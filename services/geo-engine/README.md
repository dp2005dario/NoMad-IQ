# geo-engine (Rust)

Motor geoespacial de NomadIQ. Responde por **gRPC con mTLS** las preguntas
geográficas de alta frecuencia (aeropuertos cercanos, distancias, orden óptimo
de paradas, zonas que contienen un punto) desde **índices R-tree en memoria**,
y hace **geofencing en streaming**: lee posiciones de usuarios en Kafka y
publica un evento cada vez que alguien entra o sale de una zona.

> ¿Empiezas desde cero? Lee primero [`docs/guia-geo-engine.md`](../../docs/guia-geo-engine.md).

```
PostgreSQL + PostGIS (fuente de verdad)            Redis
  geo.airports, geo.zones, geo.dataset_version      ├─ geo:route:v1:<sha256>   caché de rutas (TTL 15 min)
        │ cada 30 s: ¿cambió la versión?             └─ geo:presence:v1:<user>  zonas en las que está cada usuario
        ▼ sí → carga en una transacción (WKB)                ▲
  build_snapshot (hilo de cálculo) ──► ArcSwap ◄── lecturas sin cerrojos
                                          │
          ┌───────────────────────────────┴──────────────────────────────┐
          ▼                                                              ▼
  gRPC GeoService :50052 (TLS 1.3 + mTLS + lista de clientes)   Kafka geo.user-positions.v1 (clave user_id)
    FindNearestAirports · ComputeDistance · OptimizeRoute          │ evaluar zonas · DLQ si es inválido
    LocateZones · GetZone (geometrías en WKB)                      ▼
                                                    geo.geofence-transitions.v1 (ENTER/EXIT, id determinista)
```

## API gRPC (`proto/nomadiq/geo/v1/geo_service.proto`)

| RPC | Qué hace | Límites |
|---|---|---|
| `FindNearestAirports` | Aeropuertos más cercanos a un punto, por distancia geodésica real | `limit` 1–50 (0 = 5), radio opcional |
| `ComputeDistance` | Distancia sobre el elipsoide WGS84 (Karney) y rumbo inicial | — |
| `OptimizeRoute` | Orden de visita más corto (abierto o circular). Exacto hasta 12 paradas, heurística (vecino más cercano + 2-opt) por encima. Devuelve el recorrido como LineString WKB | 2–50 paradas, cálculos simultáneos limitados |
| `LocateZones` | Zonas (geofences) que contienen un punto; geometría WKB opcional | — |
| `GetZone` | Una zona con su MultiPolygon en WKB | — |

Errores: `INVALID_ARGUMENT` (datos mal formados), `UNAVAILABLE` (aún sin datos
cargados), `NOT_FOUND`, `RESOURCE_EXHAUSTED` (demasiadas rutas a la vez).
Todas las operaciones son deterministas: reintentar es seguro.

## Riesgos de diseño y cómo se resuelven

| Riesgo | Solución | Dónde |
|---|---|---|
| 1. Duplicar trabajo con PostGIS | PostGIS es la fuente de verdad (persistencia, índices GiST, validación `ST_IsValid`, consultas grandes). Rust solo sirve el camino caliente desde memoria y nunca consulta la base de datos por petición. | `migrations/`, `store.rs`, `snapshot.rs` |
| 2. `unsafe`/FFI de GEOS, GDAL, PROJ | Geometría 100 % Rust (`geo`, `geo-types`, `rstar`, `wkb`) y `unsafe_code = "forbid"`. La única librería en C es librdkafka (no geoespacial), aislada en `stream/kafka.rs`. | `Cargo.toml`, `spatial/` |
| 3. Contención de cerrojos en el R-tree | Foto inmutable + `ArcSwap`: las lecturas no cogen cerrojos; la foto nueva se construye aparte y se publica de golpe. En Kafka, partición por `user_id`: un solo consumidor por usuario, sin estado compartido. | `snapshot.rs`, `stream/mod.rs` |
| 4. Serialización de geometrías en gRPC | `Geometry.wkb` (bytes) para polígonos y recorridos; el WKB de PostGIS se guarda como `Bytes` y se reenvía sin copiar ni reserializar. | `proto/nomadiq/geo/v1/geo.proto`, `grpc.rs` |
| 5. Recalcular rutas en cada reintento | Clave de caché = SHA-256 del contenido de la petición (idempotente por construcción), Redis con TTL, cálculo compartido entre peticiones idénticas simultáneas ("single flight") y la caché falla en abierto. | `cache.rs`, `grpc.rs` |

## Estructura

