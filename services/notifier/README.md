# notifier (Go)

Notificaciones push de NomadIQ. Recibe del geo-engine órdenes **seudónimas**
("avisa a este seudónimo de que entró en esta zona"), aplica el anti-spam,
cifra cada aviso **para el teléfono** (HPKE) y lo entrega por Firebase Cloud
Messaging a un ritmo controlado.

```
geo-engine ──► notify.zone-requests.v1 ──► intake ──► notify.deliveries (PostgreSQL)
 (seudónimo + zona, sin coordenadas)        │ anti-spam (Redis, Lua)      │
                                            └ DLQ si es inválida           ▼
app ──► proxy de borde (JWT) ──mTLS──► API /v1/devices          sender (worker pool + token bucket) ──► FCM
```

Guía para principiantes: [`docs/guia-notificaciones.md`](../../docs/guia-notificaciones.md).

## Estructura

| Paquete | Qué hace |
|---|---|
| `cmd/notifier` | Composition root: cablea todo y apaga en orden con SIGTERM |
| `cmd/fcm-fake` | FCM falso para desarrollo y CI (`gone-…` → UNREGISTERED, `busy-…` → 429 una vez) |
| `cmd/notifyctl` | `keygen` (claves de teléfono) y `open` (descifrar un aviso a mano) |
| `internal/config` | Variables de entorno validadas; se niega a arrancar si algo es inseguro |
| `internal/events` | Decodifica y valida `ZoneNotificationRequested`; mensajes a la DLQ |
| `internal/policy` | Tipo de zona → plantilla (`zone_audioguide`, `airport_arrival`, `zone_safety` urgente) |
| `internal/antispam` | Enfriamiento por persona + no repetir zona, en un script Lua atómico |
| `internal/intake` | Orden → avisos cifrados en la cola (nunca espera a Google) |
| `internal/sender` | Cola → FCM: `SKIP LOCKED` + préstamo, obreros, cubo de fichas, frenazo global en 429 |
| `internal/fcm` | Cliente HTTP v1 de FCM (OAuth2 de cuenta de servicio) y clasificación de errores |
| `internal/api` | `PUT`/`DELETE /v1/devices/{device_id}` con identidad del proxy de borde |
| `internal/sealbox` | HPKE (CIRCL) para los avisos; AES-256-GCM, índice ciego y subclaves HKDF para los tokens |
| `internal/pseudonym` | `HMAC-SHA256(clave, "nomadiq/notify/recipient/v1\0" ‖ user_id)` en base64url |
| `internal/store` | PostgreSQL (`notify.devices`, `notify.deliveries`), migraciones embebidas |
| `internal/e2e` | Test de punta a punta contra los contenedores (etiqueta `integration`) |

## Garantías y decisiones

- **Sin historial de ubicación.** Ni user_id, ni coordenadas, ni nombres de
  zona, ni registro de avisos enviados. La cola se vacía en minutos; Redis solo
  guarda claves opacas (HMAC) con caducidad; los logs no llevan seudónimos.
- **Cifrado de extremo a extremo.** HPKE base mode, `DHKEM(X25519, HKDF-SHA256)`,
  `HKDF-SHA256`, `AES-256-GCM`, `info = "nomadiq push v1"`, `aad = device_id`.
  El campo `p` del mensaje de datos es `base64url(enc ‖ ciphertext)`. Probado
  con el vector oficial del RFC 9180. La app debe estrenar par de claves en
  cada registro (HPKE no protege avisos pasados si se roba la clave privada).
- **Anti-spam.** Una orden por posición (geo-engine), enfriamiento de 45 min
  por persona (los avisos de seguridad se lo saltan), la misma zona como mucho
  una vez cada 24 h, y `collapse_key` común en FCM.
- **Entrega "al menos una vez" con caducidad.** El anti-spam se apunta antes de
  encolar y se deshace si encolar falla. Un aviso que no se entrega en
  `NOTIFY_DELIVERY_TTL` se tira. Un duplicado es posible si una copia muere
  justo tras enviar (el préstamo caduca y otra lo reenvía); FCM lo colapsa.
- **Ritmo.** Cubo de fichas de `SEND_RATE_PER_SECOND` por copia; 429 frena a
  todos los obreros durante `Retry-After` (mínimo 30 s). Medido: 300 llegadas
  simultáneas → primer aviso a 0,3 s, los 300 en 8,3 s.
- **Teléfonos.** Máximo `NOTIFY_MAX_DEVICES` por persona (se olvida el más
  antiguo); un `device_id` ajeno da 409; el mismo token bajo otro `device_id`
  se mueve (es el mismo teléfono); `UNREGISTERED` lo borra en cascada; los que
  no se registran en `NOTIFY_DEVICE_INACTIVITY_DAYS` se borran.
