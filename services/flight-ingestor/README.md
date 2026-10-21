# flight-ingestor (Go)

Vigila rutas de vuelo, consulta sus precios en paralelo y publica cada precio
observado como evento `FlightPriceObserved` en Kafka.

```
            gRPC (mTLS)                      cada POLL_INTERVAL
auth-gateway ──────────► RouteWatchService ──► watchlist ──► ingest (N goroutines)
                                                               │
                                              FareProvider ◄───┤ consulta precio
                                                               │
                                     Kafka flights.price-observed.v1 ◄── events + publisher
```

## Estructura

| Paquete | Responsabilidad |
|---|---|
| `cmd/flight-ingestor` | Arranque, cableado de dependencias y apagado ordenado |
| `internal/config` | Variables de entorno validadas (falla si algo es inseguro) |
| `internal/domain` | Tipos y reglas de negocio, sin dependencias externas |
| `internal/watchlist` | Registro concurrente de rutas vigiladas |
| `internal/provider` | Interfaz `FareProvider` + proveedor simulado |
| `internal/ingest` | Ciclos de consulta con concurrencia limitada |
| `internal/events` | Dominio → mensaje Kafka (protobuf + cabeceras) |
| `internal/publisher` | Productor Kafka idempotente (franz-go) |
| `internal/grpcserver` | API gRPC, mTLS, interceptores |
| `internal/protomap` | Traducción dominio ↔ protobuf |

## Configuración

| Variable | Por defecto | Descripción |
|---|---|---|
| `KAFKA_BROKERS` | **obligatoria** | Lista separada por comas |
| `KAFKA_TOPIC_PRICE_OBSERVED` | `flights.price-observed.v1` | |
| `KAFKA_TLS_CA_FILE` | — | Activa TLS hacia Kafka |
| `GRPC_ADDR` / `HTTP_ADDR` | `:50051` / `:8081` | |
| `GRPC_TLS_CERT_FILE`, `GRPC_TLS_KEY_FILE`, `GRPC_TLS_CLIENT_CA_FILE` | — | mTLS (las tres juntas) |
| `GRPC_INSECURE_DEV` | `false` | Solo local: permite gRPC sin TLS |
| `POLL_INTERVAL` | `5m` | Entre 5s y 24h |
| `PROVIDER_TIMEOUT` | `10s` | Máximo por consulta |
| `INGEST_CONCURRENCY` | `32` | Consultas simultáneas (1–1024) |
| `MAX_WATCHES` | `10000` | Límite de rutas vigiladas |
| `SEED_WATCHES` | — | Rutas de ejemplo, p. ej. `MAD-NRT:2026-12-01:ECONOMY` |
| `SIMULATED_LATENCY`, `SIMULATED_ERROR_FARE_RATE` | `200ms`, `0.01` | Proveedor simulado |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `SHUTDOWN_TIMEOUT` | `15s` | |

## Tests

```bash
go test -race ./...                                    # unitarios
KAFKA_BROKERS=localhost:29092 go test -tags integration ./internal/publisher/   # con Kafka real
```
