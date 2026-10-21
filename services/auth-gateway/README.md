# auth-gateway (Java Spring Boot)

Pasarela de identidad de NomadIQ: registro, login, emisión de JWT firmados con
**ES256**, publicación de claves en **JWKS**, tokens de refresco rotatorios,
revocación inmediata con **Redis** y rate limiting contra fuerza bruta.

> ¿Empiezas desde cero? Lee primero [`docs/guia-auth-gateway.md`](../../docs/guia-auth-gateway.md).

```
 App móvil ──HTTPS──► Proxy de borde (Envoy/NGINX/Traefik)
                        │ 1. GET /v1/auth/verify  (Authorization: Bearer …)   ──mTLS──► auth-gateway
                        │ 2. 204 + X-User-ID / X-User-Roles  ◄────────────────────────── (firma ES256 en memoria
                        │                                                                 + lista negra en Redis)
                        └ 3. petición original + X-User-* ──mTLS──► microservicio interno
                                                                    (sigue exigiendo certificado)
```

## Endpoints

| Método y ruta | Acceso | Qué hace |
|---|---|---|
| `POST /v1/auth/register` | público | Crea una cuenta (`email`, `password` ≥ 12 caracteres). 201 / 400 / 409 / 429 |
| `POST /v1/auth/login` | público | Devuelve `access_token` (15 min) y `refresh_token` (30 días). 200 / 401 / 429 |
| `POST /v1/auth/refresh` | público | Canjea un `refresh_token` por una pareja nueva (un solo uso). 200 / 401 / 429 |
| `POST /v1/auth/logout` | token | Lista negra del token actual y revoca la familia del `refresh_token` enviado. 204 |
| `GET /v1/auth/verify` | token | *Forward auth* para el proxy de borde: 204 con `X-User-ID`, `X-User-Roles`, `X-Token-ID`. |
| `GET /v1/me` | token | Datos del usuario autenticado. |
| `POST /v1/admin/users/{id}/revoke-sessions` | ADMIN | Cierra todas las sesiones del usuario al instante. |
| `POST /v1/admin/users/{id}/disable` | ADMIN | Baneo: desactiva la cuenta y expulsa todas sus sesiones. |
| `GET /.well-known/jwks.json` | público | Claves públicas (activa + antiguas en rotación). Cacheable 5 min. |
| `GET :8084/livez`, `GET :8084/readyz` | red interna | Salud (readyz incluye PostgreSQL y Redis). |

Los errores siguen RFC 9457 (`application/problem+json`), sin trazas ni detalles internos.

## Estructura

| Paquete | Responsabilidad |
|---|---|
| `config` | Configuración tipada y validada (`AuthProperties`), mTLS, pool de PostgreSQL, reglas de Spring Security, Argon2id |
| `keys` | Llavero ES256 desde PEM (kid = huella RFC 7638), rotación y endpoint JWKS |
| `token` | Emisión (`at+jwt`, RFC 9068) y validación de JWT, lista negra en Redis, refresh tokens con rotación y detección de reutilización |
| `auth` | Lógica de registro, login, refresco, logout y baneo |
| `ratelimit` | Contadores atómicos en Redis (script Lua) por IP y por cuenta |
| `user` | Tabla `identity.users` con SQL explícito |
| `api` | Controladores REST, modelos JSON y traducción de errores |

## Garantías de seguridad

- **Validación sin estado:** la firma se comprueba en memoria con la clave pública; la única consulta externa por petición es un `MGET` a Redis (lista negra, < 1 ms). Algoritmo fijado a ES256 (`alg: none` y HS256 rechazados), `typ: at+jwt`, `iss`, `aud`, `exp`/`nbf` (60 s de tolerancia) y claims obligatorios.
- **Revocación:** logout = `jti` en lista negra hasta su `exp`; baneo = "todo lo emitido antes de T" por usuario. Si Redis cae, se rechaza (fallo cerrado).
- **Refresh tokens:** 256 bits aleatorios, solo se guarda su SHA-256, un solo uso con `SELECT … FOR UPDATE`; reutilizar uno revoca toda su familia.
- **Contraseñas:** Argon2id (19 MiB, 2 iteraciones), migración automática de parámetros en el login, mismo tiempo de respuesta exista o no el email.
- **Rate limiting:** por IP en login, registro y refresco; por cuenta tras N fallos (frena ataques distribuidos). Respuesta 429 con `Retry-After`.
- **Zero Trust:** el puerto principal exige mTLS con TLS 1.3; PostgreSQL `verify-full` y Redis con TLS. Con una configuración insegura el servicio **no arranca** salvo que se pidan explícitamente los `*_INSECURE_DEV`.

## Configuración

| Variable | Por defecto | Descripción |
|---|---|---|
| `HTTP_PORT` / `MANAGEMENT_PORT` | `8083` / `8084` | API / salud |
| `TLS_CERT_FILE`, `TLS_KEY_FILE`, `TLS_CLIENT_CA_FILE` | — | mTLS (las tres juntas, PEM) |
| `HTTP_INSECURE_DEV` | `false` | Solo local: HTTP sin TLS |
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | **obligatorias** | PostgreSQL (esquema `identity`, migraciones Flyway) |
| `PGPORT` / `PG_MAX_CONNS` | `5432` / `10` | |
| `PGSSLMODE` / `PGSSLROOTCERT` | `verify-full` / — | Sin `PGSSLROOTCERT` se usa el almacén de CA de Java |
| `DB_INSECURE_DEV` | `false` | Solo local: permite `disable`/`prefer`/`require` |
| `REDIS_HOST`, `REDIS_PASSWORD` | **obligatorias** | |
| `REDIS_PORT` / `REDIS_TLS` | `6379` / `true` | |
| `REDIS_INSECURE_DEV` | `false` | Solo local: Redis sin TLS |
| `JWT_ISSUER` / `JWT_AUDIENCE` | `https://auth.nomadiq.app` / `nomadiq-api` | Claims `iss` y `aud` |
| `ACCESS_TOKEN_TTL` / `REFRESH_TOKEN_TTL` | `15m` / `30d` | |
| `JWT_ACTIVE_KEY_FILE` | — | Clave privada EC P-256, PEM PKCS#8 |
| `JWT_VERIFY_ONLY_KEY_FILES` | — | Claves públicas antiguas (PEM), separadas por comas |
| `JWT_DEV_EPHEMERAL_KEY` | `false` | Solo local (exige `HTTP_INSECURE_DEV`): clave en memoria |
| `RATE_LIMIT_LOGIN_IP` | `20/1m` | Logins por IP |
| `RATE_LIMIT_REGISTER_IP` | `5/10m` | Registros por IP |
| `RATE_LIMIT_REFRESH_IP` | `60/1m` | Refrescos por IP |
| `RATE_LIMIT_LOGIN_FAILURES` | `5/15m` | Fallos de contraseña por cuenta antes de bloquearla temporalmente |
| `FORWARD_HEADERS_STRATEGY` | `none` | `native` solo con un proxy de confianza delante (IP real para el rate limiting) |
| `LOG_LEVEL` / `LOG_FORMAT` | `info` / `ecs` | Logs JSON (ECS) |

Claves de firma:

```bash
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out jwt-2026-10.pem   # privada (secreto)
openssl pkey -in jwt-2026-10.pem -pubout -out jwt-2026-10.pub.pem                      # pública (para rotar)
```

## Tests

```bash
./mvnw test      # 29 unitarios, sin Docker
./mvnw verify    # + 9 de integración: PostgreSQL y Redis reales con Testcontainers (requiere Docker)
```
