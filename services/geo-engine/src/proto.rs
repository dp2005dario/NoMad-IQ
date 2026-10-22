//! Código generado a partir de los contratos de `proto/` (lo crea `build.rs`).
//!
//! Los módulos anidados reproducen los paquetes protobuf
//! (`nomadiq.geo.v1` → `nomadiq::geo::v1`) para que las referencias entre
//! ficheros (por ejemplo, de `geo` a `common`) se resuelvan solas.
//! No edites nada aquí: cambia el `.proto` y vuelve a compilar.

/// Paquetes de NomadIQ.
// El código generado no sigue todas nuestras reglas de estilo: las relajamos
// solo aquí dentro.
#[allow(clippy::all, clippy::pedantic, missing_debug_implementations, missing_docs)]
pub mod nomadiq {
    /// Tipos compartidos por todos los servicios.
    pub mod common {
        /// Versión 1 de los tipos comunes.
        pub mod v1 {
            tonic::include_proto!("nomadiq.common.v1");
        }
    }
    /// Contratos geoespaciales.
    pub mod geo {
        /// Versión 1 de los contratos geoespaciales.
        pub mod v1 {
            tonic::include_proto!("nomadiq.geo.v1");
        }
    }
    /// Contratos de la capa de notificaciones.
    pub mod notify {
        /// Versión 1 de los contratos de notificaciones.
        pub mod v1 {
            tonic::include_proto!("nomadiq.notify.v1");
        }
    }
}

pub use nomadiq::common::v1 as common;
pub use nomadiq::geo::v1 as geo;
pub use nomadiq::notify::v1 as notify;
