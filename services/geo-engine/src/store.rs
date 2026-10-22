//! Acceso a PostgreSQL + PostGIS: la fuente de verdad geoespacial.
//!
//! El geo-engine habla con la base de datos POCO a propósito: al arrancar
//! (migraciones), y de vez en cuando para comprobar si los datos cambiaron y,
//! si es así, recargarlos enteros. Las peticiones de los usuarios nunca
//! esperan a PostgreSQL: se responden desde la copia en memoria.
//!
//! Cada consulta trae las geometrías como WKB (`ST_AsBinary`), el mismo
//! formato que luego viaja por gRPC: sin conversiones intermedias.

use std::collections::HashMap;
use std::time::Duration;

use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio_postgres::config::SslMode;
use tokio_postgres::{Client, IsolationLevel, NoTls};
use uuid::Uuid;

use crate::config::{PgTls, PostgresConfig};
use crate::tls;

/// Una migración: versión, nombre y SQL (incrustado en el binario al compilar,
/// así no hay ficheros sueltos que se puedan perder o modificar en producción).
struct Migration {
    version: i32,
    name: &'static str,
    sql: &'static str,
}

/// Migraciones en orden. NUNCA se edita una ya publicada: se añade otra nueva.
/// El checksum detecta si alguien cambió una aplicada (y el servicio se niega a arrancar).
const MIGRATIONS: &[Migration] = &[
    Migration { version: 1, name: "geo_schema", sql: include_str!("../migrations/0001_geo_schema.sql") },
    Migration { version: 2, name: "seed_airports", sql: include_str!("../migrations/0002_seed_airports.sql") },
];

/// Zonas de demostración (solo con SEED_DEMO_ZONES=true).
const DEMO_ZONES_SQL: &str = include_str!("../seeds/demo_zones.sql");

/// Número fijo para el "cerrojo consultivo" de PostgreSQL: si arrancan tres
/// réplicas a la vez, solo una aplica las migraciones; las otras esperan.
const MIGRATION_LOCK_ID: i64 = 0x6765_6f5f_6d69_6772; // "geo_migr" en hexadecimal

/// Errores de la capa de datos.
#[derive(Debug, Error)]
pub enum StoreError {
    /// Fallo de PostgreSQL (conexión, SQL...).
    #[error("PostgreSQL: {0}")]
    Postgres(#[from] tokio_postgres::Error),
    /// Fallo preparando TLS.
    #[error("TLS de PostgreSQL: {0}")]
    Tls(#[from] tls::TlsError),
    /// Una migración aplicada no coincide con la del binario.
    #[error(
        "la migración {version} ({name}) aplicada en la base de datos no coincide con la del binario: no se edita una migración publicada"
    )]
    ChecksumMismatch {
        /// Versión.
        version: i32,
        /// Nombre.
        name: &'static str,
    },
    /// Datos imposibles (por ejemplo, la tabla de versión vacía).
    #[error("datos inesperados: {0}")]
    Unexpected(String),
}

/// Fila de aeropuerto tal cual sale de la base de datos.
#[derive(Debug, Clone)]
pub struct AirportRow {
    /// IATA.
    pub iata_code: String,
    /// OACI ("" si no hay).
    pub icao_code: String,
    /// Nombre.
    pub name: String,
    /// Ciudad.
    pub city: String,
    /// País.
    pub country_code: String,
    /// Latitud.
    pub latitude: f64,
    /// Longitud.
    pub longitude: f64,
}

/// Fila de zona tal cual sale de la base de datos (sin validar todavía).
#[derive(Debug, Clone)]
pub struct ZoneRow {
    /// Id.
    pub zone_id: Uuid,
    /// Slug.
    pub slug: String,
    /// Nombre.
    pub name: String,
    /// Tipo (texto).
    pub kind: String,
    /// Geometría en WKB.
    pub wkb: Vec<u8>,
}

/// Todo el conjunto de datos, leído de una vez y de forma coherente.
#[derive(Debug, Clone)]
pub struct Dataset {
    /// Versión (`geo.dataset_version`) a la que corresponden los datos.
    pub version: i64,
    /// Aeropuertos.
    pub airports: Vec<AirportRow>,
    /// Zonas activas.
    pub zones: Vec<ZoneRow>,
}

/// Conexión a PostgreSQL que se reabre sola si se cae.
///
/// La usa una sola tarea (la que refresca la foto en memoria), así que no
/// hace falta un pool de conexiones: una basta y no compite con nadie.
#[derive(Debug)]
pub struct Store {
    config: PostgresConfig,
    client: Option<Client>,
}

impl Store {
    /// Crea el acceso (todavía sin conectar).
    pub fn new(config: PostgresConfig) -> Self {
        Self { config, client: None }
    }

    /// Devuelve una conexión abierta, reconectando si hace falta.
    async fn client(&mut self) -> Result<&mut Client, StoreError> {
        if self.client.as_ref().is_none_or(Client::is_closed) {
            self.client = Some(connect(&self.config).await?);
        }
        self.client.as_mut().ok_or_else(|| StoreError::Unexpected("conexión no disponible".into()))
    }

