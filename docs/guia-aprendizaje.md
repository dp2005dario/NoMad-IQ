# Guía de aprendizaje: contratos, infraestructura y flight-ingestor

Esta guía explica **qué se ha construido, por qué y cómo encaja todo**, pensada
para aprender, no solo para usar. Léela en orden: cada parte se apoya en la anterior.

> ¿No sabes qué es Kafka, Docker o gRPC? Empieza por [`guia-principiantes.md`](guia-principiantes.md).

---

## 0. La idea en un minuto

NomadIQ está formado por varios programas pequeños (microservicios), cada uno
escrito en el lenguaje que mejor encaja con su tarea. Para que colaboren
necesitan tres cosas:

1. **Un idioma común** → los *contratos* en `proto/`.
2. **Un sitio donde vivir y hablar** → la *infraestructura* en `infrastructure/`
   (Kafka para mensajes, bases de datos para guardar cosas).
3. **Algo que haga trabajo real** → el primer microservicio, `flight-ingestor`,
   que vigila precios de vuelos y los publica.

```
                 ┌──────────────────────────── proto/ (contratos) ────────────────────────────┐
                 │  definen los mensajes que usan TODOS: Go, Rust, Java y Python              │
                 └────────────────────────────────────────────────────────────────────────────┘

   App móvil ──► auth-gateway (Java) ──gRPC + mTLS──► flight-ingestor (Go) ──► Proveedor de precios
                                                            │
                                                            │ publica FlightPriceObserved
                                                            ▼
                                          ┌──────────── Kafka ────────────┐
                                          │ flights.price-observed.v1     │──► detector "sniper" (futuro)
                                          │ flights.fare-alerts.v1        │──► notificaciones / IA (futuro)
                                          └───────────────────────────────┘
          PostgreSQL+PostGIS · Redis · Qdrant  (listos para los siguientes servicios)
```

Hay dos formas de comunicación y conviene entender la diferencia:

| | gRPC | Kafka |
|---|---|---|
| Estilo | Llamada directa: "haz esto y contéstame" | Anuncio: "ha pasado esto", quien quiera escucha |
| Acoplamiento | El que llama espera respuesta | El productor ni sabe quién consume |
| Uso aquí | Registrar una ruta a vigilar | Difundir cada precio observado |
| Si el receptor cae | La llamada falla | Los mensajes esperan en Kafka hasta que vuelva |

---

## 1. Contratos: `proto/` y `gen/go/`

### ¿Qué es Protocol Buffers?

Es una forma de describir datos en un fichero `.proto` y generar automáticamente
código en cualquier lenguaje para leerlos y escribirlos. Ventajas frente a JSON:

- **Tipado**: un precio es un `int64`, no "lo que venga".
- **Compacto y rápido**: binario, varias veces más pequeño que JSON.
- **Evolución segura**: cada campo tiene un número (`= 1`, `= 2`...). Mientras no
  reutilices números, un servicio antiguo y uno nuevo se siguen entendiendo.

### Los ficheros

- **`common/v1/common.proto`**
  - `Money`: importe en *unidades mínimas* (céntimos). **Decisión clave**: nunca
    guardar dinero en `float`, porque `0.1 + 0.2 = 0.30000000000000004`. Con
    enteros, 129,99 € es exactamente `12999`.
  - `Date`: fecha sin hora. Un vuelo sale "el 1 de diciembre", sin zona horaria.
  - `EventMetadata`: va dentro de cada evento. `event_id` permite descartar
    duplicados; `correlation_id` permite seguir una operación entre servicios.
- **`flights/v1/flights.proto`**: `Route`, `CabinClass` y `RouteWatch`. Fíjate en
  que el primer valor de cada `enum` es `..._UNSPECIFIED = 0`: si alguien olvida
  rellenar la cabina, llega "sin especificar" y lo rechazamos, en vez de
  convertirse en "turista" sin querer.
- **`flights/v1/events.proto`**: los eventos de Kafka.
  - `FlightPriceObserved`: "para esta ruta y fecha, este proveedor dio este precio".
  - `FareAlertTriggered`: "hay una oportunidad para este usuario" (lo emitirá el
    futuro detector *sniper*). `drop_basis_points` usa puntos básicos
    (2500 = 25 %) para no usar decimales.
