//! Punto de entrada del geo-engine: lee la configuración, conecta las piezas
//! y las mantiene en marcha hasta recibir la orden de apagado.
//!
//! Orden de arranque (cada paso depende del anterior):
//! 1. Configuración y logs.
//! 2. PostgreSQL: migraciones (y zonas de demo si se piden).
//! 3. Tarea que mantiene la foto en memoria al día.
//! 4. Redis (perezoso: no bloquea el arranque).
//! 5. Endpoints de salud, gRPC y, si está activo, el geofencing por Kafka.
//!
//! Apagado (SIGTERM de Docker/Kubernetes o Ctrl+C): se avisa a todas las
//! tareas con un `CancellationToken`, el gRPC deja de aceptar peticiones
//! nuevas y termina las que tiene, Kafka confirma lo procesado, y si algo
//! tarda más de SHUTDOWN_TIMEOUT se corta.

use std::process::ExitCode;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio_util::sync::CancellationToken;
use tonic::transport::Server;
use tracing_subscriber::EnvFilter;

use geo_engine::api::{self, ApiState, PositionsTarget};
use geo_engine::cache::RedisStore;
use geo_engine::config::Config;
use geo_engine::grpc::{GeoServiceImpl, RouteSettings};
use geo_engine::health::{self, HealthState, StreamState, StreamStatus};
use geo_engine::proto::geo::geo_service_server::GeoServiceServer;
use geo_engine::snapshot::{self, SnapshotHandle};
use geo_engine::store::Store;
use geo_engine::stream::kafka::KafkaSink;
use geo_engine::{stream, tls};

/// Tamaño máximo de un mensaje gRPC recibido (1 MiB): ninguna petición
/// legítima de este servicio se acerca; protege la memoria.
const MAX_GRPC_MESSAGE_BYTES: usize = 1024 * 1024;

fn main() -> ExitCode {
    // Modo "healthcheck" para el HEALTHCHECK de Docker: la imagen final no
    // tiene curl ni shell (menos superficie de ataque), así que el propio
    // binario hace la comprobación.
    if std::env::args().nth(1).as_deref() == Some("--healthcheck") {
        return healthcheck();
    }
    let config = match Config::from_env() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return ExitCode::FAILURE;
        }
    };
    init_logging(&config);
    // rustls necesita saber qué criptografía usar en todo el proceso (Redis
    // la toma de aquí). Si ya había una instalada, no pasa nada.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let runtime = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(e) => {
            tracing::error!(error = %e, "no se pudo crear el runtime de Tokio");
            return ExitCode::FAILURE;
        }
    };
    match runtime.block_on(run(config)) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            tracing::error!(error = %e, "el geo-engine terminó con error");
            ExitCode::FAILURE
        }
    }
}

fn init_logging(config: &Config) {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(format!("{},rdkafka=warn,h2=warn,tower=warn", config.log_level)));
    let builder = tracing_subscriber::fmt().with_env_filter(filter).with_target(false);
    if config.log_json {
        builder.json().flatten_event(true).init();
    } else {
        builder.init();
    }
}

