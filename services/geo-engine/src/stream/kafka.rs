//! Conexión con Kafka mediante `rdkafka`.
//!
//! ## La única dependencia en C, y por qué
//! `rdkafka` envuelve librdkafka, el cliente de Kafka escrito en C que usan
//! también los clientes oficiales de Confluent para Python, Go y .NET: lleva
//! más de una década en producción en miles de empresas. Los clientes 100 %
//! Rust que existen hoy no gestionan bien los grupos de consumidores (el
//! reparto automático de particiones entre instancias), que es justo lo que
//! necesitamos para escalar.
//!
//! Para que esa excepción no contamine el resto (riesgo 2 del análisis):
//! - Todo el contacto con rdkafka vive en ESTE fichero. El resto del servicio
//!   solo ve [`InboundRecord`] y la interfaz [`EventSink`].
//! - Nada geoespacial pasa por C: la geometría es 100 % Rust.
//! - librdkafka se compila desde su código fuente en una versión fijada por
//!   Cargo.lock, no se toma "la que haya" en el sistema.

use std::sync::Arc;
use std::time::Duration;

use rdkafka::ClientConfig;
use rdkafka::consumer::{CommitMode, Consumer, StreamConsumer};
use rdkafka::error::KafkaError;
use rdkafka::message::{Header, Headers, Message, OwnedHeaders};
use rdkafka::producer::{FutureProducer, FutureRecord, Producer};
use rdkafka::util::Timeout;
use tokio_util::sync::CancellationToken;

use super::geofence::GeofenceRules;
use super::processor::{EventSink, InboundRecord, OutboundRecord, Processor, ProcessorSettings, SinkError, TransientError};
use crate::cache::KeyValueStore;
use crate::config::StreamConfig;
use crate::health::{StreamState, StreamStatus};
use crate::snapshot::SnapshotHandle;

/// Espera máxima entre reintentos de un mismo mensaje.
const MAX_BACKOFF: Duration = Duration::from_secs(10);

/// Configuración común a productor y consumidor.
fn base_config(cfg: &StreamConfig) -> ClientConfig {
    let mut config = ClientConfig::new();
    config.set("bootstrap.servers", cfg.brokers.join(",")).set("client.id", &cfg.client_id);
    if let Some(ca) = &cfg.tls_ca_file {
        // TLS hacia Kafka verificando el certificado del broker con nuestra CA.
        config
            .set("security.protocol", "ssl")
            .set("ssl.ca.location", ca.display().to_string())
            .set("ssl.endpoint.identification.algorithm", "https");
    }
    config
}

/// Productor: espera la confirmación de TODAS las réplicas (acks=all) y es
/// idempotente (Kafka descarta los duplicados que provocan sus propios reintentos).
pub fn producer(cfg: &StreamConfig) -> Result<FutureProducer, KafkaError> {
    base_config(cfg)
        .set("acks", "all")
        .set("enable.idempotence", "true")
        // zstd: la misma compresión que usan los servicios Go.
        .set("compression.type", "zstd")
        .set("linger.ms", "5")
        .set("message.timeout.ms", "30000")
        .create()
}

/// Consumidor del grupo `geo-engine`.
///
/// Confirmación "manual": rdkafka confirma periódicamente los offsets, pero
/// SOLO los que nosotros marcamos como procesados (`enable.auto.offset.store=false`).
/// Un mensaje solo se marca cuando su trabajo está terminado.
pub fn consumer(cfg: &StreamConfig) -> Result<StreamConsumer, KafkaError> {
    base_config(cfg)
        .set("group.id", &cfg.group_id)
        .set("enable.auto.commit", "true")
        .set("enable.auto.offset.store", "false")
        .set("auto.offset.reset", "earliest")
        // Reparto "cooperativo": al añadir una instancia no se paran todas.
        .set("partition.assignment.strategy", "cooperative-sticky")
        .set("session.timeout.ms", "45000")
        .create()
}

/// Publicador real sobre Kafka.
#[derive(Clone)]
pub struct KafkaSink {
    producer: FutureProducer,
}

impl std::fmt::Debug for KafkaSink {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("KafkaSink").finish_non_exhaustive()
    }
}

impl KafkaSink {
    /// Crea el publicador.
    pub fn new(producer: FutureProducer) -> Self {
        Self { producer }
    }

    /// Envía lo pendiente antes de apagar.
    pub fn flush(&self, timeout: Duration) {
        if let Err(e) = self.producer.flush(Timeout::After(timeout)) {
            tracing::warn!(error = %e, "no se pudieron enviar todos los mensajes antes de apagar");
        }
    }
}