    /// Aplica las migraciones pendientes dentro de una transacción con cerrojo.
    pub async fn migrate(&mut self) -> Result<(), StoreError> {
        let client = self.client().await?;
        let tx = client.transaction().await?;
        tx.execute("SELECT pg_advisory_xact_lock($1)", &[&MIGRATION_LOCK_ID]).await?;
        tx.batch_execute(
            "CREATE SCHEMA IF NOT EXISTS geo;
             CREATE TABLE IF NOT EXISTS geo.geo_engine_migrations (
                 version    integer     PRIMARY KEY,
                 name       text        NOT NULL,
                 checksum   text        NOT NULL,
                 applied_at timestamptz NOT NULL DEFAULT now()
             );",
        )
        .await?;
        let applied: HashMap<i32, String> = tx
            .query("SELECT version, checksum FROM geo.geo_engine_migrations", &[])
            .await?
            .into_iter()
            .map(|row| (row.get(0), row.get(1)))
            .collect();
        for migration in MIGRATIONS {
            let checksum = hex::encode(Sha256::digest(migration.sql.as_bytes()));
            match applied.get(&migration.version) {
                Some(existing) if *existing == checksum => continue,
                Some(_) => return Err(StoreError::ChecksumMismatch { version: migration.version, name: migration.name }),
                None => {
                    tracing::info!(version = migration.version, name = migration.name, "aplicando migración");
                    tx.batch_execute(migration.sql).await?;
                    tx.execute(
                        "INSERT INTO geo.geo_engine_migrations (version, name, checksum) VALUES ($1, $2, $3)",
                        &[&migration.version, &migration.name, &checksum],
                    )
                    .await?;
                }
            }
        }
        tx.commit().await?;
        Ok(())
    }

    /// Carga las zonas de demostración (idempotente: ON CONFLICT DO NOTHING).
    pub async fn seed_demo_zones(&mut self) -> Result<(), StoreError> {
        self.client().await?.batch_execute(DEMO_ZONES_SQL).await?;
        Ok(())
    }

    /// Versión actual del conjunto de datos: una consulta diminuta para saber
    /// si merece la pena recargar todo.
    pub async fn dataset_version(&mut self) -> Result<i64, StoreError> {
        let row = self.client().await?.query_opt("SELECT version FROM geo.dataset_version", &[]).await?;
        row.map(|r| r.get(0)).ok_or_else(|| StoreError::Unexpected("geo.dataset_version está vacía".into()))
    }

    /// Lee aeropuertos, zonas y versión en una única transacción REPEATABLE
    /// READ de solo lectura: las tres lecturas ven la misma "foto" de la base
    /// de datos aunque alguien esté escribiendo a la vez.
    pub async fn load_dataset(&mut self) -> Result<Dataset, StoreError> {
        let client = self.client().await?;
        let tx = client.build_transaction().isolation_level(IsolationLevel::RepeatableRead).read_only(true).start().await?;
        let version: i64 = tx
            .query_opt("SELECT version FROM geo.dataset_version", &[])
            .await?
            .map(|r| r.get(0))
            .ok_or_else(|| StoreError::Unexpected("geo.dataset_version está vacía".into()))?;
        let airports = tx
            .query(
                "SELECT iata_code::text, coalesce(icao_code::text, ''), name, city, country_code::text,
                        ST_Y(location::geometry), ST_X(location::geometry)
                   FROM geo.airports ORDER BY iata_code",
                &[],
            )
            .await?
            .into_iter()
            .map(|r| AirportRow {
                iata_code: r.get(0),
                icao_code: r.get(1),
                name: r.get(2),
                city: r.get(3),
                country_code: r.get(4),
                latitude: r.get(5),
                longitude: r.get(6),
            })
            .collect();
        let zones = tx
            .query("SELECT zone_id, slug, name, kind, ST_AsBinary(geom) FROM geo.zones WHERE active ORDER BY slug", &[])
            .await?
            .into_iter()
            .map(|r| ZoneRow { zone_id: r.get(0), slug: r.get(1), name: r.get(2), kind: r.get(3), wkb: r.get(4) })
            .collect();
        tx.commit().await?;
        Ok(Dataset { version, airports, zones })
    }
}

/// Abre una conexión nueva con o sin TLS según la configuración.
async fn connect(config: &PostgresConfig) -> Result<Client, StoreError> {
    let mut pg = tokio_postgres::Config::new();
    pg.host(&config.host)
        .port(config.port)
        .user(&config.user)
        .password(config.password.expose())
        .dbname(&config.database)
        .application_name("geo-engine")
        .connect_timeout(Duration::from_secs(5));
    // La conexión real la gestiona una tarea aparte ("connection"); el
    // `Client` solo envía peticiones a esa tarea.
    let client = match &config.tls {
        PgTls::Disable => {
            pg.ssl_mode(SslMode::Disable);
            let (client, connection) = pg.connect(NoTls).await?;
            spawn_connection(connection);
            client
        }
        PgTls::VerifyFull { root_cert } => {
            // rustls siempre verifica el certificado Y el nombre del servidor:
            // equivale a "verify-full".
            pg.ssl_mode(SslMode::Require);
            let tls_config = tls::client_config(tls::load_roots(root_cert)?)?;
            let (client, connection) = pg.connect(tokio_postgres_rustls::MakeRustlsConnect::new(tls_config)).await?;
            spawn_connection(connection);
            client
        }
    };
    Ok(client)
}

fn spawn_connection<F>(connection: F)
where
    F: std::future::Future<Output = Result<(), tokio_postgres::Error>> + Send + 'static,
{
    tokio::spawn(async move {
        if let Err(e) = connection.await {
            tracing::warn!(error = %e, "conexión con PostgreSQL cerrada");
        }
    });
}
