//! Lógica pura del geofencing (sin Kafka ni Redis): decidir, a partir de la
//! posición nueva y del estado anterior, en qué zonas se entró y de cuáles se salió.
//!
//! ## Histéresis: por qué no basta con "¿está dentro del polígono?"
//! El GPS de un móvil "baila" entre 5 y 30 metros aunque estés quieto. Si
//! alguien camina justo por el borde de una zona (la acera de enfrente de un
//! museo), la respuesta "dentro/fuera" cambia en cada lectura y se genera una
//! tormenta de avisos ENTRAR, SALIR, ENTRAR... Cada ENTRAR despertaría a la IA
//! de audioguías y a las notificaciones para nada.
//!
//! La solución es la misma que usa un termostato (o un "disparador de
//! Schmitt" en electrónica): umbrales DISTINTOS para encender y para apagar.
//! - **Entrar** exige estar dentro del polígono y SEGUIR dentro durante un
//!   tiempo mínimo (`enter_dwell`, por ejemplo 15 s). Mientras tanto la zona
//!   queda "pendiente" y no se avisa a nadie.
//! - **Salir** exige alejarse del borde MÁS de un margen (`exit_margin`, por
//!   ejemplo 30 m). Si la precisión del GPS es peor que ese margen, se usa la
//!   precisión: no damos por buena una salida si el círculo de incertidumbre
//!   todavía toca la zona.
//!
//! Entre ambos umbrales hay una "franja muerta" donde el estado no cambia: el
//! baile del GPS en el borde ya no produce eventos.

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
    /// Idioma principal normalizado ("es", "en"...) o vacío si no se indicó.
    pub language: String,
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
    Ok(Position {
        event_id,
        user_id: msg.user_id,
        location,
        accuracy_m: msg.horizontal_accuracy_meters,
        language: normalize_language(&msg.preferred_language),
        occurred_at_ms,
        correlation_id,
    })
}

/// Reduce una etiqueta de idioma BCP 47 a su parte principal en minúsculas:
/// "es-ES" -> "es", "EN_gb" -> "en", "zh-Hant-TW" -> "zh".
///
/// ¿Por qué no guardar la etiqueta entera? Para elegir el idioma de una
/// audioguía basta con "en"; la región ("en-GB") es un dato más sobre la
/// persona que no necesitamos (minimización). Si la etiqueta no tiene la
/// forma esperada (2 o 3 letras ASCII), se devuelve vacío: el idioma es
/// opcional y un valor raro no debe tirar la posición entera a la DLQ.
pub fn normalize_language(tag: &str) -> String {
    let primary = tag.trim().split(['-', '_']).next().unwrap_or_default();
    if (2..=3).contains(&primary.len()) && primary.chars().all(|c| c.is_ascii_alphabetic()) {
        primary.to_ascii_lowercase()
    } else {
        String::new()
    }
}

/// Reglas del geofencing, incluida la histéresis (ver la cabecera del módulo).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GeofenceRules {
    /// Posiciones con peor precisión que esto se ignoran.
    pub max_accuracy_m: f64,
    /// Distancia mínima al borde para dar por buena una salida (0 = sin margen).
    pub exit_margin_m: f64,
    /// Tiempo mínimo dentro antes de anunciar una entrada (0 = inmediata).
    pub enter_dwell_ms: i64,
}

impl GeofenceRules {
    /// Sin histéresis: entrar y salir exactamente en el borde (útil en tests).
    pub const fn without_hysteresis(max_accuracy_m: f64) -> Self {
        Self { max_accuracy_m, exit_margin_m: 0.0, enter_dwell_ms: 0 }
    }
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

/// Una zona en la que el usuario está dentro, pero aún no el tiempo
/// suficiente para anunciar la entrada (histéresis de entrada).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingZone {
    /// Zona.
    pub zone: ZoneRef,
    /// Primera vez (ms desde 1970) que se le vio dentro sin interrupción.
    pub since_ms: i64,
}

/// Versión actual del formato del estado de presencia.
pub const PRESENCE_VERSION: u8 = 2;

/// Estado de presencia de un usuario (se guarda en Redis como JSON legible).
///
/// Versión 2: añade `pending`. Un estado de la versión 1 (sin ese campo) se
/// sigue leyendo bien gracias a `#[serde(default)]`: cuenta como "sin
/// pendientes". Así desplegar esta versión no "olvida" dónde está nadie.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Presence {
    /// Versión del formato, por si cambia en el futuro.
    pub v: u8,
    /// Momento de la última posición procesada.
    pub last_occurred_at_ms: i64,
    /// Zonas en las que estaba (entrada ya anunciada).
    pub zones: Vec<ZoneRef>,
    /// Zonas en las que acaba de entrar, a la espera de confirmar.
    #[serde(default)]
    pub pending: Vec<PendingZone>,
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