- **`flights/v1/route_watch_service.proto`**: la API gRPC con tres operaciones:
  `WatchRoute`, `UnwatchRoute`, `ListRouteWatches`.

### Versionado: el `v1` en todas partes

Paquete `nomadiq.flights.v1`, topic `flights.price-observed.v1`. Si algún día hay
que romper la compatibilidad, se crea `v2` y conviven las dos versiones mientras
los consumidores migran. Nadie se rompe de golpe.

### Buf: `buf.yaml` y `buf.gen.yaml`

[Buf](https://buf.build) es la herramienta moderna para `.proto`:
- `buf lint` vigila el estilo (nombres, paquetes, enums...).
- `buf breaking` compara con `main` y **bloquea cambios incompatibles**.
- `buf generate` crea el código Go en `gen/go/`.

### `gen/go/`: código generado

Es un módulo Go independiente que cualquier servicio Go importa. **Se sube al
repositorio** (es lo habitual en Go) para que compilar no exija tener Buf
instalado. La CI comprueba que está al día: si cambias un `.proto` y no
regeneras, la CI falla. No se edita a mano nunca.

---

## 2. Infraestructura: `infrastructure/`

### `docker-compose.yml`

Docker Compose arranca varios contenedores con una sola orden. Cada servicio:

- **Kafka en modo KRaft**: antes Kafka necesitaba otro sistema (ZooKeeper) para
  coordinarse. Desde Kafka 3.3, KRaft lo integra: menos piezas, menos fallos.
  Tiene dos "puertas" (listeners): `kafka:9092` para los contenedores y
  `localhost:29092` para tu máquina. La autocreación de topics está desactivada:
  si un servicio escribe en un topic mal escrito, falla en vez de crear basura.
- **kafka-init**: contenedor de un solo uso que ejecuta `kafka/create-topics.sh`
  cuando Kafka está sano y luego termina. El script es *idempotente*
  (`--if-not-exists`): ejecutarlo dos veces no rompe nada.
- **PostgreSQL + PostGIS**: base de datos relacional con extensión geoespacial
  (distancias, polígonos, "qué hay a 500 m"). Contraseñas con `scram-sha-256`.
  `postgres/init/01-extensions.sql` activa extensiones y crea **un esquema por
  servicio** (`flights`, `geo`, `identity`) para que cada uno toque solo lo suyo.
- **Redis**: caché en memoria con contraseña obligatoria y límite de memoria.
- **Qdrant**: base de datos vectorial para que los agentes de IA busquen por
  "significado" (memoria semántica). Protegida con API key.

### Decisiones de seguridad (y por qué)

| Decisión | Motivo |
|---|---|
| `${VAR:?mensaje}` en todos los secretos | Si falta una contraseña, compose **no arranca**. Nunca hay contraseñas por defecto. |
| `.env` ignorado por git, `.env.example` sí se sube | El ejemplo documenta qué hace falta sin exponer valores reales. |
| Puertos en `127.0.0.1:...` | Solo tu propio ordenador puede conectar; nadie de tu wifi. |
| `no-new-privileges`, `cap_drop: ALL`, `read_only` | Si alguien compromete un contenedor, no puede escalar privilegios. |
| Versiones de imagen fijadas | El mismo entorno hoy y dentro de un año. `latest` cambia sin avisar. |
| `REDISCLI_AUTH` en vez de `-a contraseña` | La contraseña no aparece en la lista de procesos. |
| Healthchecks + `depends_on: service_healthy` | Nadie arranca antes de que aquello de lo que depende esté listo. |

### Perfiles

`flight-ingestor` tiene `profiles: ["apps"]`: con `docker compose up` solo
arranca la infraestructura (útil mientras programas el servicio en tu IDE); con
`--profile apps` arranca también el microservicio en contenedor.

---

## 3. El microservicio `flight-ingestor` (Go)

### Por qué Go aquí

La tarea es: muchas consultas de red a la vez, esperando respuestas. Go tiene
**goroutines**: hilos ligerísimos (unos pocos KB cada uno) que permiten miles de
consultas simultáneas con código sencillo y un binario pequeño y rápido.

### Arquitectura interna: "hexagonal" (puertos y adaptadores)

El centro (`domain`) no sabe nada de Kafka, gRPC ni proveedores. Los bordes
traducen entre el mundo exterior y el dominio. Ventaja: puedes cambiar Kafka
por otra cosa, o añadir un proveedor nuevo, sin tocar las reglas de negocio, y
probar la lógica sin levantar ninguna infraestructura.

```
            ┌───────────────────── adaptadores de entrada ─────────────────────┐
            │  grpcserver (API)        config (entorno)        cmd (arranque)  │
            └───────────────────────────────┬──────────────────────────────────┘
                                            ▼
                    watchlist ◄──── domain (reglas puras) ────► ingest (orquestación)
                                            ▲
            ┌───────────────────────────────┴──────────────────────────────────┐
            │  provider (precios)   events + protomap (formato)   publisher (Kafka) │
            └───────────────────── adaptadores de salida ──────────────────────┘
```

### Paquete a paquete

**`internal/domain/fare.go`** — Las reglas de negocio.
- `ParseAirport` normaliza (`" mad "` → `MAD`) y rechaza lo que no son 3 letras.
- `NewDate` rechaza fechas imposibles (30 de febrero).
- `WatchSpec.Validate` comprueba origen ≠ destino, vuelta ≥ ida, cabina válida, y
  **devuelve todos los errores juntos** con `errors.Join`.
- `WatchSpec.Key()` genera `MAD-NRT:2026-12-01:ECONOMY`. Esta clave es la
  identidad natural de una ruta vigilada y también la **clave del mensaje
  Kafka**: Kafka manda los mensajes con la misma clave a la misma partición, así
  que los precios de una ruta llegan **en orden**.
- `ValidationError` es un error con tipo propio: los adaptadores lo reconocen
  con `errors.As` y responden "petición inválida" en lugar de "error interno".

**`internal/watchlist/store.go`** — Registro de rutas vigiladas.
- Mapa en memoria protegido con `sync.RWMutex` (muchos lectores a la vez, un
  escritor cada vez): el gRPC escribe mientras el ingestor lee.
- `Add` es **idempotente**: pedir dos veces la misma ruta devuelve el mismo ID.
- `MAX_WATCHES` limita el tamaño: sin límite, un cliente podría agotar la memoria.
- Hoy vive en memoria; el siguiente paso es guardarlo en PostgreSQL (`flights`).

**`internal/provider/`** — De dónde salen los precios.
- `FareProvider` es una interfaz: "dame precios para esta ruta".
- `Simulated` inventa precios verosímiles (estables por ruta ±15 %) y, de vez en
  cuando, una "tarifa error" al 30 % para poder probar el sniper sin claves de API.
  Mañana, `Travelpayouts` será otro fichero que implemente la misma interfaz.

**`internal/ingest/ingestor.go`** — El corazón.
- Cada `POLL_INTERVAL` recorre todas las rutas.
- **Concurrencia limitada con un semáforo**: un canal con capacidad N
  (`INGEST_CONCURRENCY`). Para lanzar una consulta hay que meter una ficha en el
  canal; si está lleno, se espera. Así nunca hay más de N consultas a la vez
  (protege a los proveedores de nuestro tráfico y a nuestra memoria).
- **Timeout por consulta** (`context.WithTimeout`): un proveedor lento no
  bloquea el ciclo.
- **Aislamiento de fallos**: si una ruta falla, se cuenta y se registra, y las
  demás siguen. Un `recover()` convierte un pánico en un error contado en lugar
  de tumbar el proceso.
- Datos inválidos del proveedor se **descartan antes de publicar**: un evento
  basura en Kafka contaminaría a todos los consumidores.
- Al final de cada ciclo, un log con estadísticas (consultas, publicados, errores).

**`internal/events/events.go`** — Cómo se ve un mensaje en Kafka.
- Valor: el `FlightPriceObserved` en protobuf binario.
- Clave: `WatchSpec.Key()`.
- Cabeceras estilo **CloudEvents** (`ce_id`, `ce_type`, `ce_source`...): un
  consumidor sabe qué tipo de evento es sin abrirlo. Es un estándar de la CNCF.
- IDs **UUID v7**: incluyen la hora, así que se ordenan cronológicamente.
- Define su propio tipo `Message`, sin depender de la librería de Kafka: los
  tests no necesitan broker.

**`internal/protomap/`** — Traductor dominio ↔ protobuf. Es el único sitio que
conoce los dos mundos; todo lo que llega de fuera pasa por `SpecFromProto` y su
validación antes de usarse (**zero trust**: no te fíes de la entrada, aunque
venga de otro servicio "nuestro").

**`internal/publisher/kafka.go`** — El productor de Kafka (librería franz-go).
- `acks=all`: Kafka solo confirma cuando todas las réplicas sincronizadas tienen
  el mensaje → no se pierde aunque caiga un broker.
- **Idempotencia** (activa por defecto): si un reintento duplica el envío, Kafka
  lo detecta y lo guarda una sola vez.
- **Compresión zstd** y `linger` de 5 ms: agrupa mensajes en lotes comprimidos;
  muchísimo más rendimiento a cambio de 5 ms de latencia.
- `ProduceSync` espera la confirmación: si `Publish` no da error, el mensaje
  está escrito de verdad.

**`internal/grpcserver/`** — La API gRPC.
- Traduce errores de dominio a códigos gRPC estándar: validación →
  `InvalidArgument`, no existe → `NotFound`, límite → `ResourceExhausted`. Un
  error desconocido se devuelve como `Internal` **sin detalles** (no filtramos
  información interna).
- **mTLS con TLS 1.3**: en TLS normal solo el servidor demuestra quién es. En
  mTLS (*mutual*) el cliente también presenta un certificado firmado por nuestra
  CA interna. Un servicio sin certificado válido no puede ni abrir la conexión.
  `tls_test.go` lo demuestra con tres casos: sin certificado (rechazado),
  certificado nuestro (aceptado) y certificado de otra CA (rechazado).
- Interceptores (como "middleware"): uno registra cada llamada con su duración y
  código; otro captura pánicos.
- Límite de 1 MiB por mensaje, keepalive y **health check estándar de gRPC**
  (lo usan Kubernetes y los balanceadores).

**`internal/config/config.go`** — Configuración por variables de entorno.
- Valida todo y devuelve **todos** los errores a la vez.
- **Seguro por defecto**: sin certificados mTLS, el servicio **se niega a
  arrancar**, salvo que digas explícitamente `GRPC_INSECURE_DEV=true` (solo en
  local; compose lo pone y el log avisa con un WARN).
- Rangos acotados (p. ej. concurrencia 1–1024) para evitar configuraciones absurdas.
- Recibe una función `lookup` en vez de leer `os.Getenv` directamente: así los
  tests pasan un mapa sin tocar el entorno real.

**`cmd/flight-ingestor/main.go`** — Arranque y apagado.
- Crea las piezas y las conecta (*composition root*).
- Lanza tres tareas en paralelo con `errgroup`: servidor gRPC, servidor HTTP de
  salud e ingestor. Si una falla, se paran todas.
- **Apagado ordenado** (*graceful shutdown*): al recibir `SIGTERM` (lo que
  envían Docker y Kubernetes), deja de aceptar peticiones, termina las que
  están en curso, vacía los mensajes pendientes a Kafka y sale. Sin esto, cada
  despliegue perdería mensajes.
- `/healthz` = "el proceso vive"; `/readyz` = "puedo trabajar" (Kafka responde y
  el último ciclo publicó). Kubernetes usa la primera para reiniciar y la
  segunda para decidir si le manda tráfico.
- `-healthcheck`: la imagen final no tiene `curl` ni shell, así que el propio
  binario hace de cliente para el `HEALTHCHECK` de Docker.

**`Dockerfile`** — Construcción en dos etapas: compila con la imagen completa de
Go y copia solo el binario estático a `distroless/static:nonroot`. Resultado:
~28 MB, sin shell, sin gestor de paquetes, sin root. Menos cosas dentro = menos
cosas que atacar.

### Los tests

| Test | Qué demuestra |
|---|---|
| `domain/fare_test.go` | Validaciones, fechas imposibles, ida y vuelta de la clave |
| `watchlist/store_test.go` | Idempotencia, límite y acceso concurrente (con `-race`) |
| `provider/simulated_test.go` | Precios válidos, respeta cancelación, tarifas error |
| `events/events_test.go` | El mensaje se decodifica igual que se codificó; cabeceras correctas |
| `ingest/ingestor_test.go` | Nunca supera la concurrencia, un fallo no para al resto, timeouts, apagado |
| `grpcserver/server_test.go` | API real en memoria (`bufconn`): idempotencia y códigos de error |
| `grpcserver/tls_test.go` | mTLS rechaza clientes sin certificado o de otra CA |
| `config/config_test.go` | Valores por defecto, todos los errores juntos, reglas TLS |
| `publisher/kafka_integration_test.go` | Publica y consume contra un **Kafka real**; topic inexistente falla |

Los tests usan **dobles de prueba** (`fakeProvider`, `fakePublisher`): versiones
falsas de las dependencias que permiten simular "el proveedor tarda 1 s" o "Kafka
está caído" sin red. `-race` activa el detector de carreras de Go, que encuentra
accesos simultáneos sin protección.

---

## 4. CI: `.github/workflows/ci.yml`

En cada Pull Request GitHub ejecuta:
1. **Contratos**: `buf lint`, `buf breaking` contra `main`, y que `gen/` esté al día.
2. **Go**: formato (`gofmt`), `go vet` y tests con `-race`.
3. **Integración**: genera secretos aleatorios de usar y tirar, levanta el
   compose, ejecuta los tests contra Kafka real, construye la imagen Docker,
   arranca el servicio y comprueba `/readyz`.

`permissions: contents: read`: la CI tiene el mínimo permiso posible.

---

## 5. Cómo probarlo tú mismo

```bash
# 1. Secretos locales
cd infrastructure && cp .env.example .env
#    rellena cada valor (openssl rand -base64 32) y el KAFKA_CLUSTER_ID

# 2. Infraestructura
docker compose up -d --wait && docker compose ps

# 3. El microservicio con dos rutas de ejemplo, consultando cada 10 s
SEED_WATCHES="MAD-NRT:2026-12-01:ECONOMY,BCN-JFK:2026-12-10:2026-12-20:BUSINESS" \
POLL_INTERVAL=10s docker compose --profile apps up -d --build --wait

# 4. Mira los logs y los eventos
docker compose logs -f flight-ingestor
docker compose exec kafka /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic flights.price-observed.v1 \
  --property print.key=true --property print.headers=true

# 5. Tests
cd .. && make test
make test-integration
```

---

## 6. Glosario rápido

- **Topic**: "canal" de Kafka donde se publican mensajes de un tipo.
- **Partición**: trozo de un topic. Permite repartir carga; el orden solo se
  garantiza dentro de una partición (por eso importa la clave).
- **Consumer group**: varios consumidores que se reparten las particiones.
- **Idempotente**: hacerlo dos veces tiene el mismo efecto que una.
- **At-least-once**: Kafka garantiza que llega *al menos* una vez; puede llegar
  duplicado, y por eso cada evento lleva `event_id`.
- **mTLS**: TLS en el que cliente y servidor se identifican con certificado.
- **Graceful shutdown**: apagarse terminando el trabajo en curso.
- **Healthcheck**: comprobación periódica de que un servicio está bien.

---

## 7. Qué viene después

1. Persistir la watchlist en PostgreSQL (esquema `flights`) con migraciones.
2. Proveedor real (Travelpayouts) con límite de peticiones y reintentos con espera exponencial.
3. Servicio detector *sniper* que consume `price-observed` y emite `fare-alerts`.
4. Generar la CA interna y los certificados mTLS para todos los servicios.
5. Métricas con Prometheus/OpenTelemetry y trazas distribuidas.
