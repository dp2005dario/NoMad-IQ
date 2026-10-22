//! # geo-engine
//!
//! Motor geoespacial de NomadIQ, escrito en Rust.
//!
//! ## ¿Qué hace?
//! - Responde por gRPC (con mTLS) preguntas geográficas de alta frecuencia:
//!   aeropuertos cercanos, distancias, orden óptimo de paradas y en qué zonas
//!   (geofences) está un punto.
//! - Escucha en Kafka las posiciones de los usuarios y publica un evento cada
//!   vez que alguien entra o sale de una zona (geofencing en streaming).
//!
//! ## ¿Por qué Rust?
//! Rust compila a código máquina (tan rápido como C) pero el compilador impide
//! los errores de memoria típicos de C (punteros colgantes, carreras de datos).
//! Por eso este crate prohíbe `unsafe` (ver `[lints]` en Cargo.toml).
//!
//! ## Mapa de módulos
//! - [`config`]: lee y valida la configuración (variables de entorno).
//! - [`spatial`]: geometría pura (coordenadas, distancias, WKB, índices R-tree,
//!   optimización de rutas). No sabe nada de redes ni bases de datos.
//! - [`snapshot`]: la "foto" en memoria de aeropuertos y zonas y cómo se
//!   sustituye sin bloquear a nadie.
//! - [`store`]: PostgreSQL + PostGIS, la fuente de verdad.
//! - [`cache`]: Redis (caché de rutas y estado de presencia por usuario).
//! - [`grpc`]: la API `GeoService`.
//! - [`tls`]: TLS 1.3 y mTLS para el gRPC.
//! - [`stream`]: el consumidor/productor de Kafka del geofencing.
//! - [`health`]: endpoints `/healthz` y `/readyz`.
//! - [`proto`]: código generado desde `proto/`.

pub mod cache;
pub mod config;
pub mod grpc;
pub mod health;
pub mod proto;
pub mod snapshot;
pub mod spatial;
pub mod store;
pub mod stream;
pub mod tls;