/// Decide qué ha cambiado para el usuario, aplicando la histéresis.
pub fn evaluate(position: &Position, previous: Option<&Presence>, snapshot: &GeoSnapshot, rules: &GeofenceRules) -> Outcome {
    if position.accuracy_m > rules.max_accuracy_m {
        return Outcome::Ignored(IgnoreReason::TooInaccurate);
    }
    if previous.is_some_and(|p| position.occurred_at_ms <= p.last_occurred_at_ms) {
        return Outcome::Ignored(IgnoreReason::Stale);
    }
    let now_ms = position.occurred_at_ms;
    // Margen de salida efectivo: si el GPS es más impreciso que el margen,
    // manda la precisión (no sabemos si de verdad ha salido).
    let exit_margin_m = rules.exit_margin_m.max(position.accuracy_m);

    // BTreeMap = diccionario ordenado: resultados siempre en el mismo orden.
    let inside_now: BTreeMap<Uuid, ZoneRef> = snapshot
        .zones_containing(position.location)
        .into_iter()
        .map(|z| (z.id, ZoneRef { id: z.id, slug: z.slug.clone(), name: z.name.clone(), kind: z.kind.as_db().to_owned() }))
        .collect();
    let confirmed: Vec<ZoneRef> = previous.map(|p| p.zones.clone()).unwrap_or_default();
    let pending_before: BTreeMap<Uuid, i64> =
        previous.map(|p| p.pending.iter().map(|pz| (pz.zone.id, pz.since_ms)).collect()).unwrap_or_default();

    // 1) Zonas en las que YA estaba: ¿sigue dentro (con el margen de salida)?
    let mut exits = Vec::new();
    let mut still_in: BTreeMap<Uuid, ZoneRef> = BTreeMap::new();
    for zone in confirmed {
        let stays = match snapshot.zone(&zone.id) {
            // Dentro del polígono, o fuera pero aún dentro de la franja muerta.
            Some(record) => inside_now.contains_key(&zone.id) || record.distance_m(position.location) <= exit_margin_m,
            // La zona se borró de la base de datos: se anuncia la salida.
            None => false,
        };
        if stays {
            still_in.insert(zone.id, zone);
        } else {
            exits.push(Transition { kind: TransitionKind::Exit, zone });
        }
    }

    // 2) Zonas en las que está dentro pero aún no se había anunciado la entrada.
    let mut enters = Vec::new();
    let mut pending = Vec::new();
    for (id, zone) in inside_now {
        if still_in.contains_key(&id) {
            continue;
        }
        // Si ya estaba pendiente, el reloj sigue corriendo desde la primera
        // vez que se le vio dentro; si no, empieza ahora.
        let since_ms = pending_before.get(&id).copied().unwrap_or(now_ms);
        if now_ms.saturating_sub(since_ms) >= rules.enter_dwell_ms {
            still_in.insert(id, zone.clone());
            enters.push(Transition { kind: TransitionKind::Enter, zone });
        } else {
            pending.push(PendingZone { zone, since_ms });
        }
    }
    // Las pendientes que NO aparecen arriba se descartan sin avisar: salió
    // antes de cumplir el tiempo mínimo (era el GPS bailando en el borde).

    exits.sort_by(|a, b| a.zone.slug.cmp(&b.zone.slug));
    enters.sort_by(|a, b| a.zone.slug.cmp(&b.zone.slug));
    exits.extend(enters);

    let mut zones: Vec<ZoneRef> = still_in.into_values().collect();
    zones.sort_by(|a, b| a.slug.cmp(&b.slug));
    pending.sort_by(|a, b| a.zone.slug.cmp(&b.zone.slug));
    Outcome::Evaluated { transitions: exits, presence: Presence { v: PRESENCE_VERSION, last_occurred_at_ms: now_ms, zones, pending } }
}