- **Redis con `allkeys-lru`.** Si Redis expulsara una clave de enfriamiento por
  falta de memoria, el efecto es un aviso de más, nunca uno de menos. Sin
  Redis no se envía nada (se reintenta la orden).

## Configuración

| Variable | Por defecto | Notas |
|---|---|---|
| `KAFKA_BROKERS` | **obligatoria** | Separados por comas |
| `KAFKA_TOPIC_NOTIFY_REQUESTS` / `KAFKA_TOPIC_NOTIFY_REQUESTS_DLQ` | `notify.zone-requests.v1` / `notify.zone-requests-dlq.v1` | |
| `KAFKA_GROUP_ID` / `KAFKA_CLIENT_ID` / `KAFKA_TLS_CA_FILE` | `notifier` / `notifier` / — | Grupo nuevo = empieza por el final |
| `NOTIFY_PSEUDONYM_KEY` (o `_FILE`) | **obligatoria** | Hex, ≥ 32 bytes. La misma que el geo-engine |
| `NOTIFY_TOKEN_KEY` (o `_FILE`) | **obligatoria** | Hex, ≥ 32 bytes. Distinta de la anterior |
| `NOTIFY_MAX_REQUEST_AGE` / `NOTIFY_DELIVERY_TTL` | `10m` / `10m` | Órdenes y avisos más viejos se tiran |
| `NOTIFY_COOLDOWN` / `NOTIFY_ZONE_REPEAT_WINDOW` | `45m` / `24h` | `NOTIFY_COOLDOWN=0` lo desactiva |
| `NOTIFY_MAX_DEVICES` / `NOTIFY_DEVICE_INACTIVITY_DAYS` | `5` / `60` | |
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | **obligatorias** | `PGSSLMODE=verify-full` por defecto |
| `DB_INSECURE_DEV` | `false` | Solo local: permite `PGSSLMODE=disable` |
| `REDIS_HOST`, `REDIS_PASSWORD` | **obligatorias** | `REDIS_TLS=true` por defecto (`REDIS_TLS_CA_FILE` opcional) |
| `REDIS_INSECURE_DEV` | `false` | Solo local: permite `REDIS_TLS=false` |
| `FCM_PROJECT_ID` | **obligatoria** | Proyecto de Firebase |
| `FCM_CREDENTIALS_FILE` | **obligatoria** en producción | JSON de cuenta de servicio (solo se acepta ese tipo) |
| `FCM_ENDPOINT` | `https://fcm.googleapis.com` | `http` solo con `FCM_INSECURE_DEV=true` |
| `FCM_INSECURE_DEV` | `false` | Solo local: FCM falso sin credenciales |
| `SEND_RATE_PER_SECOND` / `SEND_BURST` / `SEND_WORKERS` | `50` / `50` / `8` | Ritmo por copia |
| `SEND_BATCH` / `SEND_LEASE` / `SEND_MAX_ATTEMPTS` / `SEND_POLL_INTERVAL` | `100` / `1m` / `5` / `1s` | El préstamo debe cubrir 2× el tiempo de enviar un lote |
| `API_ADDR` / `HEALTH_ADDR` | `:8089` / `:8090` | |
| `TLS_CERT_FILE`, `TLS_KEY_FILE`, `TLS_CLIENT_CA_FILE` | **obligatorias** en producción | mTLS de la API (TLS 1.3, certificado de cliente obligatorio) |
| `HTTP_INSECURE_DEV` | `false` | Solo local: API sin TLS |
| `SHUTDOWN_TIMEOUT` / `LOG_LEVEL` | `15s` / `info` | |

## API

La identidad llega del proxy de borde (`X-User-ID`, `X-User-Roles` con `USER`)
por un puerto con mTLS, como en el ai-orchestrator. Errores en RFC 9457.

```http
PUT /v1/devices/{device_id}          (device_id: UUID v4 generado por la app)
Content-Type: application/json

{"platform":"android","fcm_token":"…","public_key":"<X25519 en base64url>"}
```

→ `204` registrado o renovado · `409` ese `device_id` es de otra cuenta ·
`422` datos inválidos (clave débil, token raro, plataforma no soportada).

`DELETE /v1/devices/{device_id}` → `204` siempre (no revela qué ids existen).

Aviso que recibe la app (mensaje **de datos** de FCM): `{"v":"1","p":"<HPKE>"}`.
Descifrado, `p` es:

```json
{"v":1,"type":"zone_audioguide","zone_id":"…","zone_kind":"CITY_CENTER","lang":"es","at":"2026-10-22T13:28:00Z"}
```

## Tests

```bash
go test -race ./...                                     # unitarios (sin Docker)
# Con la infraestructura de docker compose (make up):
PGHOST=localhost … REDIS_HOST=localhost go test -tags integration ./internal/store/ ./internal/antispam/
# Con todo arrancado (make up-apps):
NOTIFIER_E2E=1 go test -tags integration -count=1 -v ./internal/e2e/
```
