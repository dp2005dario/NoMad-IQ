//! El "obrero" del geofencing: procesa un mensaje de Kafka de principio a fin.
//!
//! No conoce Kafka directamente: recibe un [`InboundRecord`] (datos copiados
//! del mensaje) y publica a través de la interfaz [`EventSink`]. Así se puede
//! probar entero con un Redis y un Kafka falsos, en milisegundos.

use std::future::Future;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use prost::Message;
use thiserror::Error;

use super::geofence::{self, Outcome, Presence, presence_key};
use crate::cache::{CacheError, KeyValueStore};
use crate::snapshot::SnapshotHandle;

/// Nombre con el que este servicio firma sus eventos.
pub const PRODUCER: &str = "geo-engine";
/// Tipo de contenido de los mensajes (igual que en los servicios Go).
pub const CONTENT_TYPE_PROTOBUF: &str = "application/x-protobuf";
/// Nombre completo del mensaje publicado (cabecera `ce_type`).
pub const TYPE_GEOFENCE_TRANSITIONED: &str = "nomadiq.geo.v1.GeofenceTransitioned";

/// Mensaje recibido (copia de los datos que necesitamos del mensaje de Kafka).
#[derive(Debug, Clone, Default)]
pub struct InboundRecord {
    /// Topic de origen.
    pub topic: String,
    /// Partición.
    pub partition: i32,
    /// Posición en la partición.
    pub offset: i64,
    /// Clave.
    pub key: Option<Vec<u8>>,
    /// Contenido.
    pub payload: Option<Vec<u8>>,
    /// Cabeceras (nombre, valor).
    pub headers: Vec<(String, Vec<u8>)>,
}

/// Mensaje a publicar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutboundRecord {
    /// Topic destino.
    pub topic: String,
    /// Clave (user_id).
    pub key: Vec<u8>,
    /// Contenido.
    pub payload: Vec<u8>,
    /// Cabeceras.
    pub headers: Vec<(String, Vec<u8>)>,
}

/// Fallo al publicar.
#[derive(Debug, Error)]
#[error("no se pudo publicar en Kafka: {0}")]
pub struct SinkError(pub String);

/// Destino de los eventos (Kafka en producción, un vector en los tests).
pub trait EventSink: Send + Sync + 'static {
    /// Publica y espera la confirmación del broker.
    fn send(&self, record: OutboundRecord) -> impl Future<Output = Result<(), SinkError>> + Send;
}

/// Errores TRANSITORIOS: se reintenta el mismo mensaje más tarde, sin
/// confirmarlo. (Los errores de DATOS no son transitorios: van a la DLQ.)
#[derive(Debug, Error)]
pub enum TransientError {
    /// Redis no disponible.
    #[error(transparent)]
    Cache(#[from] CacheError),
    /// Kafka no confirmó la publicación.
    #[error(transparent)]
    Sink(#[from] SinkError),
    /// Aún no hay datos geoespaciales cargados.
    #[error("la foto geoespacial aún no está cargada")]
    NoSnapshot,
    /// No se pudo convertir el estado a JSON (no debería ocurrir nunca).
    #[error("no se pudo serializar el estado de presencia: {0}")]
    Encode(String),
}

/// Qué pasó con un mensaje (para logs y tests).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Handled {
    /// Se publicaron `n` cambios (puede ser 0).
    Published(usize),
    /// Válido pero sin interés (impreciso o antiguo).
    Ignored,
    /// Inválido: enviado a la DLQ.
    DeadLettered,
}

/// Configuración del procesador.
#[derive(Debug, Clone)]
pub struct ProcessorSettings {
    /// Topic de salida.
    pub topic_transitions: String,
    /// Topic DLQ.
    pub topic_dlq: String,
    /// Precisión máxima aceptada.
    pub max_accuracy_m: f64,
    /// Caducidad del estado de presencia.
    pub presence_ttl: Duration,
}

/// Procesador de posiciones.
#[derive(Debug)]
pub struct Processor<S, K> {
    snapshots: SnapshotHandle,
    presence: Arc<S>,
    sink: Arc<K>,
    settings: ProcessorSettings,
}

impl<S: KeyValueStore, K: EventSink> Processor<S, K> {
    /// Crea el procesador.
    pub fn new(snapshots: SnapshotHandle, presence: Arc<S>, sink: Arc<K>, settings: ProcessorSettings) -> Self {
        Self { snapshots, presence, sink, settings }
    }

