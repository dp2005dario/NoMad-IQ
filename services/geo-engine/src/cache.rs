//! Redis: caché de rutas calculadas y memoria de "en qué zonas está cada usuario".
//!
//! ## ¿Por qué una caché de rutas? (riesgo 5 del análisis)
//! Optimizar una ruta con muchas paradas cuesta CPU. Si la app no recibe la
//! respuesta a tiempo (túnel, mala cobertura) reintenta la MISMA petición.
//! Sin caché recalcularíamos lo mismo una y otra vez. Con caché:
//! - La clave es una huella (SHA-256) del CONTENIDO de la petición. La misma
//!   petición produce siempre la misma clave, así que un reintento encuentra
//!   el resultado ya hecho: la operación es idempotente por construcción, sin
//!   que la app tenga que inventar identificadores de petición.
//! - Las entradas caducan solas (TTL, 15 min por defecto): la caché nunca crece
//!   sin límite.
//!
//! ## ¿Por qué NO cacheamos las distancias simples?
//! Calcular una distancia geodésica cuesta ~1 microsegundo; ir a Redis y
//! volver, ~200-500 microsegundos. Cachear lo barato lo haría MÁS lento.
//!
//! ## Si Redis falla
//! Para las rutas, la caché es una optimización: si Redis no responde en
//! `REDIS_OP_TIMEOUT` (250 ms) se calcula igualmente ("fail-open"). El
//! servicio sigue funcionando, solo que sin el atajo.

use std::collections::HashMap;
use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use redis::aio::{ConnectionManager, ConnectionManagerConfig};
use redis::{AsyncCommands, ConnectionAddr, ConnectionInfo, IntoConnectionInfo, RedisConnectionInfo, TlsCertificates};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::config::{RedisConfig, RedisTls};
use crate::spatial::LatLng;
use crate::spatial::route::RouteShape;

/// Errores de la caché.
#[derive(Debug, Error)]
pub enum CacheError {
    /// Redis devolvió un error o la conexión falló.
    #[error("Redis: {0}")]
    Redis(#[from] redis::RedisError),
    /// Redis no respondió a tiempo.
    #[error("Redis no respondió en {0:?}")]
    Timeout(Duration),
    /// No se pudo leer la CA de Redis.
    #[error("no se pudo leer REDIS_TLS_CA_FILE: {0}")]
    CaFile(std::io::Error),
}

/// Almacén clave-valor con caducidad. Es una "interfaz" (trait): en
/// producción la implementa Redis y en los tests una versión en memoria, así
/// los tests no necesitan un Redis de verdad.
pub trait KeyValueStore: Send + Sync + 'static {
    /// Lee un valor (None si no existe o caducó).
    fn get(&self, key: &str) -> impl Future<Output = Result<Option<Vec<u8>>, CacheError>> + Send;
    /// Guarda un valor que caduca tras `ttl`.
    fn set_ex(&self, key: &str, value: Vec<u8>, ttl: Duration) -> impl Future<Output = Result<(), CacheError>> + Send;
}

/// Cliente de Redis con reconexión automática.
#[derive(Clone)]
pub struct RedisStore {
    conn: ConnectionManager,
    op_timeout: Duration,
}

impl std::fmt::Debug for RedisStore {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RedisStore").field("op_timeout", &self.op_timeout).finish_non_exhaustive()
    }
}

