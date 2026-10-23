# Guía para principiantes: la puerta de entrada (Traefik) y la API del mapa

Hasta ahora cada microservicio tenía su propio puerto: el 8083 para el
auth-gateway, el 8085 para el ai-orchestrator, etc. Una app móvil no puede
hablar así con diez puertas distintas, y cada servicio tendría que comprobar
el token por su cuenta. La solución es una **puerta de entrada única**: la
app solo habla con ella y ella reparte las peticiones.

## 1. La analogía: la recepción de un hotel

- **Tú** eres la app móvil. Llegas con tu tarjeta, que es el *access token*.
- **Recepción** es **Traefik** (el servicio `edge` de docker compose).
  - Primero pregunta al **auth-gateway** si tu tarjeta es buena.
  - Si lo es, te acompaña a la planta que toca, que es el microservicio.
  - Te acompaña con una nota firmada: "es la persona 123, rol USER".
- **Las plantas** son los microservicios. Se fían de esa nota porque solo la
  recepción puede dárselas.
  - En producción, recepción y plantas se hablan con certificados (mTLS), así
    que nadie más puede colarles una nota falsa.

## 2. Qué hace exactamente (en orden)

Cada petición pasa por estos controles, que en Traefik se llaman *middlewares*
y están en `infrastructure/edge/dynamic.yml`:

1. **`strip-identity`**: borra cualquier `X-User-ID` o `X-User-Roles` que
   mande el cliente. Sin esto, un atacante escribiría `X-User-ID: <otra
   persona>` y se haría pasar por ella. Además:
   - Las variantes disfrazadas como `X_User_ID` también se borran
     (`aliasHeadersStrategy: delete`).
   - Se rechazan los caracteres codificados raros en la dirección (`%2F`,
     `%00`…).
2. **`rate-limit`**: como mucho unas 30 peticiones por segundo por IP.
3. **`small-body`**: cuerpos de 1 MB como máximo.
4. **`authenticated`** (*forward auth*): Traefik llama a
   `auth-gateway /v1/auth/verify` con tu token.
   - **204** → copia `X-User-ID` y `X-User-Roles` en la petición y la deja
     pasar.
   - **401** → la corta ahí mismo. El servicio ni se entera.

| Ruta | Va a | ¿Necesita token? |
|---|---|---|
| `/v1/auth/*`, `/v1/me`, `/.well-known/jwks.json` | auth-gateway | Lo comprueba el propio auth-gateway |
| `/v1/zones`, `/v1/positions` | geo-engine | Sí |
| `/v1/audioguides/*`, `/v1/recommendations/*`, `/v1/group-negotiations/*` | ai-orchestrator | Sí |
| `/v1/audio/*` (archivos .opus) | ai-orchestrator | No: son públicos e inmutables |
| `/v1/devices/*` | notifier | Sí |
| Cualquier otra | — | 404 (los paneles de admin no se publican) |

> **IP real:** como todo entra por Traefik, el auth-gateway vería a todo el
> mundo con la IP de Traefik y el límite de intentos de login bloquearía a
> todos a la vez. Por eso tiene `FORWARD_HEADERS_STRATEGY=native`: lee la IP
> real de la cabecera `X-Forwarded-For`, que escribe Traefik. Traefik descarta
> la que mande el cliente, así que no se puede falsificar.

## 3. La API nueva del geo-engine (para el mapa)

La app no habla gRPC, así que el geo-engine estrena una pequeña API HTTP en el
puerto 8090 (`src/api.rs`).

### `GET /v1/zones?bbox=minLon,minLat,maxLon,maxLat`

Devuelve las zonas que se ven en pantalla, en **GeoJSON**. Es el formato que
MapLibre, la librería del mapa, dibuja directamente sobre la GPU del móvil.

- **Lado máximo de 2°**, unos 220 km. Con el mapa tan alejado no se distinguen
  las zonas turísticas, y pedir "el mundo entero" sería una forma barata de
  cargar el servidor.
- **Como mucho 300 zonas.** Si hay más, la respuesta lo avisa con
  `truncated: true`.
- **Coordenadas con 6 decimales**, unos 10 cm de precisión. Más decimales
  solo harían la respuesta más pesada.

### `POST /v1/positions`

La app junta varias posiciones y las manda de golpe, para ahorrar batería:

```json
{"language": "es-ES",
 "positions": [{"lat": 40.4168, "lon": -3.7038, "accuracy_m": 8, "recorded_at_ms": 1792000000000}]}
```

- **Un lote se acepta entero o se rechaza entero.** Máximo 50 posiciones,
  todas de las últimas 24 h, con coordenadas válidas y precisión entre 0 y
  10 km.
- **Si llega un campo que no esperamos, se rechaza.** Por ejemplo, un
  `user_id` metido en el cuerpo para suplantar a alguien: el usuario SIEMPRE
  sale de la nota de recepción.
- **El orden se respeta.** Se ordenan por hora y se publican una detrás de
  otra en Kafka (`geo.user-positions.v1`, clave = usuario). El geofencing
  que ya existía hace el resto: zonas, histéresis, audioguías y avisos push.
- **Privacidad.** Las posiciones no se guardan aquí ni salen en los logs:
  solo se reenvían.

## 4. Probarlo en tu PC (VS Code)

1. Abre la terminal de VS Code (`Ctrl+ñ`) y arranca todo:
   ```powershell
   cd infrastructure
   docker compose --profile apps up -d --build
   ```
2. Crea una cuenta y entra **a través de la puerta** (puerto 8080):
   ```powershell
   $body = '{"email":"yo@example.com","password":"una contraseña larga"}'
   curl.exe -s -X POST http://localhost:8080/v1/auth/register -H "Content-Type: application/json" -d $body
   $token = (curl.exe -s -X POST http://localhost:8080/v1/auth/login -H "Content-Type: application/json" -d $body | ConvertFrom-Json).access_token
   ```
3. Pide las zonas de Madrid:
   ```powershell
   curl.exe -s -H "Authorization: Bearer $token" "http://localhost:8080/v1/zones?bbox=-3.75,40.38,-3.65,40.45"
   ```
4. Comprueba que sin token te para: el mismo `curl` sin `-H "Authorization…"`
   devuelve 401.

La app móvil ya apunta a esta puerta: `http://10.0.2.2:8080` desde el
emulador.

## 5. Glosario

| Palabra | Qué significa |
|---|---|
| Proxy de borde / puerta de entrada | El único servidor al que llega el tráfico de Internet; reparte hacia dentro |
| Traefik | El programa que hace de puerta de entrada (gratis, de código abierto) |
| Middleware | Un control por el que pasa cada petición (borrar cabeceras, comprobar token…) |
| Forward auth | Preguntar a otro servicio "¿este token es bueno?" antes de dejar pasar |
| GeoJSON | Formato estándar en JSON para puntos, líneas y polígonos de mapas |
| bbox | *Bounding box*: el rectángulo de mapa que se ve en pantalla |

## 6. Pendiente para producción

- **TLS público en la puerta**, con un certificado de Let's Encrypt.
- **mTLS de Traefik hacia cada servicio** (`serversTransport` con su
  certificado de cliente).
- **Quitar los puertos directos** de los servicios, que en local se dejan
  para depurar.