/// Error de arranque con un mensaje claro.
#[derive(Debug, thiserror::Error)]
enum StartupError {
    #[error("PostgreSQL: {0}")]
    Store(#[from] geo_engine::store::StoreError),
    #[error("Redis: {0}")]
    Cache(#[from] geo_engine::cache::CacheError),
    #[error("TLS del gRPC: {0}")]
    Tls(#[from] tls::TlsError),
    #[error("no se pudo abrir {addr}: {source}")]
    Bind { addr: std::net::SocketAddr, source: std::io::Error },
    #[error("servidor gRPC: {0}")]
    Grpc(#[from] tonic::transport::Error),
    #[error("Kafka (API de posiciones): {0}")]
    Kafka(#[from] rdkafka::error::KafkaError),
}

async fn run(config: Config) -> Result<(), StartupError> {
    tracing::info!(grpc = %config.grpc_addr, http = %config.http_addr, api = %config.api_addr, mtls = config.grpc_tls.is_some(), "arrancando geo-engine");
    if config.grpc_tls.is_none() {
        tracing::warn!("gRPC SIN mTLS (GRPC_INSECURE_DEV=true): solo para desarrollo local");
    }
    let shutdown = CancellationToken::new();
    spawn_signal_handler(shutdown.clone());

    // --- PostgreSQL: migraciones antes de nada. Si fallan, no arrancamos.
    let mut store = Store::new(config.postgres.clone());
    store.migrate().await?;
    if config.seed_demo_zones {
        store.seed_demo_zones().await?;
        tracing::info!("zonas de demostración cargadas");
    }

    // --- Foto en memoria, refrescada en segundo plano.
    let snapshots = SnapshotHandle::new();
    let refresher = tokio::spawn(snapshot::run_refresher(store, snapshots.clone(), config.snapshot_refresh_interval, shutdown.clone()));

    // --- Redis.
    let redis = RedisStore::connect(&config.redis)?;
    let redis_shared = Arc::new(redis.clone());

    // --- Salud.
    let stream_status = StreamStatus::default();
    let health_listener =
        TcpListener::bind(config.http_addr).await.map_err(|source| StartupError::Bind { addr: config.http_addr, source })?;
    let health_app = health::router(HealthState { snapshots: snapshots.clone(), redis: redis.clone(), stream: stream_status.clone() });
    let health_shutdown = shutdown.clone();
    let health_task = tokio::spawn(async move {
        let served = axum::serve(health_listener, health_app).with_graceful_shutdown(health_shutdown.cancelled_owned()).await;
        if let Err(e) = served {
            tracing::error!(error = %e, "servidor de salud detenido");
        }
    });

    // --- API HTTP pública (/v1/zones, /v1/positions), con el mismo mTLS que el gRPC.
    let api_sink = match &config.stream {
        Some(stream_config) => Some(Arc::new(KafkaSink::new(stream::kafka::producer(stream_config)?))),
        None => None,
    };
    let api_app = api::router(ApiState {
        snapshots: snapshots.clone(),
        positions: match (&api_sink, &config.stream) {
            (Some(sink), Some(stream_config)) => Some(PositionsTarget { sink: sink.clone(), topic: stream_config.topic_positions.clone() }),
            _ => None,
        },
    });
    let api_listener = TcpListener::bind(config.api_addr).await.map_err(|source| StartupError::Bind { addr: config.api_addr, source })?;
    let api_shutdown = shutdown.clone();
    let api_task = match &config.grpc_tls {
        Some(files) => {
            let listener = tls::AxumTlsListener::new(
                api_listener,
                tls::server_config(files)?,
                tls::ClientAllowlist::new(config.api_allowed_clients.clone()),
            )
            .map_err(|source| StartupError::Bind { addr: config.api_addr, source })?;
            tokio::spawn(async move {
                if let Err(e) = axum::serve(listener, api_app).with_graceful_shutdown(api_shutdown.cancelled_owned()).await {
                    tracing::error!(error = %e, "API HTTP detenida");
                }
            })
        }
        None => tokio::spawn(async move {
            if let Err(e) = axum::serve(api_listener, api_app).with_graceful_shutdown(api_shutdown.cancelled_owned()).await {
                tracing::error!(error = %e, "API HTTP detenida");
            }
        }),
    };

    // --- Geofencing por Kafka.
    let stream_task = match config.stream.clone() {
        Some(stream_config) => {
            let (snaps, presence, status, stop) = (snapshots.clone(), redis_shared.clone(), stream_status.clone(), shutdown.clone());
            Some(tokio::spawn(async move {
                if let Err(e) = stream::kafka::run(stream_config, snaps, presence, status.clone(), stop.clone()).await {
                    status.set(StreamState::Stopped);
                    tracing::error!(error = %e, "el geofencing por Kafka no pudo arrancar; se apaga el servicio para que el orquestador lo reinicie");
                    stop.cancel();
                }
            }))
        }
        None => {
            stream_status.set(StreamState::Disabled);
            None
        }
    };

    // --- gRPC.
    let service = GeoServiceImpl::new(
        snapshots.clone(),
        redis_shared,
        RouteSettings {
            max_stops: config.route_max_stops,
            exact_max_stops: config.route_exact_max_stops,
            cache_ttl: config.route_cache_ttl,
            max_concurrency: config.route_max_concurrency,
            queue_timeout: Duration::from_secs(2),
        },
    );
    let grpc_service = GeoServiceServer::new(service).max_decoding_message_size(MAX_GRPC_MESSAGE_BYTES);
    let listener = TcpListener::bind(config.grpc_addr).await.map_err(|source| StartupError::Bind { addr: config.grpc_addr, source })?;
    let mut builder = Server::builder()
        // Ninguna petición puede durar más de 10 s (también respeta el
        // "grpc-timeout" que mande el cliente, si es menor).
        .timeout(Duration::from_secs(10))
        .concurrency_limit_per_connection(256)
        .http2_keepalive_interval(Some(Duration::from_secs(30)))
        .http2_keepalive_timeout(Some(Duration::from_secs(10)));
    let router = builder.add_service(grpc_service);
    let grpc_shutdown = shutdown.clone().cancelled_owned();
    let served = match &config.grpc_tls {
        Some(files) => {
            let tls_config = tls::server_config(files)?;
            let incoming = tls::verified_incoming(listener, tls_config, tls::ClientAllowlist::new(config.grpc_allowed_clients.clone()));
            router.serve_with_incoming_shutdown(incoming, grpc_shutdown).await
        }
        None => {
            let incoming = tokio_stream::wrappers::TcpListenerStream::new(listener);
            router.serve_with_incoming_shutdown(incoming, grpc_shutdown).await
        }
    };
    // Si el gRPC terminó (por apagado o por error), que paren todos.
    shutdown.cancel();
    served?;

    // Esperar a que las tareas terminen, con límite de tiempo.
    let wait_all = async {
        let _ = refresher.await;
        let _ = health_task.await;
        let _ = api_task.await;
        if let Some(sink) = &api_sink {
            sink.flush(Duration::from_secs(5));
        }
        if let Some(task) = stream_task {
            let _ = task.await;
        }
    };
    if tokio::time::timeout(config.shutdown_timeout, wait_all).await.is_err() {
        tracing::warn!("apagado forzado: algunas tareas no terminaron a tiempo");
    }
    tracing::info!("geo-engine detenido");
    Ok(())
}

/// Cancela el token al recibir Ctrl+C o SIGTERM.
fn spawn_signal_handler(shutdown: CancellationToken) {
    tokio::spawn(async move {
        let ctrl_c = async {
            let _ = tokio::signal::ctrl_c().await;
        };
        #[cfg(unix)]
        let terminate = async {
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(mut s) => {
                    s.recv().await;
                }
                Err(e) => {
                    tracing::warn!(error = %e, "no se pudo escuchar SIGTERM");
                    std::future::pending::<()>().await;
                }
            }
        };
        #[cfg(not(unix))]
        let terminate = std::future::pending::<()>();
        tokio::select! {
            () = ctrl_c => {}
            () = terminate => {}
        }
        tracing::info!("señal de apagado recibida");
        shutdown.cancel();
    });
}

/// `geo-engine --healthcheck`: pide /readyz al propio servicio y devuelve 0
/// si responde 200. Usa un HTTP mínimo a mano para no añadir dependencias.
fn healthcheck() -> ExitCode {
    let port = std::env::var("HTTP_ADDR").ok().and_then(|a| a.rsplit(':').next().and_then(|p| p.parse::<u16>().ok())).unwrap_or(8087);
    let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
        Ok(rt) => rt,
        Err(_) => return ExitCode::FAILURE,
    };
    let ok = runtime.block_on(async move {
        let check = async {
            let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", port)).await.ok()?;
            stream.write_all(b"GET /readyz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n").await.ok()?;
            let mut buf = [0u8; 16];
            let n = stream.read(&mut buf).await.ok()?;
            Some(buf[..n].starts_with(b"HTTP/1.1 200"))
        };
        tokio::time::timeout(Duration::from_secs(3), check).await.ok().flatten().unwrap_or(false)
    });
    if ok { ExitCode::SUCCESS } else { ExitCode::FAILURE }
}
