//! Tests de integración contra PostgreSQL+PostGIS, Redis y Kafka REALES.
//!
//! No se ejecutan con un `cargo test` normal (están marcados `#[ignore]`):
//! necesitan la infraestructura de docker compose. Para lanzarlos:
//!
//! ```text
//! make up                       # desde la raíz del repo
//! make test-rust-integration    # o: cargo test --test integration -- --ignored
//! ```
//!
//! Los dos tests "e2e" hablan además con el geo-engine arrancado en su
//! contenedor (`make up-apps`); si GEO_ENGINE_GRPC no está definida, avisan y no hacen nada.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use geo_engine::cache::{KeyValueStore, RedisStore};
use geo_engine::config::{PgTls, PostgresConfig, RedisConfig, RedisTls, Secret};
use geo_engine::proto::geo::geo_service_client::GeoServiceClient;
use geo_engine::proto::{common, geo as pb};
use geo_engine::snapshot::{self, SnapshotHandle};
use geo_engine::spatial::LatLng;
use geo_engine::store::Store;
use prost::Message as _;
use rdkafka::ClientConfig;
use rdkafka::consumer::{Consumer, StreamConsumer};
use rdkafka::message::Message as _;
use rdkafka::producer::{FutureProducer, FutureRecord};
use uuid::Uuid;

type TestResult = Result<(), Box<dyn std::error::Error>>;

fn env(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_owned())
}

fn pg_config() -> PostgresConfig {
    PostgresConfig {
        host: env("PGHOST", "localhost"),
        port: env("PGPORT", "5432").parse().unwrap_or(5432),
        user: env("PGUSER", "nomadiq"),
        password: Secret::new(env("PGPASSWORD", "")),
        database: env("PGDATABASE", "nomadiq"),
        tls: PgTls::Disable,
    }
}

#[tokio::test]
#[ignore = "necesita PostgreSQL con PostGIS (make up)"]
async fn postgis_migraciones_carga_y_deteccion_de_cambios() -> TestResult {
    let mut store = Store::new(pg_config());
    // Dos veces: las migraciones deben ser idempotentes (la segunda no hace nada).
    store.migrate().await?;
    store.migrate().await?;
    store.seed_demo_zones().await?;

    let handle = SnapshotHandle::new();
    assert!(snapshot::refresh_once(&mut store, &handle).await?, "la primera carga publica una foto");
    let snap = handle.load().ok_or("sin foto")?;
    assert!(snap.airport_count() > 1000, "aeropuertos: {}", snap.airport_count());
    assert!(snap.zone_count() >= 6, "zonas: {}", snap.zone_count());
    assert_eq!(handle.rejected_rows(), 0);

    let sol = LatLng::new(40.4168, -3.7038)?;
    let nearest = snap.nearest_airports(sol, 1, None);
    assert_eq!(nearest.first().map(|(a, _)| a.iata_code.as_str()), Some("MAD"));
    let zones: Vec<_> = snap.zones_containing(sol).iter().map(|z| z.slug.clone()).collect();
    assert!(zones.contains(&"madrid-centro".to_owned()), "{zones:?}");

    // Sin cambios en la base de datos: no se reconstruye nada.
    assert!(!snapshot::refresh_once(&mut store, &handle).await?);

    // Un cambio cualquiera sube la versión y provoca una foto nueva.
    let cfg = pg_config();
    let (client, connection) = tokio_postgres::Config::new()
        .host(&cfg.host)
        .port(cfg.port)
        .user(&cfg.user)
        .password(cfg.password.expose())
        .dbname(&cfg.database)
        .connect(tokio_postgres::NoTls)
        .await?;
    tokio::spawn(connection);
    client.execute("UPDATE geo.zones SET name = name WHERE slug = 'madrid-centro'", &[]).await?;
    assert!(snapshot::refresh_once(&mut store, &handle).await?, "tras un UPDATE se publica otra foto");

    // PostGIS rechaza un polígono que se cruza a sí mismo (defensa en profundidad).
    let invalid = client
        .execute(
            "INSERT INTO geo.zones (slug, name, kind, geom) VALUES ('pajarita', 'X', 'CITY_CENTER',
             ST_Multi(ST_GeomFromText('POLYGON((0 0, 1 1, 1 0, 0 1, 0 0))', 4326)))",
            &[],
        )
        .await;
    assert!(invalid.is_err(), "un polígono inválido no debe entrar en la base de datos");
    Ok(())
}

#[tokio::test]
#[ignore = "necesita Redis (make up)"]
async fn redis_real_guarda_y_caduca() -> TestResult {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let redis = RedisStore::connect(&RedisConfig {
        host: env("REDIS_HOST", "localhost"),
        port: 6379,
        password: Secret::new(env("REDIS_PASSWORD", "")),
        tls: RedisTls::Disable,
        op_timeout: Duration::from_secs(1),
    })?;
    redis.ping().await?;
    let key = format!("geo:test:{}", Uuid::new_v4());
    redis.set_ex(&key, b"hola".to_vec(), Duration::from_secs(1)).await?;
    assert_eq!(redis.get(&key).await?, Some(b"hola".to_vec()));
    tokio::time::sleep(Duration::from_millis(2100)).await;
    assert_eq!(redis.get(&key).await?, None, "la entrada caduca sola");
    Ok(())
}

