//! Lógica pura del geofencing (sin Kafka ni Redis): decidir, a partir de la
//! posición nueva y del estado anterior, en qué zonas se entró y de cuáles se salió.

use std::collections::BTreeMap;

use prost::Message;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

use crate::proto::{common, geo as pb};
use crate::spatial::{GeoSnapshot, LatLng, ZoneKind};

/// Espacio de nombres para los UUID v5 de los eventos. Un UUID v5 es la
/// "huella" de un texto: el mismo texto da siempre el mismo UUID. Así, si un
/// evento se publica dos veces, ambas copias llevan el mismo id.
pub const EVENT_ID_NAMESPACE: Uuid = Uuid::from_u128(0x6e6f_6d61_6469_7121_9e0e_6765_6f66_656e);

/// Margen para relojes de móvil adelantados: más de 5 minutos en el futuro
/// es un dato erróneo (y envenenaría la detección de posiciones antiguas).
const MAX_FUTURE_SKEW_MS: i64 = 5 * 60 * 1000;
/// Longitud máxima de un user_id.
const MAX_USER_ID_LEN: usize = 128;

/// Motivos por los que un mensaje es inválido (va a la DLQ).
#[derive(Debug, Clone, PartialEq, Error)]
pub enum PositionError {
    /// No es protobuf válido.
    #[error("no es un UserPositionReported válido: {0}")]
    Decode(String),
    /// Falta un campo obligatorio.
    #[error("falta el campo {0}")]
    Missing(&'static str),
    /// event_id no es un UUID.
    #[error("metadata.event_id no es un UUID")]
    BadEventId,
    /// user_id vacío, demasiado largo o con caracteres de control.
    #[error("user_id inválido")]
    BadUserId,
    /// Coordenadas imposibles.
    #[error("posición inválida: {0}")]
    BadPosition(String),
    /// Precisión negativa o no numérica.
    #[error("horizontal_accuracy_meters inválido")]
    BadAccuracy,
    /// Marca de tiempo imposible o en el futuro.
    #[error("metadata.occurred_at inválido o en el futuro")]
    BadTimestamp,
}

/// Posición ya validada.
#[derive(Debug, Clone, PartialEq)]
pub struct Position {
    /// Id del evento de posición.
    pub event_id: Uuid,
    /// Usuario.
    pub user_id: String,
    /// Dónde.
    pub location: LatLng,
    /// Precisión en metros (0 = desconocida).
    pub accuracy_m: f64,
    /// Cuándo (milisegundos desde 1970).
    pub occurred_at_ms: i64,
    /// Correlación para trazar la operación entre servicios.
    pub correlation_id: String,
}

/// Lee y valida un `UserPositionReported`.
pub fn parse_position(payload: &[u8], now_ms: i64) -> Result<Position, PositionError> {
    let msg = pb::UserPositionReported::decode(payload).map_err(|e| PositionError::Decode(e.to_string()))?;
    let metadata = msg.metadata.ok_or(PositionError::Missing("metadata"))?;
    let event_id = Uuid::parse_str(&metadata.event_id).map_err(|_| PositionError::BadEventId)?;
    if msg.user_id.is_empty() || msg.user_id.len() > MAX_USER_ID_LEN || msg.user_id.chars().any(char::is_control) {
        return Err(PositionError::BadUserId);
    }
    let p = msg.position.ok_or(PositionError::Missing("position"))?;
    let location = LatLng::new(p.latitude, p.longitude).map_err(|e| PositionError::BadPosition(e.to_string()))?;
    if !msg.horizontal_accuracy_meters.is_finite() || msg.horizontal_accuracy_meters < 0.0 {
        return Err(PositionError::BadAccuracy);
    }
    let ts = metadata.occurred_at.ok_or(PositionError::Missing("metadata.occurred_at"))?;
    if !(0..1_000_000_000).contains(&ts.nanos) {
        return Err(PositionError::BadTimestamp);
    }
    let occurred_at_ms =
        ts.seconds.checked_mul(1000).and_then(|ms| ms.checked_add(i64::from(ts.nanos) / 1_000_000)).ok_or(PositionError::BadTimestamp)?;
    if occurred_at_ms <= 0 || occurred_at_ms > now_ms + MAX_FUTURE_SKEW_MS {
        return Err(PositionError::BadTimestamp);
    }
    let correlation_id = if metadata.correlation_id.is_empty() { metadata.event_id } else { metadata.correlation_id };
    Ok(Position { event_id, user_id: msg.user_id, location, accuracy_m: msg.horizontal_accuracy_meters, occurred_at_ms, correlation_id })
}

/// Referencia a una zona guardada en el estado de presencia. Se guarda
/// también el nombre y el tipo para poder anunciar la SALIDA aunque la zona
/// se haya borrado entretanto de la base de datos.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ZoneRef {
    /// Id.
    pub id: Uuid,
    /// Slug.
    pub slug: String,
    /// Nombre.
    pub name: String,
    /// Tipo (texto, como en PostgreSQL).
    pub kind: String,
}

