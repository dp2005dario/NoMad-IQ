//! Geofencing en streaming: posiciones de usuarios → entradas/salidas de zonas.
//!
//! Flujo de cada mensaje de `geo.user-positions.v1`:
//! 1. Leer y validar la posición. Si es basura → a la DLQ (buzón de mensajes
//!    rotos) para investigarla, sin bloquear al resto.
//! 2. Leer de Redis en qué zonas estaba el usuario.
//! 3. Calcular en qué zonas está ahora (índice en memoria, microsegundos).
//! 4. Publicar un `GeofenceTransitioned` por cada zona en la que entró o de
//!    la que salió, y esperar a que Kafka confirme.
//! 5. Guardar el nuevo estado en Redis y marcar el mensaje como procesado.
//!
//! ## ¿Y si se cae a mitad? (entrega "al menos una vez")
//! El orden importa: primero publicar, luego guardar estado, y por último
//! confirmar el mensaje. Si el proceso muere entre medias, el mensaje se
//! vuelve a procesar y genera los MISMOS eventos con los MISMOS ids
//! (deterministas): quien los consume descarta los repetidos. Nunca se pierde
//! un aviso; como mucho se duplica, y el duplicado se detecta.
//!
//! ## Concurrencia sin cerrojos (riesgo 3)
//! La clave de Kafka es el user_id: todas las posiciones de una persona van a
//! la misma partición y las procesa UNA sola instancia, en orden. No hay dos
//! hilos peleándose por el estado del mismo usuario, así que no hacen falta
//! cerrojos: es el patrón de "paso de mensajes". Para escalar se añaden
//! instancias y Kafka les reparte las particiones.

pub mod geofence;
pub mod kafka;
pub mod notify;
pub mod processor;

pub use processor::{EventSink, InboundRecord, OutboundRecord, Processor};
