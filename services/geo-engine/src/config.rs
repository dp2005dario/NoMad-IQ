//! Configuración del servicio a partir de variables de entorno ("12-factor").
//!
//! Igual que en los servicios Go: se leen y validan TODAS las variables y se
//! devuelven todos los errores juntos, para que quien despliega vea de una vez
//! todo lo que falta. Y si la configuración es insegura (gRPC sin mTLS,
//! PostgreSQL o Redis sin TLS) el servicio se niega a arrancar, salvo que se
//! active a propósito el modo de desarrollo correspondiente (`*_INSECURE_DEV`).

use std::fmt;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::time::Duration;

/// Un secreto (contraseña). Su `Debug` imprime asteriscos, así un
/// `tracing::debug!("{config:?}")` nunca filtra contraseñas a los logs.
#[derive(Clone, PartialEq, Eq)]
pub struct Secret(String);

impl Secret {
    /// Crea un secreto.
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    /// Acceso explícito al valor: buscar `expose()` en el código muestra
    /// todos los sitios donde se usa una contraseña.
    pub fn expose(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Secret(***)")
    }
}

/// Ficheros de certificados para mTLS del gRPC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrpcTlsFiles {
    /// Certificado del servidor (PEM).
    pub cert_file: PathBuf,
    /// Clave privada del servidor (PEM).
    pub key_file: PathBuf,
    /// CA que firma los certificados de los clientes autorizados (PEM).
    pub client_ca_file: PathBuf,
}

/// Modo TLS de PostgreSQL. Solo dos opciones a propósito: o se verifica el
/// certificado del servidor Y su nombre (`verify-full`), o nada (`disable`,
/// solo en desarrollo). Los modos intermedios ("require") cifran pero no
/// comprueban con quién hablas: dan una falsa sensación de seguridad.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PgTls {
    /// Sin TLS (solo con DB_INSECURE_DEV=true).
    Disable,
    /// TLS verificando certificado y nombre con la CA indicada.
    VerifyFull {
        /// CA raíz (PGSSLROOTCERT).
        root_cert: PathBuf,
    },
}

/// Conexión a PostgreSQL (mismas variables que usa `psql`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PostgresConfig {
    /// Servidor.
    pub host: String,
    /// Puerto.
    pub port: u16,
    /// Usuario.
    pub user: String,
    /// Contraseña.
    pub password: Secret,
    /// Base de datos.
    pub database: String,
    /// Cifrado.
    pub tls: PgTls,
}

/// TLS de Redis.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RedisTls {
    /// Sin TLS (solo con REDIS_INSECURE_DEV=true).
    Disable,
    /// TLS; `ca_file` opcional para una CA privada (si no, las del sistema).
    Enabled {
        /// CA raíz opcional.
        ca_file: Option<PathBuf>,
    },
}

/// Conexión a Redis.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RedisConfig {
    /// Servidor.
    pub host: String,
    /// Puerto.
    pub port: u16,
    /// Contraseña (Redis se despliega siempre con contraseña).
    pub password: Secret,
    /// Cifrado.
    pub tls: RedisTls,
    /// Tiempo máximo por operación: si Redis va lento, mejor seguir sin caché.
    pub op_timeout: Duration,
}

/// Kafka y el geofencing en streaming.
#[derive(Debug, Clone, PartialEq)]
pub struct StreamConfig {
    /// Brokers ("host:puerto").
    pub brokers: Vec<String>,
    /// Identificador de este cliente en los logs de Kafka.
    pub client_id: String,
    /// Grupo de consumidores: las instancias del mismo grupo se reparten particiones.
    pub group_id: String,
    /// Topic de entrada (posiciones).
    pub topic_positions: String,
    /// Topic de salida (entradas/salidas de zonas).
    pub topic_transitions: String,
    /// Topic de entradas anónimas a zonas (solo zone_id + idioma).
    pub topic_zone_entries: String,
    /// Topic de mensajes imposibles de procesar.
    pub topic_positions_dlq: String,
    /// Topic de órdenes de notificación seudónimas (para el notifier).
    pub topic_notify_requests: String,
    /// Clave HMAC (en hexadecimal) con la que se calcula el seudónimo del
    /// destinatario. None = no se piden notificaciones push.
    pub notify_pseudonym_key: Option<Secret>,
    /// CA para TLS hacia Kafka (opcional; activa TLS si se indica).
    pub tls_ca_file: Option<PathBuf>,
    /// Posiciones con peor precisión que esto se ignoran (evita avisos falsos).
    pub max_accuracy_m: f64,
    /// Histéresis de salida: hay que alejarse más que esto del borde para salir.
    pub exit_margin_m: f64,
    /// Histéresis de entrada: tiempo mínimo dentro antes de anunciar la entrada.
    pub enter_dwell: Duration,
    /// Cuánto se recuerda en Redis en qué zonas estaba cada usuario.
    pub presence_ttl: Duration,
}