| Módulo | Responsabilidad |
|---|---|
| `config.rs` | Variables de entorno validadas; no arranca si algo es inseguro |
| `spatial/coord.rs` | `LatLng` validado, distancias geodésicas, vector 3D para el índice |
| `spatial/wkb.rs` | Lectura/escritura WKB con validación (tipo, tamaño, rango, polígonos válidos) |
| `spatial/index.rs` | `GeoSnapshot`: R-tree de aeropuertos (3D) y de zonas (cajas 2D) |
| `spatial/route.rs` | Held-Karp exacto y heurística vecino más cercano + 2-opt |
| `store.rs` | PostgreSQL: migraciones con checksum y cerrojo, carga coherente (REPEATABLE READ) |
| `snapshot.rs` | Construcción y publicación atómica de la foto; refresco periódico |
| `cache.rs` | Redis (perezoso, con tiempo máximo) y clave de caché de rutas |
| `grpc.rs` | `GeoService`: validación, caché, single flight, semáforo de CPU |
| `tls.rs` | TLS 1.3 + mTLS con rustls y lista de clientes permitidos |
| `stream/geofence.rs` | Lógica pura: validar posición, calcular entradas/salidas, ids deterministas |
| `stream/processor.rs` | Un mensaje de principio a fin: DLQ, estado en Redis, publicación |
| `stream/kafka.rs` | rdkafka: consumidor con confirmación manual, productor idempotente |
| `health.rs` | `/healthz` y `/readyz` |
| `main.rs` | Arranque, señales y apagado ordenado |

## Configuración

| Variable | Por defecto | Descripción |
|---|---|---|
| `GRPC_ADDR` / `HTTP_ADDR` | `0.0.0.0:50052` / `0.0.0.0:8087` | gRPC / salud |
| `GRPC_TLS_CERT_FILE`, `GRPC_TLS_KEY_FILE`, `GRPC_TLS_CLIENT_CA_FILE` | — | mTLS (las tres juntas, PEM) |
| `GRPC_ALLOWED_CLIENTS` | — | Nombres (SAN DNS o CN) que pueden llamar; vacío = cualquiera de la CA |
| `GRPC_INSECURE_DEV` | `false` | Solo local: gRPC sin TLS |
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | **obligatorias** | PostgreSQL (esquema `geo`) |
| `PGPORT` / `PGSSLMODE` / `PGSSLROOTCERT` | `5432` / `verify-full` / — | TLS 1.3 verificando el servidor |
| `DB_INSECURE_DEV` | `false` | Solo local: permite `PGSSLMODE=disable` |
| `SNAPSHOT_REFRESH_INTERVAL` | `30s` | Cada cuánto se mira si PostGIS cambió |
| `SEED_DEMO_ZONES` | `false` | Carga zonas de ejemplo (compose lo activa) |
| `REDIS_HOST`, `REDIS_PASSWORD` | **obligatorias** | |
| `REDIS_PORT` / `REDIS_TLS` / `REDIS_TLS_CA_FILE` | `6379` / `true` / — | |
| `REDIS_INSECURE_DEV` | `false` | Solo local: permite `REDIS_TLS=false` |
| `REDIS_OP_TIMEOUT` / `ROUTE_CACHE_TTL` | `250ms` / `15m` | |
| `ROUTE_MAX_STOPS` / `ROUTE_EXACT_MAX_STOPS` / `ROUTE_MAX_CONCURRENCY` | `50` / `12` / nº de CPUs | |
| `GEOFENCE_STREAM_ENABLED` | `true` | Activa el geofencing por Kafka |
| `KAFKA_BROKERS` | **obligatoria** si el stream está activo | Separados por comas |
| `KAFKA_GROUP_ID` / `KAFKA_CLIENT_ID` | `geo-engine` | |
| `KAFKA_TOPIC_POSITIONS` / `KAFKA_TOPIC_TRANSITIONS` / `KAFKA_TOPIC_POSITIONS_DLQ` | `geo.user-positions.v1` / `geo.geofence-transitions.v1` / `geo.user-positions-dlq.v1` | |
| `KAFKA_TOPIC_ZONE_ENTRIES` | `geo.zone-entries.v1` | Entradas **anónimas** (solo `zone_id` + idioma, clave `zone_id`) para el ai-orchestrator |
| `KAFKA_TLS_CA_FILE` | — | Activa TLS hacia Kafka |
| `GEOFENCE_MAX_ACCURACY_M` / `PRESENCE_TTL` | `100` / `24h` | Precisión GPS mínima / memoria de presencia |
| `GEOFENCE_EXIT_MARGIN_M` | `30` | Histéresis de salida: hay que alejarse más que esto del borde (o que la precisión del GPS, si es peor) |
| `GEOFENCE_ENTER_DWELL` | `15s` | Histéresis de entrada: tiempo mínimo dentro antes de anunciar la entrada (`0s` = inmediata) |
| `SHUTDOWN_TIMEOUT` / `LOG_LEVEL` / `LOG_FORMAT` | `20s` / `info` / `json` | |

## Desarrollo

```bash
cd services/geo-engine
cargo test                                   # unitarios + mTLS (sin contenedores)
cargo fmt && cargo clippy --all-targets -- -D warnings
cargo run                                    # con las variables de entorno de arriba
```

Desde la raíz: `make test-rust`, `make up` + `make test-rust-integration`
(los e2e necesitan `make up-apps`), y `make zones` para ver las zonas.

Los aeropuertos (`migrations/0002_seed_airports.sql`, 1.151 filas) salen de
[OurAirports](https://ourairports.com/data/) (dominio público), filtrando
`type = large_airport`, `scheduled_service = yes` y código IATA de 3 letras.
Para añadir aeropuertos o zonas no se edita una migración publicada: se crea
otra nueva (`0003_...sql`) y se añade a la lista `MIGRATIONS` de `store.rs`.