impl EventSink for KafkaSink {
    async fn send(&self, record: OutboundRecord) -> Result<(), SinkError> {
        let mut headers = OwnedHeaders::new_with_capacity(record.headers.len());
        for (key, value) in &record.headers {
            headers = headers.insert(Header { key, value: Some(value) });
        }
        let future_record = FutureRecord::to(&record.topic).key(&record.key).payload(&record.payload).headers(headers);
        self.producer
            .send(future_record, Timeout::After(Duration::from_secs(5)))
            .await
            .map(|_| ())
            .map_err(|(e, _)| SinkError(e.to_string()))
    }
}

/// Copia del mensaje de Kafka a nuestro tipo neutro.
fn to_inbound<M: Message>(message: &M) -> InboundRecord {
    let headers = message
        .headers()
        .map(|h| h.iter().map(|header| (header.key.to_owned(), header.value.map(<[u8]>::to_vec).unwrap_or_default())).collect())
        .unwrap_or_default();
    InboundRecord {
        topic: message.topic().to_owned(),
        partition: message.partition(),
        offset: message.offset(),
        key: message.key().map(<[u8]>::to_vec),
        payload: message.payload().map(<[u8]>::to_vec),
        headers,
    }
}

/// Bucle principal del geofencing: lee, procesa (reintentando lo transitorio)
/// y marca como procesado. Termina limpiamente con `shutdown`.
pub async fn run<S: KeyValueStore>(
    cfg: StreamConfig,
    snapshots: SnapshotHandle,
    presence: Arc<S>,
    status: StreamStatus,
    shutdown: CancellationToken,
) -> Result<(), KafkaError> {
    status.set(StreamState::Starting);
    // No tiene sentido leer posiciones sin saber dónde están las zonas.
    while snapshots.load().is_none() {
        tokio::select! {
            () = shutdown.cancelled() => {
                status.set(StreamState::Stopped);
                return Ok(());
            }
            () = tokio::time::sleep(Duration::from_millis(500)) => {}
        }
    }
    let consumer = consumer(&cfg)?;
    consumer.subscribe(&[cfg.topic_positions.as_str()])?;
    let sink = Arc::new(KafkaSink::new(producer(&cfg)?));
    let processor = Processor::new(
        snapshots,
        presence,
        sink.clone(),
        ProcessorSettings {
            topic_transitions: cfg.topic_transitions.clone(),
            topic_zone_entries: cfg.topic_zone_entries.clone(),
            topic_dlq: cfg.topic_positions_dlq.clone(),
            rules: GeofenceRules {
                max_accuracy_m: cfg.max_accuracy_m,
                exit_margin_m: cfg.exit_margin_m,
                // Duration -> milisegundos (cabe de sobra: el máximo es 10 min).
                enter_dwell_ms: i64::try_from(cfg.enter_dwell.as_millis()).unwrap_or(i64::MAX),
            },
            presence_ttl: cfg.presence_ttl,
        },
    );
    status.set(StreamState::Running);
    tracing::info!(topic = %cfg.topic_positions, group = %cfg.group_id, "geofencing en streaming iniciado");

    'messages: loop {
        let message = tokio::select! {
            () = shutdown.cancelled() => break,
            message = consumer.recv() => message,
        };
        let message = match message {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!(error = %e, "error leyendo de Kafka");
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
        };
        let record = to_inbound(&message);
        let mut backoff = Duration::from_millis(100);
        loop {
            match processor.handle(&record).await {
                Ok(outcome) => {
                    tracing::debug!(?outcome, partition = record.partition, offset = record.offset, "posición procesada");
                    status.set(StreamState::Running);
                    break;
                }
                Err(e) => {
                    log_transient(&e, &record);
                    status.set(StreamState::Retrying);
                    tokio::select! {
                        // Al apagar, el mensaje queda SIN confirmar: se procesará al volver.
                        () = shutdown.cancelled() => break 'messages,
                        () = tokio::time::sleep(backoff) => {}
                    }
                    backoff = (backoff * 2).min(MAX_BACKOFF);
                }
            }
        }
        if let Err(e) = consumer.store_offset_from_message(&message) {
            tracing::warn!(error = %e, "no se pudo marcar el mensaje como procesado (se reprocesará)");
        }
    }

    // Apagado ordenado: enviar lo pendiente y confirmar lo procesado.
    sink.flush(Duration::from_secs(5));
    if let Err(e) = consumer.commit_consumer_state(CommitMode::Sync) {
        // "No offset stored" simplemente significa que no había nada nuevo.
        tracing::debug!(error = %e, "confirmación final de offsets");
    }
    status.set(StreamState::Stopped);
    tracing::info!("geofencing en streaming detenido");
    Ok(())
}

fn log_transient(error: &TransientError, record: &InboundRecord) {
    tracing::warn!(error = %error, partition = record.partition, offset = record.offset, "error transitorio: se reintentará el mensaje");
}