/// Configuración completa y validada.
#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// Dirección del gRPC.
    pub grpc_addr: SocketAddr,
    /// mTLS del gRPC (None solo con GRPC_INSECURE_DEV=true).
    pub grpc_tls: Option<GrpcTlsFiles>,
    /// Identidades (SAN DNS o CN del certificado) que pueden llamar al gRPC.
    /// Vacío = cualquier certificado firmado por la CA de clientes.
    pub grpc_allowed_clients: Vec<String>,
    /// Dirección HTTP de /healthz y /readyz.
    pub http_addr: SocketAddr,
    /// Dirección de la API HTTP pública (/v1/zones, /v1/positions) que la app
    /// usa a través del proxy de borde. Usa el MISMO mTLS que el gRPC.
    pub api_addr: SocketAddr,
    /// Identidades (certificado) que pueden llamar a la API HTTP: normalmente
    /// solo el proxy de borde. Vacío = cualquier certificado de la CA de clientes.
    pub api_allowed_clients: Vec<String>,
    /// PostgreSQL.
    pub postgres: PostgresConfig,
    /// Cada cuánto se comprueba si los datos de PostGIS cambiaron.
    pub snapshot_refresh_interval: Duration,
    /// Cargar las zonas de demostración al arrancar.
    pub seed_demo_zones: bool,
    /// Redis.
    pub redis: RedisConfig,
    /// Cuánto tiempo se guarda una ruta calculada en Redis.
    pub route_cache_ttl: Duration,
    /// Paradas máximas por petición de ruta.
    pub route_max_stops: usize,
    /// Hasta cuántas paradas se usa el algoritmo exacto.
    pub route_exact_max_stops: usize,
    /// Cálculos de ruta simultáneos como máximo (protege la CPU).
    pub route_max_concurrency: usize,
    /// Kafka (None si GEOFENCE_STREAM_ENABLED=false).
    pub stream: Option<StreamConfig>,
    /// Tiempo máximo para un apagado ordenado.
    pub shutdown_timeout: Duration,
    /// Nivel de log (error, warn, info, debug, trace).
    pub log_level: String,
    /// Formato de log: json (producción) o text (lectura humana).
    pub log_json: bool,
}

/// Lista de todos los problemas encontrados en la configuración.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError(pub Vec<String>);

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "configuración inválida ({} problema(s)):", self.0.len())?;
        for problem in &self.0 {
            writeln!(f, "  - {problem}")?;
        }
        Ok(())
    }
}

impl std::error::Error for ConfigError {}

/// Lector que acumula errores en lugar de parar en el primero.
struct Reader<'a> {
    lookup: &'a dyn Fn(&str) -> Option<String>,
    errors: Vec<String>,
}