impl RedisStore {
    /// Prepara el cliente SIN conectar todavía ("lazy"): si Redis no está
    /// disponible al arrancar, el servicio arranca igual y conecta cuando pueda.
    pub fn connect(config: &RedisConfig) -> Result<Self, CacheError> {
        let settings = RedisConnectionInfo::default().set_password(config.password.expose());
        let client = match &config.tls {
            RedisTls::Disable => {
                let info: ConnectionInfo = ConnectionAddr::Tcp(config.host.clone(), config.port).into_connection_info()?;
                redis::Client::open(info.set_redis_settings(settings))?
            }
            RedisTls::Enabled { ca_file } => {
                // insecure: false → se comprueba que el certificado es del host
                // al que conectamos (evita ataques de intermediario).
                let addr = ConnectionAddr::TcpTls { host: config.host.clone(), port: config.port, insecure: false, tls_params: None };
                let info = addr.into_connection_info()?.set_redis_settings(settings);
                let root_cert = ca_file.as_ref().map(std::fs::read).transpose().map_err(CacheError::CaFile)?;
                redis::Client::build_with_tls(info, TlsCertificates { client_tls: None, root_cert })?
            }
        };
        let manager_config = ConnectionManagerConfig::new()
            .set_connection_timeout(Some(Duration::from_secs(2)))
            .set_response_timeout(Some(config.op_timeout))
            .set_number_of_retries(2)
            .set_max_delay(Duration::from_secs(2));
        let conn = ConnectionManager::new_lazy_with_config(client, manager_config)?;
        Ok(Self { conn, op_timeout: config.op_timeout })
    }

    /// Comprueba que Redis responde (para /readyz).
    pub async fn ping(&self) -> Result<(), CacheError> {
        let mut conn = self.conn.clone();
        self.bounded(async move { redis::cmd("PING").query_async::<String>(&mut conn).await }).await?;
        Ok(())
    }

    /// Ejecuta una operación con tiempo máximo.
    async fn bounded<T>(&self, op: impl Future<Output = redis::RedisResult<T>>) -> Result<T, CacheError> {
        match tokio::time::timeout(self.op_timeout, op).await {
            Ok(result) => Ok(result?),
            Err(_) => Err(CacheError::Timeout(self.op_timeout)),
        }
    }
}

impl KeyValueStore for RedisStore {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, CacheError> {
        // ConnectionManager se clona barato: todas las copias comparten la misma conexión.
        let mut conn = self.conn.clone();
        self.bounded(async move { conn.get::<_, Option<Vec<u8>>>(key).await }).await
    }

    async fn set_ex(&self, key: &str, value: Vec<u8>, ttl: Duration) -> Result<(), CacheError> {
        let mut conn = self.conn.clone();
        let seconds = ttl.as_secs().max(1);
        self.bounded(async move { conn.set_ex::<_, _, ()>(key, value, seconds).await }).await
    }
}

/// Implementación en memoria para tests (sin caducidad real).
#[derive(Debug, Default, Clone)]
pub struct MemoryStore {
    data: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    /// Si es true, todas las operaciones fallan (simula Redis caído).
    pub fail: Arc<std::sync::atomic::AtomicBool>,
}

impl MemoryStore {
    fn check(&self) -> Result<(), CacheError> {
        if self.fail.load(std::sync::atomic::Ordering::Relaxed) { Err(CacheError::Timeout(Duration::ZERO)) } else { Ok(()) }
    }

    /// Número de claves guardadas.
    pub fn len(&self) -> usize {
        self.data.lock().map(|d| d.len()).unwrap_or_default()
    }

