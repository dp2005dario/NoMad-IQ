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

            gRPC (mTLS)
price-consumer ────────► FareSearchService ──► caché 10 min + singleflight ──► Searcher (mismo proveedor)
 (GET /v1/fares/search)
```

El **buscador** (`FareSearchService.SearchFares`) responde al momento a "de
MAD a NRT, ida el 15, vuelta el 22, 2 adultos": hasta 20 ofertas ordenadas
por precio, con precio por persona, total, escalas, duración y enlace de
reserva (con el número de viajeros ya puesto). Para no pagar ni saturar al
proveedor con millones de usuarios, cada búsqueda se recuerda 10 minutos y
las búsquedas iguales simultáneas comparten una sola petición; si aun así el
proveedor pide frenar, responde `RESOURCE_EXHAUSTED` y la app pide reintentar.

## Estructura

| Paquete | Responsabilidad |
|---|---|
| `cmd/flight-ingestor` | Arranque, cableado de dependencias y apagado ordenado |
| `internal/config` | Variables de entorno validadas (falla si algo es inseguro) |
| `internal/domain` | Tipos y reglas de negocio, sin dependencias externas |
| `internal/watchlist` | Registro concurrente de rutas vigiladas |
| `internal/provider` | Interfaz `FareProvider`, proveedor simulado y Travelpayouts (precios reales + enlace de afiliado) |
| `internal/ingest` | Ciclos de consulta con concurrencia limitada |
| `internal/events` | Dominio → mensaje Kafka (protobuf + cabeceras) |
| `internal/publisher` | Productor Kafka idempotente (franz-go) |
| `internal/grpcserver` | API gRPC (seguimientos y buscador con caché), mTLS, interceptores |
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
| `FARE_PROVIDER` | `simulated` | `simulated` o `travelpayouts` |
| `TRAVELPAYOUTS_TOKEN` (o `_FILE`) | obligatoria con travelpayouts | **Secreto**: va en la cabecera `X-Access-Token`, nunca en URLs ni logs |
| `TRAVELPAYOUTS_MARKER` | obligatoria con travelpayouts | Tu id de afiliado: se añade a cada enlace de reserva |
| `TRAVELPAYOUTS_CURRENCY` | `EUR` | Divisa de los precios |
| `TRAVELPAYOUTS_RATE_PER_SECOND` / `TRAVELPAYOUTS_REFRESH` | `2` / `30m` | Ritmo máximo total y refresco mínimo por ruta |
| `SEARCH_CACHE_TTL` / `SEARCH_CACHE_ENTRIES` | `10m` / `20000` | Buscador: cuánto y cuántas búsquedas se recuerdan (la misma búsqueda de miles de personas = 1 petición al proveedor) |
| `SEARCH_TIMEOUT` | `8s` | Espera máxima al proveedor en una búsqueda |
| `TRAVELPAYOUTS_BASE_URL` / `TRAVELPAYOUTS_BOOKING_HOST` | `https://api.travelpayouts.com` / `https://www.aviasales.com` | |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `SHUTDOWN_TIMEOUT` | `15s` | |

## Tests

```bash
go test -race ./...                                    # unitarios
KAFKA_BROKERS=localhost:29092 go test -tags integration ./internal/publisher/   # con Kafka real
```