/// Construye el evento `GeofenceTransitioned` de un cambio. Devuelve también
/// su id (determinista) para la cabecera `ce_id`.
pub fn transition_event(position: &Position, transition: &Transition, producer: &str) -> (Uuid, pb::GeofenceTransitioned) {
    let (label, kind) = match transition.kind {
        TransitionKind::Enter => ("ENTER", pb::GeofenceTransitionType::Enter),
        TransitionKind::Exit => ("EXIT", pb::GeofenceTransitionType::Exit),
    };
    let event_id = Uuid::new_v5(&EVENT_ID_NAMESPACE, format!("{}|{}|{label}", position.event_id, transition.zone.id).as_bytes());
    let zone_kind = proto_zone_kind(&transition.zone.kind);
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

/// Construye el evento ANÓNIMO `ZoneEntered` de una entrada (ver
/// events.proto): solo zona, tipo e idioma. Nada que identifique a la persona.
///
/// El id es aleatorio (UUID v4) a propósito: si se derivase de la posición,
/// quien tuviera acceso a otros topics podría recalcularlo y saber de quién
/// es. ¿Y los duplicados si se reprocesa? Son inofensivos: quien lo consume
/// (la caché de audioguías por zona) es idempotente por naturaleza.
pub fn zone_entry_event(position: &Position, zone: &ZoneRef, producer: &str) -> (Uuid, pb::ZoneEntered) {
    let event_id = Uuid::new_v4();
    // Redondeo hacia abajo al minuto: menos precisión temporal = más difícil
    // cruzar este evento con otros para reidentificar a alguien.
    let minute_s = position.occurred_at_ms.div_euclid(60_000) * 60;
    let event = pb::ZoneEntered {
        metadata: Some(common::EventMetadata {
            event_id: event_id.to_string(),
            occurred_at: Some(prost_types::Timestamp { seconds: minute_s, nanos: 0 }),
            producer: producer.to_owned(),
            correlation_id: String::new(),
        }),
        zone_id: zone.id.to_string(),
        zone_kind: proto_zone_kind(&zone.kind).into(),
        language: position.language.clone(),
    };
    (event_id, event)
}

pub(crate) fn proto_zone_kind(kind: &str) -> pb::ZoneKind {
    match ZoneKind::from_db(kind) {
        Some(ZoneKind::CityCenter) => pb::ZoneKind::CityCenter,
        Some(ZoneKind::TouristArea) => pb::ZoneKind::TouristArea,
        Some(ZoneKind::Airport) => pb::ZoneKind::Airport,
        Some(ZoneKind::Restricted) => pb::ZoneKind::Restricted,
        None => pb::ZoneKind::Unspecified,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::spatial::index::tests::sample_snapshot;

    pub(crate) const NOW_MS: i64 = 1_790_000_000_000;
    const NO_HYSTERESIS: GeofenceRules = GeofenceRules::without_hysteresis(100.0);
    /// Histéresis típica: 30 m de margen de salida y 15 s dentro para entrar.
    const HYSTERESIS: GeofenceRules = GeofenceRules { max_accuracy_m: 100.0, exit_margin_m: 30.0, enter_dwell_ms: 15_000 };

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
            preferred_language: "es-ES".into(),
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
        let Outcome::Evaluated { transitions, presence } = evaluate(&p1, None, &snap, &NO_HYSTERESIS) else { unreachable!() };
        let summary: Vec<_> = transitions.iter().map(|t| (t.kind, t.zone.slug.as_str())).collect();
        assert_eq!(summary, [(TransitionKind::Enter, "madrid-centro"), (TransitionKind::Enter, "madrid-sol")]);

        // 2) Se mueve dentro del centro pero fuera de Sol: solo sale de Sol.
        let p2 = position(40.4200, -3.7100, NOW_MS - 2000, 2);
        let Outcome::Evaluated { transitions, presence } = evaluate(&p2, Some(&presence), &snap, &NO_HYSTERESIS) else { unreachable!() };
        let summary: Vec<_> = transitions.iter().map(|t| (t.kind, t.zone.slug.as_str())).collect();
        assert_eq!(summary, [(TransitionKind::Exit, "madrid-sol")]);

        // 3) Sigue en el mismo sitio: nada que contar.
        let p3 = position(40.4201, -3.7101, NOW_MS - 1000, 3);
        let Outcome::Evaluated { transitions, presence } = evaluate(&p3, Some(&presence), &snap, &NO_HYSTERESIS) else { unreachable!() };
        assert!(transitions.is_empty());

        // 4) Se va a Barcelona: sale del centro.
        let p4 = position(41.38, 2.17, NOW_MS, 4);
        let Outcome::Evaluated { transitions, presence } = evaluate(&p4, Some(&presence), &snap, &NO_HYSTERESIS) else { unreachable!() };
        let summary: Vec<_> = transitions.iter().map(|t| (t.kind, t.zone.slug.as_str())).collect();
        assert_eq!(summary, [(TransitionKind::Exit, "madrid-centro")]);
        assert!(presence.zones.is_empty());
    }

    #[test]
    fn ignora_posiciones_antiguas_e_imprecisas() {
        let snap = sample_snapshot();
        let previous = Presence { v: 1, last_occurred_at_ms: NOW_MS, zones: vec![], pending: vec![] };
        let old = position(40.4168, -3.7038, NOW_MS - 1, 1);
        assert_eq!(evaluate(&old, Some(&previous), &snap, &NO_HYSTERESIS), Outcome::Ignored(IgnoreReason::Stale));
        let mut blurry = position(40.4168, -3.7038, NOW_MS + 1, 2);
        blurry.accuracy_m = 500.0;
        assert_eq!(evaluate(&blurry, Some(&previous), &snap, &NO_HYSTERESIS), Outcome::Ignored(IgnoreReason::TooInaccurate));
    }

    #[test]
    fn la_salida_de_una_zona_borrada_se_anuncia_igual() {
        let snap = sample_snapshot();
        let ghost = ZoneRef { id: Uuid::from_u128(999), slug: "zona-borrada".into(), name: "Borrada".into(), kind: "RESTRICTED".into() };
        let previous = Presence { v: 1, last_occurred_at_ms: 1, zones: vec![ghost.clone()], pending: vec![] };
        let p = position(0.0, 0.0, NOW_MS, 1);
        let Outcome::Evaluated { transitions, .. } = evaluate(&p, Some(&previous), &snap, &NO_HYSTERESIS) else { unreachable!() };
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
    fn slugs(transitions: &[Transition]) -> Vec<(TransitionKind, &str)> {
        transitions.iter().map(|t| (t.kind, t.zone.slug.as_str())).collect()
    }

    /// Evalúa con la histéresis típica y devuelve (cambios, estado nuevo).
    fn step(lat: f64, lon: f64, ms: i64, event: u128, previous: Option<&Presence>) -> (Vec<Transition>, Presence) {
        let snap = sample_snapshot();
        match evaluate(&position(lat, lon, ms, event), previous, &snap, &HYSTERESIS) {
            Outcome::Evaluated { transitions, presence } => (transitions, presence),
            Outcome::Ignored(reason) => unreachable!("no debería ignorarse: {reason:?}"),
        }
    }

    #[test]
    fn el_gps_bailando_en_el_borde_no_genera_tormenta() {
        let t0 = NOW_MS - 60_000;
        // 1) Primera lectura dentro de Sol: aún no se anuncia nada (pendiente).
        let (t, state) = step(40.4175, -3.7035, t0, 1, None);
        assert!(t.is_empty());
        assert_eq!(state.pending.len(), 2, "madrid-centro y madrid-sol, a la espera");
        // 2) Sigue dentro 20 s después (> 15 s): ahora sí, ENTRAR en ambas.
        let (t, state) = step(40.4176, -3.7034, t0 + 20_000, 2, Some(&state));
        assert_eq!(slugs(&t), [(TransitionKind::Enter, "madrid-centro"), (TransitionKind::Enter, "madrid-sol")]);
        assert!(state.pending.is_empty());
        // 3) El GPS "salta" ~11 m fuera del borde norte de Sol, vuelve dentro y
        //    vuelve a salir: todo dentro de la franja muerta de 30 m, CERO eventos.
        let mut state = state;
        for (i, lat) in [40.4181, 40.4179, 40.4181, 40.4182].into_iter().enumerate() {
            let (t, next) = step(lat, -3.7035, t0 + 25_000 + 5_000 * i64::try_from(i).unwrap_or(0), 3 + i as u128, Some(&state));
            assert!(t.is_empty(), "lectura {i} en el borde generó {:?}", slugs(&t));
            state = next;
        }
        // 4) Se aleja de verdad (~111 m al norte del borde): SALIR de Sol.
        let (t, state) = step(40.4190, -3.7035, t0 + 50_000, 9, Some(&state));
        assert_eq!(slugs(&t), [(TransitionKind::Exit, "madrid-sol")]);
        assert_eq!(state.zones.len(), 1, "sigue en madrid-centro");
    }

    #[test]
    fn una_entrada_fugaz_no_cuenta() {
        let t0 = NOW_MS - 60_000;
        let (_, state) = step(40.4175, -3.7035, t0, 1, None);
        // 5 s después ya está ~111 m fuera de Sol: Sol se olvida sin avisar.
        let (t, state) = step(40.4190, -3.7035, t0 + 5_000, 2, Some(&state));
        assert!(t.is_empty());
        let pending: Vec<_> = state.pending.iter().map(|p| p.zone.slug.as_str()).collect();
        assert_eq!(pending, ["madrid-centro"]);
        // Vuelve a Sol a los 20 s: madrid-centro (dentro desde t0) se confirma;
        // Sol empieza a contar DE NUEVO desde ahora.
        let (t, state) = step(40.4175, -3.7035, t0 + 20_000, 3, Some(&state));
        assert_eq!(slugs(&t), [(TransitionKind::Enter, "madrid-centro")]);
        assert_eq!(state.pending.first().map(|p| (p.zone.slug.as_str(), p.since_ms)), Some(("madrid-sol", t0 + 20_000)));
    }

    #[test]
    fn un_gps_impreciso_amplia_el_margen_de_salida() {
        let snap = sample_snapshot();
        let sol = ZoneRef { id: Uuid::from_u128(2), slug: "madrid-sol".into(), name: "madrid-sol".into(), kind: "TOURIST_AREA".into() };
        let previous = Presence { v: PRESENCE_VERSION, last_occurred_at_ms: 1, zones: vec![sol], pending: vec![] };
        // ~55 m fuera del borde norte de Sol.
        let mut p = position(40.4185, -3.703, NOW_MS, 1);
        p.accuracy_m = 80.0;
        let Outcome::Evaluated { transitions, .. } = evaluate(&p, Some(&previous), &snap, &HYSTERESIS) else { unreachable!() };
        assert!(transitions.is_empty(), "con ±80 m no sabemos si salió: se queda dentro");
        p.accuracy_m = 10.0;
        let Outcome::Evaluated { transitions, .. } = evaluate(&p, Some(&previous), &snap, &HYSTERESIS) else { unreachable!() };
        assert_eq!(slugs(&transitions), [(TransitionKind::Exit, "madrid-sol")]);
    }

    #[test]
    fn el_estado_de_la_version_1_se_sigue_leyendo() -> Result<(), serde_json::Error> {
        let v1 = r#"{"v":1,"last_occurred_at_ms":5,"zones":[{"id":"00000000-0000-0000-0000-000000000002","slug":"madrid-sol","name":"Sol","kind":"TOURIST_AREA"}]}"#;
        let presence: Presence = serde_json::from_str(v1)?;
        assert_eq!(presence.zones.len(), 1);
        assert!(presence.pending.is_empty());
        Ok(())
    }

    #[test]
    fn normaliza_el_idioma() {
        assert_eq!(normalize_language("es-ES"), "es");
        assert_eq!(normalize_language(" EN_gb "), "en");
        assert_eq!(normalize_language("zh-Hant-TW"), "zh");
        assert_eq!(normalize_language("fil"), "fil");
        assert_eq!(normalize_language(""), "");
        assert_eq!(normalize_language("español"), "");
        assert_eq!(normalize_language("e1"), "");
    }

    #[test]
    fn la_entrada_anonima_no_lleva_datos_personales() {
        let p = position(40.4168, -3.7038, NOW_MS + 59_123 - NOW_MS % 60_000, 7);
        let zone = ZoneRef { id: Uuid::from_u128(1), slug: "z".into(), name: "Z".into(), kind: "TOURIST_AREA".into() };
        let (id_a, event) = zone_entry_event(&p, &zone, "geo-engine");
        let (id_b, _) = zone_entry_event(&p, &zone, "geo-engine");
        assert_ne!(id_a, id_b, "id aleatorio: no se puede enlazar con la posición");
        assert_eq!(event.zone_id, zone.id.to_string());
        assert_eq!(event.language, "es");
        assert_eq!(event.zone_kind, i32::from(pb::ZoneKind::TouristArea));
        let meta = event.metadata.clone().unwrap_or_default();
        assert!(meta.correlation_id.is_empty());
        assert_eq!(meta.occurred_at.map(|t| (t.seconds % 60, t.nanos)), Some((0, 0)), "redondeado al minuto");
        // Ni rastro del usuario ni de la posición en los bytes del mensaje.
        let bytes = event.encode_to_vec();
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("ana") && !text.contains(&p.event_id.to_string()));
    }
}