    /// true si no hay claves.
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl KeyValueStore for MemoryStore {
    async fn get(&self, key: &str) -> Result<Option<Vec<u8>>, CacheError> {
        self.check()?;
        Ok(self.data.lock().ok().and_then(|d| d.get(key).cloned()))
    }

    async fn set_ex(&self, key: &str, value: Vec<u8>, _ttl: Duration) -> Result<(), CacheError> {
        self.check()?;
        if let Ok(mut d) = self.data.lock() {
            d.insert(key.to_owned(), value);
        }
        Ok(())
    }
}

/// Precisión con la que se redondean las coordenadas en la clave: 1e-6 grados
/// son ~11 cm. Dos peticiones que solo difieren en ruido de coma flotante
/// comparten resultado, sin mezclar lugares realmente distintos.
const KEY_COORD_SCALE: f64 = 1e6;

/// Clave de caché de una ruta: `geo:route:v1:<sha256 en hexadecimal>`.
///
/// Incluye todo lo que cambia el resultado (forma, paradas con su id y
/// posición, en orden) y nada más. El "v1" permite invalidar todas las
/// entradas de golpe si algún día cambia el algoritmo: basta con pasar a "v2".
pub fn route_cache_key(stops: &[(String, LatLng)], shape: RouteShape, exact_max_stops: usize) -> String {
    let mut hasher = Sha256::new();
    hasher.update(match shape {
        RouteShape::Open => b"open\0".as_slice(),
        RouteShape::RoundTrip => b"round\0".as_slice(),
    });
    // El límite del algoritmo exacto cambia el resultado (exacto o heurístico).
    hasher.update((exact_max_stops as u64).to_le_bytes());
    for (id, point) in stops {
        // Longitud + contenido: evita que ("ab","c") y ("a","bc") coincidan.
        hasher.update((id.len() as u64).to_le_bytes());
        hasher.update(id.as_bytes());
        // `as i64` tras redondear: el valor cabe de sobra (máximo 180e6).
        #[allow(clippy::cast_possible_truncation)]
        let (lat, lon) = ((point.lat() * KEY_COORD_SCALE).round() as i64, (point.lon() * KEY_COORD_SCALE).round() as i64);
        hasher.update(lat.to_le_bytes());
        hasher.update(lon.to_le_bytes());
    }
    format!("geo:route:v1:{}", hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spatial::index::tests::ll;

    fn stops(points: &[(&str, f64, f64)]) -> Vec<(String, LatLng)> {
        points.iter().map(|(id, lat, lon)| ((*id).to_owned(), ll(*lat, *lon))).collect()
    }

    #[test]
    fn misma_peticion_misma_clave() {
        let a = stops(&[("hotel", 40.4168, -3.7038), ("prado", 40.4138, -3.6921)]);
        let b = stops(&[("hotel", 40.416_800_000_1, -3.7038), ("prado", 40.4138, -3.6921)]);
        assert_eq!(route_cache_key(&a, RouteShape::Open, 12), route_cache_key(&b, RouteShape::Open, 12));
        assert!(route_cache_key(&a, RouteShape::Open, 12).starts_with("geo:route:v1:"));
    }

    #[test]
    fn cualquier_cambio_relevante_cambia_la_clave() {
        let base = stops(&[("hotel", 40.4168, -3.7038), ("prado", 40.4138, -3.6921)]);
        let key = route_cache_key(&base, RouteShape::Open, 12);
        assert_ne!(key, route_cache_key(&base, RouteShape::RoundTrip, 12));
        assert_ne!(key, route_cache_key(&base, RouteShape::Open, 10));
        let reordered = stops(&[("prado", 40.4138, -3.6921), ("hotel", 40.4168, -3.7038)]);
        assert_ne!(key, route_cache_key(&reordered, RouteShape::Open, 12));
        let renamed = stops(&[("hotel", 40.4168, -3.7038), ("museo", 40.4138, -3.6921)]);
        assert_ne!(key, route_cache_key(&renamed, RouteShape::Open, 12));
        let moved = stops(&[("hotel", 40.4168, -3.7038), ("prado", 40.4139, -3.6921)]);
        assert_ne!(key, route_cache_key(&moved, RouteShape::Open, 12));
    }

    #[tokio::test]
    async fn memoria_simula_fallos() -> Result<(), CacheError> {
        let store = MemoryStore::default();
        store.set_ex("k", b"v".to_vec(), Duration::from_secs(1)).await?;
        assert_eq!(store.get("k").await?, Some(b"v".to_vec()));
        store.fail.store(true, std::sync::atomic::Ordering::Relaxed);
        assert!(store.get("k").await.is_err());
        Ok(())
    }
}