/// Dirección del geo-engine en contenedor, o None para saltar el test.
fn e2e_target() -> Option<String> {
    let target = std::env::var("GEO_ENGINE_GRPC").ok();
    if target.is_none() {
        eprintln!("GEO_ENGINE_GRPC no definida: se omite el test e2e (arranca el servicio con make up-apps)");
    }
    target
}

fn point(lat: f64, lon: f64) -> Option<pb::LatLng> {
    Some(pb::LatLng { latitude: lat, longitude: lon })
}

#[tokio::test]
#[ignore = "necesita el geo-engine en marcha (make up-apps)"]
async fn e2e_grpc_contra_el_contenedor() -> TestResult {
    let Some(target) = e2e_target() else { return Ok(()) };
    let mut client = GeoServiceClient::connect(target).await?;

    let airports = client
        .find_nearest_airports(pb::FindNearestAirportsRequest { point: point(40.4168, -3.7038), limit: 3, max_distance_meters: 0.0 })
        .await?
        .into_inner();
    assert_eq!(airports.airports.first().and_then(|a| a.airport.as_ref()).map(|a| a.iata_code.as_str()), Some("MAD"));

    let zones = client.locate_zones(pb::LocateZonesRequest { point: point(40.4168, -3.7038), include_geometry: true }).await?.into_inner();
    let centro = zones.zones.iter().find(|z| z.slug == "madrid-centro").ok_or("madrid-centro no encontrada")?;
    assert!(centro.geometry.as_ref().is_some_and(|g| !g.wkb.is_empty()), "la geometría llega en WKB");

    // Ruta con ids únicos para no chocar con ejecuciones anteriores: la
    // primera vez se calcula y la segunda sale de Redis.
    let run = Uuid::new_v4().simple().to_string();
    let stop = |name: &str, lat, lon| pb::RouteStop { stop_id: format!("{name}-{run}"), location: point(lat, lon) };
    let request = pb::OptimizeRouteRequest {
        stops: vec![stop("hotel", 40.4168, -3.7038), stop("prado", 40.4138, -3.6921), stop("palacio", 40.4180, -3.7144), stop("retiro", 40.4153, -3.6845)],
        shape: pb::RouteShape::RoundTrip.into(),
    };
    let first = client.optimize_route(request.clone()).await?.into_inner();
    assert!(!first.from_cache && first.optimal);
    let second = client.optimize_route(request).await?.into_inner();
    assert!(second.from_cache, "el reintento debe salir de la caché de Redis");
    assert_eq!(first.ordered_stop_ids, second.ordered_stop_ids);
    Ok(())
}

#[tokio::test]
#[ignore = "necesita el geo-engine en marcha (make up-apps)"]
async fn e2e_geofencing_por_kafka() -> TestResult {
    if e2e_target().is_none() {
        return Ok(());
    }
    let brokers = env("KAFKA_BROKERS", "localhost:29092");
    let user_id = format!("e2e-{}", Uuid::new_v4());
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?;
    let position = pb::UserPositionReported {
        metadata: Some(common::EventMetadata {
            event_id: Uuid::new_v4().to_string(),
            occurred_at: Some(prost_types::Timestamp { seconds: i64::try_from(now.as_secs())?, nanos: 0 }),
            producer: "e2e-test".into(),
            correlation_id: String::new(),
        }),
        user_id: user_id.clone(),
        position: point(40.4168, -3.7038), // Puerta del Sol
        horizontal_accuracy_meters: 8.0,
    };
    let producer: FutureProducer = ClientConfig::new().set("bootstrap.servers", &brokers).create()?;
    let payload = position.encode_to_vec();
    producer
        .send(FutureRecord::to("geo.user-positions.v1").key(user_id.as_bytes()).payload(&payload), Duration::from_secs(10))
        .await
        .map_err(|(e, _)| e)?;

    // Grupo nuevo + "earliest": leemos el topic desde el principio y buscamos
    // los eventos de NUESTRO usuario (el user_id es único en cada ejecución).
    let consumer: StreamConsumer = ClientConfig::new()
        .set("bootstrap.servers", &brokers)
        .set("group.id", format!("e2e-{}", Uuid::new_v4()))
        .set("auto.offset.reset", "earliest")
        .set("enable.auto.commit", "false")
        .create()?;
    consumer.subscribe(&["geo.geofence-transitions.v1"])?;
    let deadline = Instant::now() + Duration::from_secs(60);
    let mut entered = Vec::new();
    while Instant::now() < deadline && !entered.contains(&"madrid-centro".to_owned()) {
        let Ok(Ok(message)) = tokio::time::timeout(Duration::from_secs(5), consumer.recv()).await else { continue };
        if message.key() != Some(user_id.as_bytes()) {
            continue;
        }
        let event = pb::GeofenceTransitioned::decode(message.payload().unwrap_or_default())?;
        assert_eq!(event.transition, i32::from(pb::GeofenceTransitionType::Enter));
        entered.push(event.zone_slug);
    }
    assert!(entered.contains(&"madrid-centro".to_owned()), "no llegó la entrada en madrid-centro: {entered:?}");
    Ok(())
}
