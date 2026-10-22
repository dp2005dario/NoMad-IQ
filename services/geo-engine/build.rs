//! Script de compilación: Cargo lo ejecuta ANTES de compilar el servicio.
//!
//! Lee los contratos de `proto/` (en la raíz del repositorio) y genera el
//! código Rust equivalente (structs para los mensajes y el "esqueleto" del
//! servidor gRPC). Así el contrato es la única fuente de verdad: si alguien
//! cambia un `.proto`, el código Rust se regenera solo en la siguiente
//! compilación y el compilador avisa de todo lo que hay que adaptar.
//!
//! Usamos `protox`, un compilador de protobuf escrito en Rust, en lugar de
//! `protoc` (escrito en C++): no hay que instalar nada aparte, ni en tu PC ni
//! en Docker ni en la CI.

use std::error::Error;

/// Carpeta de los contratos, relativa a services/geo-engine.
const PROTO_ROOT: &str = "../../proto";

/// Contratos que necesita este servicio (sus dependencias se incluyen solas).
const PROTO_FILES: &[&str] = &["nomadiq/geo/v1/geo_service.proto", "nomadiq/geo/v1/events.proto"];

fn main() -> Result<(), Box<dyn Error>> {
    // Recompilar si cambia cualquier contrato.
    println!("cargo:rerun-if-changed={PROTO_ROOT}");

    // 1) Compilar los .proto a un "FileDescriptorSet": una descripción binaria
    //    de todos los mensajes y servicios (con sus comentarios).
    let descriptors = protox::compile(PROTO_FILES, [PROTO_ROOT])?;

    // 2) Generar el código Rust a partir de esa descripción.
    tonic_prost_build::configure()
        // El servidor es este servicio; el cliente lo usan los tests (y
        // servirá a otros servicios Rust en el futuro).
        .build_server(true)
        .build_client(true)
        // El WKB de una geometría se genera como `bytes::Bytes` en vez de
        // `Vec<u8>`: copiar un `Bytes` solo incrementa un contador, no duplica
        // los datos. Las zonas guardan su WKB una vez y cada respuesta lo
        // comparte sin copiar miles de vértices.
        .bytes(".nomadiq.geo.v1.Geometry.wkb")
        .compile_fds(descriptors)?;
    Ok(())
}
