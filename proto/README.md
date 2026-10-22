# proto/ — Contratos entre microservicios

Aquí viven los **contratos**: la definición exacta de qué datos se intercambian
los servicios, escrita en [Protocol Buffers](https://protobuf.dev). Es la única
fuente de verdad: Go, Rust, Java y Python generan su código desde estos ficheros.

| Fichero | Qué define |
|---|---|
| `nomadiq/common/v1/common.proto` | Tipos compartidos: `Money`, `Date`, `EventMetadata` |
| `nomadiq/flights/v1/flights.proto` | Modelo de vuelos: `Route`, `CabinClass`, `RouteWatch` |
| `nomadiq/flights/v1/events.proto` | Eventos de Kafka: `FlightPriceObserved`, `FareAlertTriggered` |
| `nomadiq/flights/v1/route_watch_service.proto` | API gRPC `RouteWatchService` |
| `nomadiq/geo/v1/geo.proto` | Tipos geoespaciales: `LatLng`, `Geometry` (WKB), `Airport`, `Zone`, `ZoneKind` |
| `nomadiq/geo/v1/geo_service.proto` | API gRPC `GeoService` del geo-engine (Rust) |
| `nomadiq/geo/v1/events.proto` | Eventos de Kafka: `UserPositionReported`, `GeofenceTransitioned` |

## Catálogo de topics de Kafka

| Topic | Mensaje (valor) | Clave | Particiones | Retención | Productor → Consumidores |
|---|---|---|---|---|---|
| `flights.price-observed.v1` | `FlightPriceObserved` | `ORIGEN-DESTINO:FECHA[:VUELTA]:CABINA` | 12 | 7 días | flight-ingestor → detector sniper, analítica |
| `flights.fare-alerts.v1` | `FareAlertTriggered` | `user_id` | 6 | 30 días | detector sniper → notificaciones, ai-orchestrator |
| `geo.user-positions.v1` | `UserPositionReported` | `user_id` | 12 | 24 horas (dato personal) | app móvil (futuro) → geo-engine |
| `geo.geofence-transitions.v1` | `GeofenceTransitioned` | `user_id` | 6 | 7 días | geo-engine → notificaciones, ai-orchestrator |
| `geo.user-positions-dlq.v1` | `UserPositionReported` (original) | `user_id` | 3 | 3 días | geo-engine (mensajes inválidos) |

### Geometrías: WKB

Los puntos sueltos viajan como `LatLng` (dos `double`). Las formas complejas
(polígonos de zonas, recorridos) viajan como `Geometry.wkb`: bytes en formato
WKB estándar (ISO, 2D, EPSG:4326, X = longitud, Y = latitud). Es el mismo
formato que devuelve PostGIS con `ST_AsBinary`, así que no hay conversiones
campo a campo en ningún salto.

Cada mensaje lleva cabeceras estilo CloudEvents: `content-type`, `ce_id`,
`ce_type` (nombre completo del mensaje proto), `ce_source`, `ce_time`, `ce_specversion`.

## Reglas de evolución

1. Nunca cambies el número ni el tipo de un campo existente.
2. Para quitar un campo, márcalo `reserved`; no reutilices su número.
3. Un cambio incompatible exige paquete nuevo (`v2`) y topic nuevo (`.v2`).

`buf breaking` comprueba estas reglas automáticamente en cada Pull Request.

## Regenerar el código

```bash
go install github.com/bufbuild/buf/cmd/buf@v1.47.2
go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.5
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1
make proto   # desde la raíz: lint + generación en gen/go
```