    /// Procesa un mensaje. `Ok` = se puede confirmar; `Err` = reintentar.
    pub async fn handle(&self, record: &InboundRecord) -> Result<Handled, TransientError> {
        let snapshot = self.snapshots.load().ok_or(TransientError::NoSnapshot)?;
        let Some(payload) = record.payload.as_deref() else {
            return self.dead_letter(record, "mensaje sin contenido").await;
        };
        let position = match geofence::parse_position(payload, now_ms()) {
            Ok(p) => p,
            Err(e) => return self.dead_letter(record, &e.to_string()).await,
        };

        let key = presence_key(&position.user_id);
        // Un estado ilegible (corrupto o de un formato antiguo) no debe
        // bloquear al usuario para siempre: se trata como "sin estado".
        let previous: Option<Presence> = self.presence.get(&key).await?.and_then(|bytes| {
            serde_json::from_slice(&bytes).inspect_err(|e| tracing::warn!(error = %e, "estado de presencia ilegible: se reinicia")).ok()
        });

        let (transitions, presence) = match geofence::evaluate(&position, previous.as_ref(), &snapshot, self.settings.max_accuracy_m) {
            Outcome::Ignored(reason) => {
                tracing::debug!(?reason, "posición ignorada");
                return Ok(Handled::Ignored);
            }
            Outcome::Evaluated { transitions, presence } => (transitions, presence),
        };

        // 1) Publicar cada cambio y esperar confirmación.
        for transition in &transitions {
            let (event_id, event) = geofence::transition_event(&position, transition, PRODUCER);
            let record = OutboundRecord {
                topic: self.settings.topic_transitions.clone(),
                key: position.user_id.as_bytes().to_vec(),
                payload: event.encode_to_vec(),
                headers: vec![
                    ("content-type".into(), CONTENT_TYPE_PROTOBUF.into()),
                    ("ce_specversion".into(), b"1.0".to_vec()),
                    ("ce_id".into(), event_id.to_string().into_bytes()),
                    ("ce_type".into(), TYPE_GEOFENCE_TRANSITIONED.into()),
                    ("ce_source".into(), PRODUCER.into()),
                    ("ce_time".into(), rfc3339_now().into_bytes()),
                ],
            };
            self.sink.send(record).await?;
        }
        // 2) Guardar el estado nuevo (solo después de publicar: ver stream/mod.rs).
        let bytes = serde_json::to_vec(&presence).map_err(|e| TransientError::Encode(e.to_string()))?;
        self.presence.set_ex(&key, bytes, self.settings.presence_ttl).await?;
        if !transitions.is_empty() {
            // Sin coordenadas ni nombres en el log: la ubicación es un dato personal.
            tracing::info!(transitions = transitions.len(), "cambios de zona publicados");
        }
        Ok(Handled::Published(transitions.len()))
    }

    /// Envía el mensaje ORIGINAL intacto a la DLQ con el motivo y su procedencia.
    async fn dead_letter(&self, record: &InboundRecord, reason: &str) -> Result<Handled, TransientError> {
        tracing::warn!(partition = record.partition, offset = record.offset, %reason, "posición inválida enviada a la DLQ");
        let mut headers = record.headers.clone();
        headers.extend([
            ("dlq_reason".to_owned(), reason.as_bytes().to_vec()),
            ("dlq_source_topic".to_owned(), record.topic.as_bytes().to_vec()),
            ("dlq_source_partition".to_owned(), record.partition.to_string().into_bytes()),
            ("dlq_source_offset".to_owned(), record.offset.to_string().into_bytes()),
        ]);
        self.sink
            .send(OutboundRecord {
                topic: self.settings.topic_dlq.clone(),
                key: record.key.clone().unwrap_or_default(),
                payload: record.payload.clone().unwrap_or_default(),
                headers,
            })
            .await?;
        Ok(Handled::DeadLettered)
    }
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX)).unwrap_or_default()
}