/// Estado de presencia de un usuario (se guarda en Redis como JSON legible).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Presence {
    /// Versión del formato, por si cambia en el futuro.
    pub v: u8,
    /// Momento de la última posición procesada.
    pub last_occurred_at_ms: i64,
    /// Zonas en las que estaba.
    pub zones: Vec<ZoneRef>,
}

/// Clave de Redis del estado de un usuario.
pub fn presence_key(user_id: &str) -> String {
    format!("geo:presence:v1:{user_id}")
}

/// Por qué se ignora una posición (válida, pero no útil).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IgnoreReason {
    /// GPS demasiado impreciso: podría "saltar" dentro y fuera de una zona.
    TooInaccurate,
    /// Llegó tarde: ya procesamos una posición más reciente de ese usuario.
    Stale,
}

/// Entrada o salida.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TransitionKind {
    /// Entró.
    Enter,
    /// Salió.
    Exit,
}

/// Un cambio detectado.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transition {
    /// Tipo.
    pub kind: TransitionKind,
    /// Zona.
    pub zone: ZoneRef,
}

/// Resultado de evaluar una posición.
#[derive(Debug, Clone, PartialEq)]
pub enum Outcome {
    /// No hay que hacer nada.
    Ignored(IgnoreReason),
    /// Cambios a publicar (puede estar vacío) y nuevo estado a guardar.
    Evaluated {
        /// Primero las salidas y luego las entradas, cada grupo ordenado por slug.
        transitions: Vec<Transition>,
        /// Estado nuevo.
        presence: Presence,
    },
}

/// Decide qué ha cambiado para el usuario.
pub fn evaluate(position: &Position, previous: Option<&Presence>, snapshot: &GeoSnapshot, max_accuracy_m: f64) -> Outcome {
    if position.accuracy_m > max_accuracy_m {
        return Outcome::Ignored(IgnoreReason::TooInaccurate);
    }
    if previous.is_some_and(|p| position.occurred_at_ms <= p.last_occurred_at_ms) {
        return Outcome::Ignored(IgnoreReason::Stale);
    }
    // BTreeMap = diccionario ordenado: resultados siempre en el mismo orden.
    let now: BTreeMap<Uuid, ZoneRef> = snapshot
        .zones_containing(position.location)
        .into_iter()
        .map(|z| (z.id, ZoneRef { id: z.id, slug: z.slug.clone(), name: z.name.clone(), kind: z.kind.as_db().to_owned() }))
        .collect();
    let before: BTreeMap<Uuid, ZoneRef> = previous.map(|p| p.zones.iter().map(|z| (z.id, z.clone())).collect()).unwrap_or_default();

    let mut exits: Vec<Transition> = before
        .iter()
        .filter(|(id, _)| !now.contains_key(id))
        .map(|(_, zone)| Transition { kind: TransitionKind::Exit, zone: zone.clone() })
        .collect();
    let mut enters: Vec<Transition> = now
        .iter()
        .filter(|(id, _)| !before.contains_key(id))
        .map(|(_, zone)| Transition { kind: TransitionKind::Enter, zone: zone.clone() })
        .collect();
    exits.sort_by(|a, b| a.zone.slug.cmp(&b.zone.slug));
    enters.sort_by(|a, b| a.zone.slug.cmp(&b.zone.slug));
    exits.extend(enters);

    let mut zones: Vec<ZoneRef> = now.into_values().collect();
    zones.sort_by(|a, b| a.slug.cmp(&b.slug));
    Outcome::Evaluated { transitions: exits, presence: Presence { v: 1, last_occurred_at_ms: position.occurred_at_ms, zones } }
}