impl Reader<'_> {
    fn raw(&self, key: &str) -> Option<String> {
        (self.lookup)(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty())
    }

    fn string(&self, key: &str, default: &str) -> String {
        self.raw(key).unwrap_or_else(|| default.to_owned())
    }

    fn required(&mut self, key: &str) -> String {
        self.raw(key).unwrap_or_else(|| {
            self.errors.push(format!("{key} es obligatoria"));
            String::new()
        })
    }

    fn path(&self, key: &str) -> Option<PathBuf> {
        self.raw(key).map(PathBuf::from)
    }

    fn boolean(&mut self, key: &str, default: bool) -> bool {
        match self.raw(key).as_deref() {
            None => default,
            Some("true" | "1") => true,
            Some("false" | "0") => false,
            Some(other) => {
                self.errors.push(format!("{key}: booleano inválido {other:?} (usa true/false)"));
                default
            }
        }
    }

    fn integer<T>(&mut self, key: &str, default: T, min: T, max: T) -> T
    where
        T: std::str::FromStr + PartialOrd + Copy + fmt::Display,
    {
        let Some(raw) = self.raw(key) else { return default };
        match raw.parse::<T>() {
            Ok(v) if v >= min && v <= max => v,
            Ok(v) => {
                self.errors.push(format!("{key}: {v} fuera del rango [{min}, {max}]"));
                default
            }
            Err(_) => {
                self.errors.push(format!("{key}: entero inválido {raw:?}"));
                default
            }
        }
    }

    fn float(&mut self, key: &str, default: f64, min: f64, max: f64) -> f64 {
        let Some(raw) = self.raw(key) else { return default };
        match raw.parse::<f64>() {
            Ok(v) if v.is_finite() && v >= min && v <= max => v,
            _ => {
                self.errors.push(format!("{key}: se esperaba un número entre {min} y {max}, se recibió {raw:?}"));
                default
            }
        }
    }

    /// Duraciones legibles: "30s", "5m", "1h", "250ms".
    fn duration(&mut self, key: &str, default: Duration, min: Duration, max: Duration) -> Duration {
        let Some(raw) = self.raw(key) else { return default };
        match humantime::parse_duration(&raw) {
            Ok(d) if d >= min && d <= max => d,
            Ok(d) => {
                self.errors.push(format!(
                    "{key}: {} fuera del rango [{}, {}]",
                    humantime::format_duration(d),
                    humantime::format_duration(min),
                    humantime::format_duration(max)
                ));
                default
            }
            Err(_) => {
                self.errors.push(format!("{key}: duración inválida {raw:?} (ejemplos: 30s, 5m)"));
                default
            }
        }
    }

    fn socket_addr(&mut self, key: &str, default: &str) -> SocketAddr {
        let raw = self.string(key, default);
        // Aceptamos ":50052" (estilo Go) como "escuchar en todas las interfaces".
        let normalized = if raw.starts_with(':') { format!("0.0.0.0{raw}") } else { raw.clone() };
        normalized.parse().unwrap_or_else(|_| {
            self.errors.push(format!("{key}: dirección inválida {raw:?} (ejemplo: 0.0.0.0:50052)"));
            SocketAddr::from(([0, 0, 0, 0], 0))
        })
    }

    /// Un secreto que llega en una variable o, mejor (producción), en un
    /// fichero montado: `CLAVE_FILE=/run/secrets/...`. Así no aparece en
    /// `docker inspect` ni en la lista de procesos.
    fn secret_or_file(&mut self, key: &str) -> Option<Secret> {
        let file_key = format!("{key}_FILE");
        match (self.raw(key), self.path(&file_key)) {
            (Some(_), Some(_)) => {
                self.errors.push(format!("{key} y {file_key} son excluyentes: usa solo una"));
                None
            }
            (Some(value), None) => Some(Secret::new(value)),
            (None, Some(path)) => match std::fs::read_to_string(&path) {
                Ok(value) if !value.trim().is_empty() => Some(Secret::new(value.trim())),
                // No se incluye el contenido del fichero en el error, solo su ruta.
                Ok(_) => {
                    self.errors.push(format!("{file_key}: el fichero {} está vacío", path.display()));
                    None
                }
                Err(e) => {
                    self.errors.push(format!("{file_key}: no se pudo leer {}: {e}", path.display()));
                    None
                }
            },
            (None, None) => None,
        }
    }

    fn list(&self, key: &str) -> Vec<String> {
        self.raw(key).map(|raw| raw.split(',').map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned).collect()).unwrap_or_default()
    }
}

impl Config {
    /// Lee la configuración de las variables de entorno del proceso.
    pub fn from_env() -> Result<Self, ConfigError> {
        Self::from_lookup(&|key| std::env::var(key).ok())
    }

