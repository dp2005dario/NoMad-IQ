# price-consumer (Go)

Consume los precios que publica el `flight-ingestor`, guarda el historial en
PostgreSQL, detecta chollos (bajadas y tarifas error) y publica alertas para
los usuarios suscritos. Cierra el bucle de eventos del "sniper".

> ¿Empiezas desde cero? Lee primero [`docs/guia-price-consumer.md`](../../docs/guia-price-consumer.md).

```
Kafka flights.price-observed.v1
        │  (grupo de consumidores "price-consumer", una goroutine por partición)
        ▼
  kafka.Consume ──► processor.Handle ──┬─ mensaje roto ──► Kafka flights.price-observed-dlq.v1
                                       │
                                       ▼  UNA transacción
                     PostgreSQL: price_observations + detector + fare_alerts (pendientes)
                                       │
                                       ▼
                   outbox.Relay ──► Kafka flights.fare-alerts.v1 (clave = user_id)
```

## Estructura

| Paquete | Responsabilidad |
|---|---|
| `cmd/price-consumer` | Arranque, cableado, salud HTTP y apagado ordenado |
| `internal/config` | Variables de entorno validadas (se niega a arrancar si algo es inseguro) |
| `internal/domain` | Tipos y reglas de negocio, sin dependencias externas |
| `internal/detector` | Regla "sniper": mediana del historial, umbrales, objetivo y anti-spam (función pura) |
| `internal/events` | Protobuf ⇄ dominio: decodifica precios, codifica alertas y mensajes DLQ |
| `internal/processor` | Orquesta cada mensaje: validar, transacción, detectar, guardar alertas |
| `internal/store` | PostgreSQL con pgx, migraciones embebidas y bandeja de salida |
| `internal/api` | API HTTP de vuelos para la app (chollos, rutas vigiladas, historial, avisos) |
| `internal/watchsync` | Sincroniza las rutas vigiladas con el flight-ingestor (gRPC) |
| `internal/outbox` | Publica en Kafka las alertas pendientes (patrón Transactional Outbox) |
| `internal/kafka` | Consumidor en grupo con commit manual, reintentos con backoff y productor |

## Garantías

- **Idempotente:** `event_id` es la clave primaria de `price_observations`; el ID de cada alerta es un UUID v5 de `(event_id, user_id)`. Reprocesar un mensaje no duplica nada.
- **Al menos una vez:** el offset se confirma solo después de guardar. Las alertas se guardan en la misma transacción que el precio y el relay las publica después; si algo cae, se reintenta.
- **Mensajes venenosos:** se apartan a la DLQ con el motivo y su procedencia en cabeceras. Los fallos temporales (base de datos caída) se reintentan con espera exponencial y nunca se descartan.
- **Anti-spam:** a un usuario solo se le repite una alerta de la misma ruta dentro de `ALERT_COOLDOWN` si el precio mejora.

## Configuración

| Variable | Por defecto | Descripción |
|---|---|---|
| `KAFKA_BROKERS` | **obligatoria** | Lista separada por comas |
| `KAFKA_GROUP_ID` | `price-consumer` | Grupo de consumidores (todas las copias usan el mismo) |
| `KAFKA_TOPIC_PRICE_OBSERVED` / `KAFKA_TOPIC_FARE_ALERTS` / `KAFKA_TOPIC_DLQ` | `flights.price-observed.v1` / `flights.fare-alerts.v1` / `flights.price-observed-dlq.v1` | |
| `KAFKA_TLS_CA_FILE` | — | Activa TLS hacia Kafka |
| `KAFKA_MAX_POLL_RECORDS` | `500` | Mensajes máximos por lote |
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | **obligatorias** | Conexión a PostgreSQL |
| `PGPORT` | `5432` | |
| `PGSSLMODE` | `verify-full` | `disable`/`prefer` solo con `DB_INSECURE_DEV=true` |
| `PGSSLROOTCERT` | — | CA para verificar el certificado del servidor |
| `PG_MAX_CONNS` | `10` | Tamaño del pool de conexiones |
| `DB_INSECURE_DEV` | `false` | Solo local: permite PostgreSQL sin TLS |
| `DETECTOR_MIN_SAMPLES` | `5` | Precios previos necesarios para juzgar el mercado |
| `DETECTOR_DROP_BP` | `2000` | Bajada mínima para `PRICE_DROP` (20 %) |
| `DETECTOR_ERROR_FARE_BP` | `5000` | Bajada mínima para `ERROR_FARE` (50 %) |
| `DETECTOR_HISTORY_WINDOW` | `720h` | Ventana del historial (30 días) |
| `DETECTOR_HISTORY_LIMIT` | `200` | Precios máximos leídos por mensaje |
| `ALERT_COOLDOWN` | `24h` | Periodo anti-spam (`0s` lo desactiva) |
| `SEED_SUBSCRIPTIONS` | — | `usuario\|CLAVE[\|importe_centimos\|DIVISA]`, separadas por comas |
| `OUTBOX_INTERVAL` / `OUTBOX_BATCH_SIZE` | `5s` / `100` | Red de seguridad del relay de alertas |
| `HTTP_ADDR` | `:8082` | `/healthz` y `/readyz` |
| `API_ADDR` | `:8092` | API de vuelos de la app (`/v1/fares/...`, detrás de `edge`) |
| `TLS_CERT_FILE`, `TLS_KEY_FILE`, `TLS_CLIENT_CA_FILE` | **obligatorias** (las tres) | mTLS de la API: solo la puerta de entrada puede llamarla |
| `HTTP_INSECURE_DEV` | `false` | Solo local: API sin TLS |
| `MAX_WATCHES_PER_USER` / `MAX_DAYS_AHEAD` / `DEALS_FRESHNESS` | `50` / `330` / `48h` | Límites de la API |
| `INGESTOR_GRPC_ADDR` | — | gRPC del flight-ingestor; vacía = no se sincronizan rutas |
| `INGESTOR_TLS_CERT_FILE`, `INGESTOR_TLS_KEY_FILE`, `INGESTOR_TLS_CA_FILE` | obligatorias con `INGESTOR_GRPC_ADDR` | mTLS hacia el ingestor |
| `INGESTOR_INSECURE_DEV` | `false` | Solo local: gRPC sin TLS |
| `WATCH_SYNC_INTERVAL` / `WATCH_SYNC_PRUNE` | `1m` / `true` | Cada cuánto se sincroniza y si se quitan rutas que nadie quiere |
| `POPULAR_ROUTES` | — | `MAD-JFK,BCN-LIS,...`: rutas de la portada de chollos |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `SHUTDOWN_TIMEOUT` | `15s` | |

## Tests

```bash
go test -race ./...                       # unitarios (sin infraestructura)
# Con la infraestructura de docker compose levantada (make up):
KAFKA_BROKERS=localhost:29092 PGHOST=localhost PGUSER=nomadiq PGPASSWORD=... PGDATABASE=nomadiq \
  go test -tags integration ./internal/store/ ./internal/kafka/
```