/// Construye el evento `GeofenceTransitioned` de un cambio. Devuelve también
/// su id (determinista) para la cabecera `ce_id`.
pub fn transition_event(position: &Position, transition: &Transition, producer: &str) -> (Uuid, pb::GeofenceTransitioned) {
    let (label, kind) = match transition.kind {
        TransitionKind::Enter => ("ENTER", pb::GeofenceTransitionType::Enter),
        TransitionKind::Exit => ("EXIT", pb::GeofenceTransitionType::Exit),
    };
    let event_id = Uuid::new_v5(&EVENT_ID_NAMESPACE, format!("{}|{}|{label}", position.event_id, transition.zone.id).as_bytes());
    let zone_kind = match ZoneKind::from_db(&transition.zone.kind) {
        Some(ZoneKind::CityCenter) => pb::ZoneKind::CityCenter,
        Some(ZoneKind::TouristArea) => pb::ZoneKind::TouristArea,
        Some(ZoneKind::Airport) => pb::ZoneKind::Airport,
        Some(ZoneKind::Restricted) => pb::ZoneKind::Restricted,
        None => pb::ZoneKind::Unspecified,
    };
    let event = pb::GeofenceTransitioned {
        metadata: Some(common::EventMetadata {
            event_id: event_id.to_string(),
            occurred_at: Some(prost_types::Timestamp {
                seconds: position.occurred_at_ms.div_euclid(1000),
                // El resto está en [0, 999], así que cabe en i32 multiplicado por 1e6.
                nanos: i32::try_from(position.occurred_at_ms.rem_euclid(1000) * 1_000_000).unwrap_or(0),
            }),
            producer: producer.to_owned(),
            correlation_id: position.correlation_id.clone(),
        }),
        user_id: position.user_id.clone(),
        transition: kind.into(),
        zone_id: transition.zone.id.to_string(),
        zone_slug: transition.zone.slug.clone(),
        zone_name: transition.zone.name.clone(),
        zone_kind: zone_kind.into(),
        position: Some(pb::LatLng { latitude: position.location.lat(), longitude: position.location.lon() }),
        position_event_id: position.event_id.to_string(),
    };
    (event_id, event)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::spatial::index::tests::sample_snapshot;

    pub(crate) const NOW_MS: i64 = 1_790_000_000_000;

    pub(crate) fn position_msg(user: &str, lat: f64, lon: f64, accuracy: f64, ms: i64, event: u128) -> pb::UserPositionReported {
        pb::UserPositionReported {
            metadata: Some(common::EventMetadata {
                event_id: Uuid::from_u128(event).to_string(),
                occurred_at: Some(prost_types::Timestamp {
                    seconds: ms / 1000,
                    nanos: i32::try_from((ms % 1000) * 1_000_000).unwrap_or(0),
                }),
                producer: "test".into(),
                correlation_id: String::new(),
            }),
            user_id: user.into(),
            position: Some(pb::LatLng { latitude: lat, longitude: lon }),
            horizontal_accuracy_meters: accuracy,
        }
    }

    fn position(lat: f64, lon: f64, ms: i64, event: u128) -> Position {
        match parse_position(&position_msg("ana", lat, lon, 10.0, ms, event).encode_to_vec(), NOW_MS) {
            Ok(p) => p,
            Err(e) => unreachable!("posición de test inválida: {e}"),
        }
    }

    #[test]
    fn valida_los_mensajes() {
        let ok = position_msg("ana", 40.4, -3.7, 5.0, NOW_MS, 1);
        assert!(parse_position(&ok.encode_to_vec(), NOW_MS).is_ok());
        assert!(matches!(parse_position(&[0xff, 0xff], NOW_MS), Err(PositionError::Decode(_))));

        let mut no_meta = ok.clone();
        no_meta.metadata = None;
        assert_eq!(parse_position(&no_meta.encode_to_vec(), NOW_MS), Err(PositionError::Missing("metadata")));

        let mut bad_user = ok.clone();
        bad_user.user_id = "a\nb".into();
        assert_eq!(parse_position(&bad_user.encode_to_vec(), NOW_MS), Err(PositionError::BadUserId));

        let mut bad_pos = ok.clone();
        bad_pos.position = Some(pb::LatLng { latitude: 100.0, longitude: 0.0 });
        assert!(matches!(parse_position(&bad_pos.encode_to_vec(), NOW_MS), Err(PositionError::BadPosition(_))));

        let mut bad_acc = ok.clone();
        bad_acc.horizontal_accuracy_meters = -1.0;
        assert_eq!(parse_position(&bad_acc.encode_to_vec(), NOW_MS), Err(PositionError::BadAccuracy));

        let future = position_msg("ana", 40.4, -3.7, 5.0, NOW_MS + 10 * 60 * 1000, 1);
        assert_eq!(parse_position(&future.encode_to_vec(), NOW_MS), Err(PositionError::BadTimestamp));

        let mut bad_id = ok;
        if let Some(m) = bad_id.metadata.as_mut() {
            m.event_id = "no-es-uuid".into();
        }
        assert_eq!(parse_position(&bad_id.encode_to_vec(), NOW_MS), Err(PositionError::BadEventId));
    }

    #[test]
    fn entrar_moverse_dentro_y_salir() {
        let snap = sample_snapshot();
        // 1) Primera posición en Sol: entra en madrid-centro y madrid-sol.
        let p1 = position(40.4168, -3.7038, NOW_MS - 3000, 1);
        let Outcome::Evaluated { transitions, presence } = evaluate(&p1, None, &snap, 100.0) else { unreachable!() };
        let summary: Vec<_> = transitions.iter().map(|t| (t.kind, t.zone.slug.as_str())).collect();
        assert_eq!(summary, [(TransitionKind::Enter, "madrid-centro"), (TransitionKind::Enter, "madrid-sol")]);

        // 2) Se mueve dentro del centro pero fuera de Sol: solo sale de Sol.
        let p2 = position(40.4200, -3.7100, NOW_MS - 2000, 2);
        let Outcome::Evaluated { transitions, presence } = evaluate(&p2, Some(&presence), &snap, 100.0) else { unreachable!() };
        let summary: Vec<_> = transitions.iter().map(|t| (t.kind, t.zone.slug.as_str())).collect();
        assert_eq!(summary, [(TransitionKind::Exit, "madrid-sol")]);

        // 3) Sigue en el mismo sitio: nada que contar.
        let p3 = position(40.4201, -3.7101, NOW_MS - 1000, 3);
        let Outcome::Evaluated { transitions, presence } = evaluate(&p3, Some(&presence), &snap, 100.0) else { unreachable!() };
        assert!(transitions.is_empty());

        // 4) Se va a Barcelona: sale del centro.
        let p4 = position(41.38, 2.17, NOW_MS, 4);
        let Outcome::Evaluated { transitions, presence } = evaluate(&p4, Some(&presence), &snap, 100.0) else { unreachable!() };
        let summary: Vec<_> = transitions.iter().map(|t| (t.kind, t.zone.slug.as_str())).collect();
        assert_eq!(summary, [(TransitionKind::Exit, "madrid-centro")]);
        assert!(presence.zones.is_empty());
    }

    #[test]
    fn ignora_posiciones_antiguas_e_imprecisas() {
        let snap = sample_snapshot();
        let previous = Presence { v: 1, last_occurred_at_ms: NOW_MS, zones: vec![] };
        let old = position(40.4168, -3.7038, NOW_MS - 1, 1);
        assert_eq!(evaluate(&old, Some(&previous), &snap, 100.0), Outcome::Ignored(IgnoreReason::Stale));
        let mut blurry = position(40.4168, -3.7038, NOW_MS + 1, 2);
        blurry.accuracy_m = 500.0;
        assert_eq!(evaluate(&blurry, Some(&previous), &snap, 100.0), Outcome::Ignored(IgnoreReason::TooInaccurate));
    }

    #[test]
    fn la_salida_de_una_zona_borrada_se_anuncia_igual() {
        let snap = sample_snapshot();
        let ghost = ZoneRef { id: Uuid::from_u128(999), slug: "zona-borrada".into(), name: "Borrada".into(), kind: "RESTRICTED".into() };
        let previous = Presence { v: 1, last_occurred_at_ms: 1, zones: vec![ghost.clone()] };
        let p = position(0.0, 0.0, NOW_MS, 1);
        let Outcome::Evaluated { transitions, .. } = evaluate(&p, Some(&previous), &snap, 100.0) else { unreachable!() };
        assert_eq!(transitions, [Transition { kind: TransitionKind::Exit, zone: ghost }]);
    }

    #[test]
    fn el_id_del_evento_es_determinista() {
        let p = position(40.4168, -3.7038, NOW_MS, 7);
        let zone = ZoneRef { id: Uuid::from_u128(1), slug: "z".into(), name: "Z".into(), kind: "CITY_CENTER".into() };
        let enter = Transition { kind: TransitionKind::Enter, zone: zone.clone() };
        let (id_a, event) = transition_event(&p, &enter, "geo-engine");
        let (id_b, _) = transition_event(&p, &enter, "geo-engine");
        assert_eq!(id_a, id_b, "reprocesar da el mismo id");
        let (id_exit, _) = transition_event(&p, &Transition { kind: TransitionKind::Exit, zone }, "geo-engine");
        assert_ne!(id_a, id_exit);
        assert_eq!(event.zone_kind, i32::from(pb::ZoneKind::CityCenter));
        assert_eq!(event.metadata.and_then(|m| m.occurred_at).map(|t| t.seconds), Some(NOW_MS / 1000));
    }
}
