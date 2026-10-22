//! Geometría pura: ni red, ni base de datos, ni Kafka.
//!
//! Separar la lógica geográfica de todo lo demás tiene dos ventajas:
//! 1. Se prueba con tests rápidos y deterministas (sin contenedores).
//! 2. Si mañana cambiamos Kafka o Redis por otra cosa, este código no se toca.
//!
//! Todo está escrito con crates 100 % Rust del ecosistema GeoRust (`geo`,
//! `geo-types`, `rstar`, `wkb`). No usamos GEOS, GDAL ni PROJ (librerías en
//! C/C++): un fallo de memoria en ellas tumbaría el proceso entero con un
//! "segmentation fault" que Rust no puede evitar.

pub mod coord;
pub mod index;
pub mod route;
pub mod wkb;

pub use coord::{CoordError, LatLng};
pub use index::{AirportRecord, GeoSnapshot, ZoneKind, ZoneRecord};