    /// Lee la configuración con una función de búsqueda inyectable (tests).
    pub fn from_lookup(lookup: &dyn Fn(&str) -> Option<String>) -> Result<Self, ConfigError> {
        let mut r = Reader { lookup, errors: Vec::new() };

        // --- gRPC + mTLS
        let grpc_addr = r.socket_addr("GRPC_ADDR", "0.0.0.0:50052");
        let grpc_insecure = r.boolean("GRPC_INSECURE_DEV", false);
        let cert = r.path("GRPC_TLS_CERT_FILE");
        let key = r.path("GRPC_TLS_KEY_FILE");
        let client_ca = r.path("GRPC_TLS_CLIENT_CA_FILE");
        let grpc_tls = match (cert, key, client_ca) {
            (Some(cert_file), Some(key_file), Some(client_ca_file)) => Some(GrpcTlsFiles { cert_file, key_file, client_ca_file }),
            (None, None, None) if grpc_insecure => None,
            (None, None, None) => {
                r.errors.push(
                    "gRPC sin mTLS: define GRPC_TLS_CERT_FILE, GRPC_TLS_KEY_FILE y GRPC_TLS_CLIENT_CA_FILE \
                     (o GRPC_INSECURE_DEV=true SOLO en desarrollo)"
                        .into(),
                );
                None
            }
            _ => {
                r.errors.push("GRPC_TLS_CERT_FILE, GRPC_TLS_KEY_FILE y GRPC_TLS_CLIENT_CA_FILE van juntas: faltan algunas".into());
                None
            }
        };
        let grpc_allowed_clients = r.list("GRPC_ALLOWED_CLIENTS");
        let http_addr = r.socket_addr("HTTP_ADDR", "0.0.0.0:8087");
        let api_addr = r.socket_addr("API_ADDR", "0.0.0.0:8090");
        let api_allowed_clients = r.list("API_ALLOWED_CLIENTS");

        // --- PostgreSQL
        let db_insecure = r.boolean("DB_INSECURE_DEV", false);
        let pg_host = r.required("PGHOST");
        let pg_port = r.integer("PGPORT", 5432u16, 1, u16::MAX);
        let pg_user = r.required("PGUSER");
        let pg_password = Secret::new(r.required("PGPASSWORD"));
        let pg_database = r.required("PGDATABASE");
        let pg_tls = match r.string("PGSSLMODE", "verify-full").as_str() {
            "disable" if db_insecure => PgTls::Disable,
            "disable" => {
                r.errors.push("PGSSLMODE=disable solo se permite con DB_INSECURE_DEV=true".into());
                PgTls::Disable
            }
            "verify-full" => match r.path("PGSSLROOTCERT") {
                Some(root_cert) => PgTls::VerifyFull { root_cert },
                None => {
                    r.errors.push("PGSSLMODE=verify-full necesita PGSSLROOTCERT (CA del servidor PostgreSQL)".into());
                    PgTls::Disable
                }
            },
            other => {
                r.errors.push(format!("PGSSLMODE={other:?} no soportado: usa verify-full (o disable en desarrollo)"));
                PgTls::Disable
            }
        };

        let snapshot_refresh_interval =
            r.duration("SNAPSHOT_REFRESH_INTERVAL", Duration::from_secs(30), Duration::from_secs(1), Duration::from_secs(24 * 3600));
        let seed_demo_zones = r.boolean("SEED_DEMO_ZONES", false);

        // --- Redis
        let redis_insecure = r.boolean("REDIS_INSECURE_DEV", false);
        let redis_host = r.required("REDIS_HOST");
        let redis_port = r.integer("REDIS_PORT", 6379u16, 1, u16::MAX);
        let redis_password = Secret::new(r.required("REDIS_PASSWORD"));
        let redis_tls = if r.boolean("REDIS_TLS", true) {
            RedisTls::Enabled { ca_file: r.path("REDIS_TLS_CA_FILE") }
        } else {
            if !redis_insecure {
                r.errors.push("REDIS_TLS=false solo se permite con REDIS_INSECURE_DEV=true".into());
            }
            RedisTls::Disable
        };
        let redis_op_timeout =
            r.duration("REDIS_OP_TIMEOUT", Duration::from_millis(250), Duration::from_millis(10), Duration::from_secs(10));
        let route_cache_ttl =
            r.duration("ROUTE_CACHE_TTL", Duration::from_secs(15 * 60), Duration::from_secs(1), Duration::from_secs(7 * 24 * 3600));

        // --- Rutas
        let route_max_stops = r.integer("ROUTE_MAX_STOPS", 50usize, 2, 200);
        let route_exact_max_stops = r.integer("ROUTE_EXACT_MAX_STOPS", 12usize, 3, crate::spatial::route::EXACT_HARD_LIMIT);
        let cpus = std::thread::available_parallelism().map(usize::from).unwrap_or(2);
        let route_max_concurrency = r.integer("ROUTE_MAX_CONCURRENCY", cpus, 1, 1024);

        // --- Kafka (geofencing en streaming)
        let stream = if r.boolean("GEOFENCE_STREAM_ENABLED", true) {
            let brokers = r.list("KAFKA_BROKERS");
            if brokers.is_empty() {
                r.errors.push("KAFKA_BROKERS es obligatoria con GEOFENCE_STREAM_ENABLED=true".into());
            }
            Some(StreamConfig {
                brokers,
                client_id: r.string("KAFKA_CLIENT_ID", "geo-engine"),
                group_id: r.string("KAFKA_GROUP_ID", "geo-engine"),
                topic_positions: r.string("KAFKA_TOPIC_POSITIONS", "geo.user-positions.v1"),
                topic_transitions: r.string("KAFKA_TOPIC_TRANSITIONS", "geo.geofence-transitions.v1"),
                topic_zone_entries: r.string("KAFKA_TOPIC_ZONE_ENTRIES", "geo.zone-entries.v1"),
                topic_positions_dlq: r.string("KAFKA_TOPIC_POSITIONS_DLQ", "geo.user-positions-dlq.v1"),
                topic_notify_requests: r.string("KAFKA_TOPIC_NOTIFY_REQUESTS", "notify.zone-requests.v1"),
                notify_pseudonym_key: r.secret_or_file("NOTIFY_PSEUDONYM_KEY").and_then(|key| {
                    // Se valida aquí para que una clave mala pare el arranque
                    // con un mensaje claro, en lugar de fallar más tarde.
                    match crate::stream::notify::Pseudonymizer::from_hex(key.expose()) {
                        Ok(_) => Some(key),
                        Err(e) => {
                            r.errors.push(format!("NOTIFY_PSEUDONYM_KEY: {e}"));
                            None
                        }
                    }
                }),
                tls_ca_file: r.path("KAFKA_TLS_CA_FILE"),
                max_accuracy_m: r.float("GEOFENCE_MAX_ACCURACY_M", 100.0, 1.0, 10_000.0),
                // 30 m: algo más que el "baile" típico del GPS de un móvil en ciudad.
                exit_margin_m: r.float("GEOFENCE_EXIT_MARGIN_M", 30.0, 0.0, 1_000.0),
                // 15 s: suficiente para descartar el borde, poco para que el
                // usuario note retraso. 0s desactiva la histéresis de entrada.
                enter_dwell: r.duration("GEOFENCE_ENTER_DWELL", Duration::from_secs(15), Duration::ZERO, Duration::from_secs(600)),
                presence_ttl: r.duration(
                    "PRESENCE_TTL",
                    Duration::from_secs(24 * 3600),
                    Duration::from_secs(60),
                    Duration::from_secs(30 * 24 * 3600),
                ),
            })
        } else {
            None
        };

        let shutdown_timeout = r.duration("SHUTDOWN_TIMEOUT", Duration::from_secs(20), Duration::from_secs(1), Duration::from_secs(120));
        let log_level = r.string("LOG_LEVEL", "info").to_lowercase();
        if !matches!(log_level.as_str(), "error" | "warn" | "info" | "debug" | "trace") {
            r.errors.push(format!("LOG_LEVEL: {log_level:?} inválido (error, warn, info, debug, trace)"));
        }
        let log_json = match r.string("LOG_FORMAT", "json").as_str() {
            "json" => true,
            "text" => false,
            other => {
                r.errors.push(format!("LOG_FORMAT: {other:?} inválido (json o text)"));
                true
            }
        };

        if !r.errors.is_empty() {
            return Err(ConfigError(r.errors));
        }
        Ok(Self {
            grpc_addr,
            grpc_tls,
            grpc_allowed_clients,
            http_addr,
            api_addr,
            api_allowed_clients,
            postgres: PostgresConfig {
                host: pg_host,
                port: pg_port,
                user: pg_user,
                password: pg_password,
                database: pg_database,
                tls: pg_tls,
            },
            snapshot_refresh_interval,
            seed_demo_zones,
            redis: RedisConfig {
                host: redis_host,
                port: redis_port,
                password: redis_password,
                tls: redis_tls,
                op_timeout: redis_op_timeout,
            },
            route_cache_ttl,
            route_max_stops,
            route_exact_max_stops,
            route_max_concurrency,
            stream,
            shutdown_timeout,
            log_level,
            log_json,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn load(vars: &[(&str, &str)]) -> Result<Config, ConfigError> {
        let map: HashMap<String, String> = vars.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        Config::from_lookup(&move |k| map.get(k).cloned())
    }

    const DEV: &[(&str, &str)] = &[
        ("GRPC_INSECURE_DEV", "true"),
        ("PGHOST", "localhost"),
        ("PGUSER", "nomadiq"),
        ("PGPASSWORD", "secreto"),
        ("PGDATABASE", "nomadiq"),
        ("PGSSLMODE", "disable"),
        ("DB_INSECURE_DEV", "true"),
        ("REDIS_HOST", "localhost"),
        ("REDIS_PASSWORD", "secreto"),
        ("REDIS_TLS", "false"),
        ("REDIS_INSECURE_DEV", "true"),
        ("KAFKA_BROKERS", "localhost:29092"),
    ];

    #[test]
    fn configuracion_de_desarrollo_valida() -> Result<(), ConfigError> {
        let cfg = load(DEV)?;
        assert_eq!(cfg.grpc_addr.port(), 50052);
        assert!(cfg.grpc_tls.is_none());
        assert_eq!(cfg.postgres.tls, PgTls::Disable);
        assert_eq!(cfg.stream.as_ref().map(|s| s.topic_positions.as_str()), Some("geo.user-positions.v1"));
        assert_eq!(cfg.route_exact_max_stops, 12);
        let stream = cfg.stream.as_ref().map(|s| (s.exit_margin_m, s.enter_dwell, s.topic_zone_entries.as_str()));
        assert_eq!(stream, Some((30.0, Duration::from_secs(15), "geo.zone-entries.v1")));
        Ok(())
    }

    #[test]
    fn sin_variables_lista_todos_los_errores_y_exige_seguridad() {
        let Err(ConfigError(errors)) = load(&[]) else { unreachable!("debería fallar") };
        let joined = errors.join("\n");
        for expected in ["gRPC sin mTLS", "PGHOST", "PGPASSWORD", "PGSSLROOTCERT", "REDIS_HOST", "REDIS_PASSWORD", "KAFKA_BROKERS"] {
            assert!(joined.contains(expected), "falta el error sobre {expected}: {joined}");
        }
    }

    #[test]
    fn desactivar_tls_sin_modo_desarrollo_es_un_error() {
        let vars: Vec<_> = DEV.iter().copied().filter(|(k, _)| !k.ends_with("_INSECURE_DEV")).collect();
        let Err(ConfigError(errors)) = load(&vars) else { unreachable!("debería fallar") };
        assert_eq!(errors.len(), 3, "{errors:?}");
    }

    #[test]
    fn valores_fuera_de_rango() {
        let mut vars = DEV.to_vec();
        vars.extend([("ROUTE_MAX_STOPS", "100000"), ("SNAPSHOT_REFRESH_INTERVAL", "nunca"), ("LOG_LEVEL", "ruido")]);
        let Err(ConfigError(errors)) = load(&vars) else { unreachable!("debería fallar") };
        assert_eq!(errors.len(), 3, "{errors:?}");
    }

    #[test]
    fn la_contrasena_no_sale_en_los_logs() -> Result<(), ConfigError> {
        let cfg = load(DEV)?;
        assert!(!format!("{cfg:?}").contains("secreto"));
        Ok(())
    }

    #[test]
    fn clave_de_seudonimos_opcional_validada_y_oculta() {
        let key = "00".repeat(32);
        let mut vars = DEV.to_vec();
        assert!(load(&vars).is_ok_and(|c| c.stream.is_some_and(|s| s.notify_pseudonym_key.is_none())));
        vars.push(("NOTIFY_PSEUDONYM_KEY", key.as_str()));
        let cfg = load(&vars);
        assert!(cfg.as_ref().is_ok_and(|c| c.stream.as_ref().is_some_and(|s| s.notify_pseudonym_key.is_some())));
        assert!(cfg.is_ok_and(|c| !format!("{c:?}").contains(&key)));

        let mut short = DEV.to_vec();
        short.push(("NOTIFY_PSEUDONYM_KEY", "abcd"));
        let Err(ConfigError(errors)) = load(&short) else { unreachable!("debería fallar") };
        assert!(errors.iter().any(|e| e.contains("NOTIFY_PSEUDONYM_KEY")), "{errors:?}");

        let mut both = DEV.to_vec();
        both.extend([("NOTIFY_PSEUDONYM_KEY", key.as_str()), ("NOTIFY_PSEUDONYM_KEY_FILE", "/run/secrets/k")]);
        assert!(load(&both).is_err());
    }

    #[test]
    fn stream_desactivable_y_tls_a_medias() {
        let mut vars = DEV.to_vec();
        vars.retain(|(k, _)| *k != "KAFKA_BROKERS");
        vars.push(("GEOFENCE_STREAM_ENABLED", "false"));
        assert!(load(&vars).is_ok_and(|c| c.stream.is_none()));

        let mut half = DEV.to_vec();
        half.push(("GRPC_TLS_CERT_FILE", "/certs/server.pem"));
        assert!(load(&half).is_err());
    }
}