fn rfc3339_now() -> String {
    humantime::format_rfc3339_millis(SystemTime::now()).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cache::MemoryStore;
    use crate::proto::geo as pb;
    use crate::spatial::index::tests::sample_snapshot;
    use crate::stream::geofence::tests::position_msg;
    use std::sync::Mutex;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[derive(Debug, Default)]
    struct VecSink {
        sent: Mutex<Vec<OutboundRecord>>,
        fail: AtomicBool,
    }

    impl EventSink for VecSink {
        async fn send(&self, record: OutboundRecord) -> Result<(), SinkError> {
            if self.fail.load(Ordering::Relaxed) {
                return Err(SinkError("broker caído".into()));
            }
            if let Ok(mut sent) = self.sent.lock() {
                sent.push(record);
            }
            Ok(())
        }
    }

    impl VecSink {
        fn take(&self) -> Vec<OutboundRecord> {
            self.sent.lock().map(|mut v| std::mem::take(&mut *v)).unwrap_or_default()
        }
    }

    fn processor() -> (Processor<MemoryStore, VecSink>, MemoryStore, Arc<VecSink>) {
        let handle = SnapshotHandle::new();
        handle.publish(sample_snapshot());
        let store = MemoryStore::default();
        let sink = Arc::new(VecSink::default());
        let settings = ProcessorSettings {
            topic_transitions: "geo.geofence-transitions.v1".into(),
            topic_dlq: "geo.user-positions-dlq.v1".into(),
            max_accuracy_m: 100.0,
            presence_ttl: Duration::from_secs(3600),
        };
        (Processor::new(handle, Arc::new(store.clone()), sink.clone(), settings), store, sink)
    }

    fn record(lat: f64, lon: f64, ms: i64, event: u128) -> InboundRecord {
        InboundRecord {
            topic: "geo.user-positions.v1".into(),
            partition: 3,
            offset: 42,
            key: Some(b"ana".to_vec()),
            payload: Some(position_msg("ana", lat, lon, 10.0, ms, event).encode_to_vec()),
            headers: vec![("ce_id".into(), b"x".to_vec())],
        }
    }

    fn now() -> i64 {
        now_ms() - 10_000
    }

    #[tokio::test]
    async fn publica_entradas_con_cabeceras_y_guarda_estado() -> Result<(), TransientError> {
        let (p, store, sink) = processor();
        assert_eq!(p.handle(&record(40.4168, -3.7038, now(), 1)).await?, Handled::Published(2));
        let sent = sink.take();
        assert_eq!(sent.len(), 2);
        assert!(sent.iter().all(|r| r.topic == "geo.geofence-transitions.v1" && r.key == b"ana"));
        let event = pb::GeofenceTransitioned::decode(sent[0].payload.as_slice()).map_err(|e| SinkError(e.to_string()))?;
        assert_eq!(event.zone_slug, "madrid-centro");
        assert_eq!(event.transition, i32::from(pb::GeofenceTransitionType::Enter));
        let ce_type = sent[0].headers.iter().find(|(k, _)| k == "ce_type").map(|(_, v)| v.as_slice());
        assert_eq!(ce_type, Some(TYPE_GEOFENCE_TRANSITIONED.as_bytes()));
        assert_eq!(store.len(), 1);
        Ok(())
    }

    #[tokio::test]
    async fn reprocesar_tras_un_fallo_da_los_mismos_ids() -> Result<(), TransientError> {
        let (p, store, sink) = processor();
        // Redis falla DESPUÉS de publicar: el mensaje se reintentará.
        let msg = record(40.4168, -3.7038, now(), 1);
        store.fail.store(true, Ordering::Relaxed);
        assert!(p.handle(&msg).await.is_err(), "sin Redis no se puede leer el estado: reintentar");
        store.fail.store(false, Ordering::Relaxed);

        // Kafka falla: tampoco se confirma ni se guarda estado.
        sink.fail.store(true, Ordering::Relaxed);
        assert!(matches!(p.handle(&msg).await, Err(TransientError::Sink(_))));
        assert!(store.is_empty(), "sin publicar no se guarda estado");
        sink.fail.store(false, Ordering::Relaxed);

        // Al reintentar todo va bien; un segundo reintento (duplicado) se ignora.
        p.handle(&msg).await?;
        let first_ids: Vec<_> = sink.take().iter().map(|r| r.headers[2].1.clone()).collect();
        assert_eq!(p.handle(&msg).await?, Handled::Ignored, "misma posición = antigua");
        assert_eq!(first_ids.len(), 2);
        Ok(())
    }

    #[tokio::test]
    async fn mensajes_rotos_van_a_la_dlq_intactos() -> Result<(), TransientError> {
        let (p, store, sink) = processor();
        let mut broken = record(40.0, -3.0, now(), 1);
        broken.payload = Some(vec![0xde, 0xad]);
        assert_eq!(p.handle(&broken).await?, Handled::DeadLettered);
        let mut empty = record(40.0, -3.0, now(), 2);
        empty.payload = None;
        assert_eq!(p.handle(&empty).await?, Handled::DeadLettered);
        let sent = sink.take();
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0].topic, "geo.user-positions-dlq.v1");
        assert_eq!(sent[0].payload, vec![0xde, 0xad], "el contenido original se conserva");
        let header = |name: &str| sent[0].headers.iter().find(|(k, _)| k == name).map(|(_, v)| String::from_utf8_lossy(v).into_owned());
        assert_eq!(header("dlq_source_offset").as_deref(), Some("42"));
        assert_eq!(header("ce_id").as_deref(), Some("x"), "cabeceras originales conservadas");
        assert!(store.is_empty());
        Ok(())
    }

    #[tokio::test]
    async fn sin_foto_no_se_confirma_nada() {
        let p =
            Processor::new(SnapshotHandle::new(), Arc::new(MemoryStore::default()), Arc::new(VecSink::default()), processor().0.settings);
        assert!(matches!(p.handle(&record(40.0, -3.0, now(), 1)).await, Err(TransientError::NoSnapshot)));
    }

    #[tokio::test]
    async fn estado_corrupto_se_reinicia() -> Result<(), TransientError> {
        let (p, store, sink) = processor();
        store.set_ex(&presence_key("ana"), b"{no es json".to_vec(), Duration::from_secs(1)).await?;
        assert_eq!(p.handle(&record(40.4168, -3.7038, now(), 1)).await?, Handled::Published(2));
        assert_eq!(sink.take().len(), 2);
        Ok(())
    }
}
