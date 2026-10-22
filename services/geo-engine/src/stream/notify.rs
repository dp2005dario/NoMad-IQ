//! Órdenes de notificación push SEUDÓNIMAS para el notifier.
//!
//! El problema: para avisar a alguien en el móvil hay que saber a QUIÉN
//! avisar, pero el servicio que envía los avisos no debería poder montar un
//! historial de "esta persona estuvo aquí a esta hora" (RGPD, Zero Trust).
//!
//! La solución: el geo-engine (que ya sabe quién está dónde, es su trabajo)
//! no manda el `user_id`, sino un **seudónimo**: `HMAC-SHA256(clave, user_id)`.
//!
//! - Un HMAC es como una "huella con sello": con la misma clave y el mismo
//!   usuario sale siempre la misma huella, pero sin la clave es imposible
//!   calcularla o volver atrás. Ni siquiera se puede probar "¿será Ana?",
//!   porque para probarlo hace falta la clave.
//! - Solo el geo-engine y el notifier tienen la clave. El notifier guarda los
//!   teléfonos bajo ese mismo seudónimo, así que encuentra a quién avisar sin
//!   saber nunca quién es.
//! - La orden lleva lo justo: seudónimo, zona, tipo de zona e idioma. Ni
//!   coordenadas, ni precisión del GPS, ni nombres. Con la hora redondeada al
//!   minuto y un id aleatorio, igual que el `ZoneEntered` anónimo.
//!
//! Anti-spam en origen: si una misma posición hace entrar en VARIAS zonas a
//! la vez (el centro de Madrid y la Puerta del Sol están una dentro de otra),
//! solo se pide UN aviso, el de la zona más relevante ([`notify_priority`]).
//! El resto del anti-spam (enfriamiento por persona) lo hace el notifier.

use std::fmt;

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::hmac;
use uuid::Uuid;

use super::geofence::{Position, ZoneRef};
use crate::proto::{common, notify as pb};
use crate::spatial::ZoneKind;

/// Nombre completo del mensaje publicado (cabecera `ce_type`).
pub const TYPE_ZONE_NOTIFICATION_REQUESTED: &str = "nomadiq.notify.v1.ZoneNotificationRequested";

/// Bytes mínimos de la clave: 32 bytes (256 bits) = la longitud de SHA-256.
/// Con menos, el HMAC sería más fácil de atacar por fuerza bruta.
pub const MIN_KEY_BYTES: usize = 32;

/// "Etiqueta" que se mezcla antes del user_id (separación de dominios): si
/// algún día se usa la misma clave para otra cosa, los resultados nunca
/// coincidirán con estos seudónimos. El notifier usa exactamente la misma.
const RECIPIENT_CONTEXT: &[u8] = b"nomadiq/notify/recipient/v1\0";

/// Calcula seudónimos de destinatario. Su `Debug` no muestra la clave.
pub struct Pseudonymizer {
    key: hmac::Key,
}

impl fmt::Debug for Pseudonymizer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Pseudonymizer(***)")
    }
}

impl Pseudonymizer {
    /// Crea el calculador a partir de la clave en hexadecimal (64 caracteres o más).
    pub fn from_hex(key_hex: &str) -> Result<Self, String> {
        let bytes = hex::decode(key_hex.trim()).map_err(|_| "la clave debe estar en hexadecimal".to_owned())?;
        if bytes.len() < MIN_KEY_BYTES {
            return Err(format!(
                "la clave debe tener al menos {MIN_KEY_BYTES} bytes ({} caracteres hex); genera una con: openssl rand -hex 32",
                MIN_KEY_BYTES * 2
            ));
        }
        Ok(Self { key: hmac::Key::new(hmac::HMAC_SHA256, &bytes) })
    }

    /// Seudónimo de un usuario: HMAC-SHA256 en base64url sin relleno (43 caracteres).
    pub fn recipient(&self, user_id: &str) -> String {
        let mut ctx = hmac::Context::with_key(&self.key);
        ctx.update(RECIPIENT_CONTEXT);
        ctx.update(user_id.as_bytes());
        URL_SAFE_NO_PAD.encode(ctx.sign().as_ref())
    }
}

/// Qué zona "gana" si se entra en varias a la vez (mayor = más importante).
///
/// Un aviso de seguridad va siempre primero; después, lo más concreto
/// (un monumento) antes que lo más general (todo el centro de la ciudad).
pub fn notify_priority(kind: &str) -> u8 {
    match ZoneKind::from_db(kind) {
        Some(ZoneKind::Restricted) => 4,
        Some(ZoneKind::TouristArea) => 3,
        Some(ZoneKind::Airport) => 2,
        Some(ZoneKind::CityCenter) => 1,
        None => 0,
    }
}

/// Construye la orden de notificación de una entrada a zona.
pub fn request_event(position: &Position, zone: &ZoneRef, recipient: String, producer: &str) -> (Uuid, pb::ZoneNotificationRequested) {
    // Id aleatorio y hora al minuto, por lo mismo que en `zone_entry_event`:
    // que no se pueda cruzar con los eventos que sí llevan el user_id.
    let event_id = Uuid::new_v4();
    let minute_s = position.occurred_at_ms.div_euclid(60_000) * 60;
    let event = pb::ZoneNotificationRequested {
        metadata: Some(common::EventMetadata {
            event_id: event_id.to_string(),
            occurred_at: Some(prost_types::Timestamp { seconds: minute_s, nanos: 0 }),
            producer: producer.to_owned(),
            correlation_id: String::new(),
        }),
        recipient,
        zone_id: zone.id.to_string(),
        zone_kind: super::geofence::proto_zone_kind(&zone.kind).into(),
        language: position.language.clone(),
    };
    (event_id, event)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Clave de prueba 00 01 02 ... 1f. El notifier (Go) tiene un test con la
    /// MISMA clave y el MISMO resultado: si los dos lenguajes dejaran de
    /// calcular igual, los avisos no llegarían a nadie.
    const TEST_KEY: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

    #[test]
    fn seudonimo_estable_y_compatible_con_el_notifier() -> Result<(), String> {
        let p = Pseudonymizer::from_hex(TEST_KEY)?;
        let ana = p.recipient("ana");
        assert_eq!(ana.len(), 43);
        assert_eq!(ana, p.recipient("ana"), "misma persona, mismo seudónimo");
        assert_ne!(ana, p.recipient("anb"));
        assert_eq!(ana, "L3EwJq7E81uOwDP3QpkOd8aLg_sQhE63kbas17KB9rk");
        Ok(())
    }

    #[test]
    fn otra_clave_otro_seudonimo_y_claves_cortas_rechazadas() -> Result<(), String> {
        let a = Pseudonymizer::from_hex(TEST_KEY)?;
        let b = Pseudonymizer::from_hex(&"ff".repeat(32))?;
        assert_ne!(a.recipient("ana"), b.recipient("ana"));
        assert!(Pseudonymizer::from_hex("abcd").is_err());
        assert!(Pseudonymizer::from_hex(&"zz".repeat(32)).is_err());
        assert!(!format!("{a:?}").contains("0001"));
        Ok(())
    }

    #[test]
    fn la_zona_mas_concreta_gana() {
        assert!(notify_priority("RESTRICTED") > notify_priority("TOURIST_AREA"));
        assert!(notify_priority("TOURIST_AREA") > notify_priority("AIRPORT"));
        assert!(notify_priority("AIRPORT") > notify_priority("CITY_CENTER"));
        assert_eq!(notify_priority("desconocido"), 0);
    }
}
