//! Endpoints de salud para Docker y Kubernetes.
//!
//! - `/healthz` ("¿estás vivo?"): responde 200 mientras el proceso funcione.
//!   Si deja de responder, el orquestador reinicia el contenedor.
//! - `/readyz` ("¿puedes atender?"): 200 solo cuando la foto geoespacial está
//!   cargada. Mientras no lo esté, el balanceador no le manda tráfico.
//!
//! Redis y Kafka se muestran en `/readyz` como información, pero NO quitan el
//! "listo": sin Redis las rutas se calculan igual (sin caché) y el geofencing
//! reintenta solo. Apartar del tráfico un servicio que puede responder sería
//! convertir una avería parcial en una caída total.

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::get;
use axum::{Json, Router};
use serde_json::{Value, json};

use crate::cache::RedisStore;
use crate::snapshot::SnapshotHandle;

/// Estado del consumidor de Kafka, compartido entre tareas sin cerrojos.
#[derive(Debug, Clone, Default)]
pub struct StreamStatus(Arc<AtomicU8>);

/// Valores posibles de [`StreamStatus`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum StreamState {
    /// GEOFENCE_STREAM_ENABLED=false.
    Disabled = 0,
    /// Arrancando (esperando la foto o conectando a Kafka).
    Starting = 1,
    /// Procesando posiciones.
    Running = 2,
    /// Reintentando tras un error (Redis o Kafka no disponibles).
    Retrying = 3,
    /// Parado (apagado o error fatal).
    Stopped = 4,
}

impl StreamStatus {
    /// Cambia el estado.
    pub fn set(&self, state: StreamState) {
        self.0.store(state as u8, Ordering::Relaxed);
    }

    /// Estado actual.
    pub fn get(&self) -> StreamState {
        match self.0.load(Ordering::Relaxed) {
            1 => StreamState::Starting,
            2 => StreamState::Running,
            3 => StreamState::Retrying,
            4 => StreamState::Stopped,
            _ => StreamState::Disabled,
        }
    }
}

/// Lo que necesitan los endpoints.
#[derive(Debug, Clone)]
pub struct HealthState {
    /// Foto geoespacial.
    pub snapshots: SnapshotHandle,
    /// Redis (para informar de su estado).
    pub redis: RedisStore,
    /// Estado del geofencing.
    pub stream: StreamStatus,
}

/// Rutas HTTP de salud.
pub fn router(state: HealthState) -> Router {
    Router::new().route("/healthz", get(|| async { "ok" })).route("/readyz", get(readyz)).with_state(state)
}

async fn readyz(State(state): State<HealthState>) -> (StatusCode, Json<Value>) {
    let snapshot = state.snapshots.load();
    let ready = snapshot.is_some();
    let redis = match state.redis.ping().await {
        Ok(()) => "ok".to_owned(),
        Err(e) => format!("no disponible: {e}"),
    };
    let stream = match state.stream.get() {
        StreamState::Disabled => "disabled",
        StreamState::Starting => "starting",
        StreamState::Running => "running",
        StreamState::Retrying => "retrying",
        StreamState::Stopped => "stopped",
    };
    let body = json!({
        "ready": ready,
        "snapshot": snapshot.map(|s| json!({
            "version": s.version(),
            "airports": s.airport_count(),
            "zones": s.zone_count(),
            "rejected_rows": state.snapshots.rejected_rows(),
            "seconds_since_last_sync": state.snapshots.seconds_since_last_sync(),
        })),
        "redis": redis,
        "geofence_stream": stream,
    });
    let code = if ready { StatusCode::OK } else { StatusCode::SERVICE_UNAVAILABLE };
    (code, Json(body))
}
