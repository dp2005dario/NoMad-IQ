# Guía del price-consumer: el detector de chollos, explicado desde cero

Esta guía está escrita para alguien que **no sabe nada** de programación de
sistemas. Si es tu primera vez con el proyecto, lee antes
[`guia-principiantes.md`](guia-principiantes.md) (qué es cada carpeta y cómo
instalarlo todo); esta guía se centra en el detector de chollos. Si algo no se entiende, la culpa es de la guía, no tuya. Ve por
orden: cada sección se apoya en la anterior.

---

## 0. La idea con una analogía (sin tecnicismos)

Imagina una **lonja de pescado**:

1. **El pescador** (`flight-ingestor`) sale al mar cada pocos minutos y vuelve
   con precios de vuelos: "Madrid–Tokio, 1 de diciembre, 450 €".
2. Deja cada precio en una **cinta transportadora** (`Kafka`). La cinta no
   decide nada: solo transporta, en orden, y guarda lo que lleva durante
   7 días por si alguien necesita volver a mirarlo.
3. Al final de la cinta está **el tasador** (`price-consumer`, lo que hemos
   construido ahora). Coge cada precio y:
   - lo apunta en su **libro de registro** (`PostgreSQL`), para tener historial;
   - mira en el libro los precios anteriores de ese mismo vuelo y se pregunta:
     *"¿esto es mucho más barato de lo normal?"*;
   - si lo es, escribe una **nota de aviso** para cada persona que pidió
     vigilar ese vuelo y la deja en la **bandeja de salida**.
4. **El cartero** (`outbox`) recoge las notas de la bandeja y las pone en otra
   cinta (`flights.fare-alerts.v1`). Más adelante, otro servicio cogerá esas
   notas y mandará la notificación al móvil.
5. Si llega a la cinta algo que no es un precio (un papel roto, ilegible), el
   tasador no se queda atascado: lo echa en la **caja de devoluciones**
   (`DLQ`) y sigue con el siguiente.

Eso es todo. El resto de esta guía explica cómo se hace eso de forma que
**no se pierda nada, no se repita nada y aguante millones de precios**.

---

## 1. Glosario para principiantes

Vuelve aquí siempre que una palabra te suene a chino.

| Palabra | Qué significa, en sencillo |
|---|---|
| **Microservicio** | Un programa pequeño que hace UNA cosa. NomadIQ son varios programas que colaboran. |
| **Evento / mensaje** | Un aviso de que "algo ha pasado": "se ha visto este precio". |
| **Kafka** | La cinta transportadora de mensajes entre servicios. |
| **Topic** | Una cinta concreta, con nombre. Ej.: `flights.price-observed.v1`. |
| **Partición** | Una cinta se divide en varios carriles paralelos (12 en nuestro caso) para ir más rápido. Los precios de un mismo vuelo van siempre por el mismo carril, así llegan en orden. |
| **Offset** | El número de cada mensaje dentro de un carril ("voy por el 1.532"). |
| **Commit (de offset)** | Decirle a Kafka "hasta aquí ya lo he procesado". Si el programa se reinicia, sigue desde ahí. |
| **Grupo de consumidores** | Varias copias del mismo programa que se reparten los carriles. 3 copias = cada una lleva 4 carriles. Si una se cae, las otras se quedan sus carriles. |
| **Rebalanceo** | El momento en que Kafka reparte de nuevo los carriles porque una copia entró o salió. |
| **Productor / consumidor** | Quien pone mensajes en la cinta / quien los recoge. |
| **Protobuf** | Formato para empaquetar mensajes en binario: muy compacto y con tipos estrictos. Los "planos" están en `proto/`. |
| **PostgreSQL** | La base de datos: tablas con filas, como hojas de cálculo muy potentes y seguras. |
| **Tabla / fila / columna** | Una hoja de cálculo / una línea / una columna. |
| **Clave primaria** | La columna que identifica cada fila de forma única (como el DNI). |
| **Índice** | Como el índice de un libro: permite encontrar filas sin leer la tabla entera. |
| **Transacción** | Un grupo de cambios que se aplica **entero o nada**. Como una transferencia bancaria: no puede salir el dinero de una cuenta sin entrar en la otra. |
| **Commit / rollback (de base de datos)** | Confirmar la transacción / deshacerla entera. |
| **Migración** | Un fichero SQL numerado que crea o cambia tablas. Se aplica una sola vez y en orden. |
| **Idempotente** | Que hacerlo dos veces da el mismo resultado que hacerlo una. Pulsar el botón del ascensor 5 veces no llama a 5 ascensores. |
| **Al menos una vez** | Garantía de Kafka: un mensaje nunca se pierde, pero en raras ocasiones puede llegar repetido. Por eso necesitamos idempotencia. |
| **DLQ (Dead Letter Queue)** | "Buzón de cartas devueltas": topic donde van los mensajes imposibles de procesar. |
| **Mensaje venenoso (poison pill)** | Un mensaje roto que, si lo reintentas para siempre, bloquea el carril. |
| **Outbox (bandeja de salida)** | Guardar lo que hay que enviar en la base de datos y enviarlo después, para no perderlo nunca. |
| **Backoff exponencial** | Al reintentar, esperar cada vez el doble (0,5 s, 1 s, 2 s, 4 s…) para no saturar al que está caído. |
| **Mediana** | El valor del medio al ordenar una lista. De `[10, 11, 12, 13, 500]` la mediana es 12 (la media sería 109, engañosa). |
| **Puntos básicos (pb)** | Centésimas de porcentaje: 2000 pb = 20 %. Se usan enteros para no tener errores de decimales. |
| **Goroutine** | Una tarea ligera de Go que se ejecuta a la vez que otras. Puedes tener miles. |
| **Graceful shutdown** | Apagarse con educación: terminar lo que tienes entre manos antes de cerrar. |
| **Healthcheck** | Una dirección (`/healthz`, `/readyz`) que Docker o Kubernetes consultan para saber si el servicio está bien. |
| **TLS** | El cifrado del candado de las webs (https). Aquí lo exigimos también entre el servicio y la base de datos. |
| **Variable de entorno** | Un ajuste que se le pasa al programa desde fuera (por ejemplo, la contraseña), sin escribirlo en el código. |

---

## 2. El viaje de UN precio, paso a paso

Sigamos a un mensaje concreto: *"MAD–NRT, 1 de diciembre, turista, 150 €"*.

1. **El ingestor lo publica** en `flights.price-observed.v1` con la clave
   `MAD-NRT:2026-12-01:ECONOMY`. Kafka lo mete en, digamos, el carril 4.
2. **El price-consumer lo recoge** (`internal/kafka/client.go`). Cada carril
   tiene su propia goroutine: los 12 carriles se procesan a la vez, pero dentro
   de un carril los mensajes van en orden.
3. **Se traduce y se revisa** (`internal/events/events.go`): ¿es protobuf de
   verdad? ¿el código de aeropuerto tiene 3 letras? ¿el precio es positivo? ¿la
   fecha existe? Si algo falla → a la DLQ, y siguiente mensaje.
4. **Se abre una transacción** en PostgreSQL (`internal/processor/processor.go`):
   1. Se intenta guardar el precio. Si su `event_id` ya existía, es un
      **repetido**: se cierra sin hacer nada más.
   2. Se leen los últimos precios de esa ruta (hasta 200, de los últimos
      30 días): `500, 480, 520, 490, 510…` → **mediana 500 €**.
   3. Se calcula la bajada: `(500 − 150) / 500 = 70 %` = **7000 pb**.
   4. El detector decide (`internal/detector/detector.go`): 70 % ≥ 50 % →
      **ERROR_FARE** (posible tarifa error de la aerolínea).
   5. Se buscan los usuarios suscritos a esa ruta. Para cada uno se comprueba
      el anti-spam: ¿ya le avisamos hace menos de 24 h con un precio igual o
      mejor? Si no, se crea su alerta.
   6. Se guardan las alertas marcadas como "pendientes de publicar".
   7. **COMMIT**: el precio y sus alertas quedan guardados a la vez.
5. **Se confirma el offset** en Kafka: "el mensaje del carril 4 está hecho".
6. **El cartero** (`internal/outbox/relay.go`) se despierta, recoge las
   alertas pendientes, las publica en `flights.fare-alerts.v1` (clave = el
   usuario) y las marca como publicadas.

¿Y si el programa se cae entre el paso 4 y el 5? Al reiniciar, Kafka le
vuelve a dar el mensaje (no se había confirmado). Pero en el paso 4.1 el
`event_id` ya existe → se trata como repetido. **Nada se duplica.**

¿Y si se cae entre el 4 y el 6? Las alertas están en la base de datos como
pendientes; el cartero las encontrará al arrancar. **Nada se pierde.**

---

## 3. La regla del "sniper", en detalle

| Situación | Resultado |
|---|---|
| Menos de 5 precios previos | No se juzga el mercado (aún no sabemos qué es "barato"). El precio objetivo del usuario sí funciona. |
| Bajada ≥ 50 % frente a la mediana | `ERROR_FARE` — posible error de la aerolínea, ¡corre! |
| Precio ≤ objetivo que puso el usuario | `TARGET_REACHED` |
| Bajada ≥ 20 % frente a la mediana | `PRICE_DROP` |
| Varias a la vez | Gana la más urgente: ERROR_FARE > TARGET_REACHED > PRICE_DROP |
| Ya avisado en las últimas 24 h a igual o mejor precio | No se repite (anti-spam) |

**¿Por qué la mediana y no la media?** Porque un solo precio raro no la
mueve. Si ayer hubo una tarifa error de 12 € entre precios de 500 €, la media
bajaría mucho y la siguiente tarifa error parecería "normal". La mediana ni
se inmuta.

**¿Por qué enteros (céntimos y puntos básicos)?** En los ordenadores
`0.1 + 0.2` no da exactamente `0.3`. Con dinero eso es inaceptable, así que
todo se guarda en céntimos (`45000` = 450,00 €) y los porcentajes en puntos
básicos.

Todos los umbrales se cambian con variables de entorno, sin tocar código
(`DETECTOR_DROP_BP`, `DETECTOR_ERROR_FARE_BP`, `DETECTOR_MIN_SAMPLES`,
`ALERT_COOLDOWN`…).

---

## 4. Los riesgos que señaló Gemini y qué hemos hecho con cada uno

| Riesgo | Qué hemos hecho | Dónde está |
|---|---|---|
| **1. Duplicados** (Kafka puede entregar un mensaje dos veces) | El `event_id` es la clave primaria de `price_observations`: `INSERT … ON CONFLICT DO NOTHING`. El ID de cada alerta es un UUID calculado de `(evento, usuario)`, así que la misma alerta siempre tiene el mismo ID, y la tabla tiene `UNIQUE (event_id, user_id)`. Quien reciba las alertas también puede descartar repetidas por ese ID. | `store/postgres.go`, `detector.AlertID`, migración `0001` |
| **2. Saturar PostgreSQL** | Pool de conexiones limitado (`PG_MAX_CONNS`), lotes de lectura de Kafka acotados (`KAFKA_MAX_POLL_RECORDS`), índices para cada consulta frecuente, inserción de alertas en *batch* de pgx (un solo viaje de red) y procesado en paralelo por partición. **Pendiente:** agrupar varios precios en una sola transacción o usar `COPY`. Hoy es una transacción por mensaje porque es lo más sencillo de razonar y probar; cuando midamos el *consumer lag* con carga real decidiremos si hace falta. | `kafka/client.go`, `store/postgres.go` |
| **3. Mensajes venenosos** | Dos tipos de fallo, dos tratamientos. **Datos rotos** (no es protobuf, campos inválidos o la base de datos rechaza el dato): directo a la DLQ `flights.price-observed-dlq.v1`, conservando el mensaje original y añadiendo el motivo, topic, partición y offset en cabeceras. **Fallos temporales** (base de datos caída): se reintenta el mismo mensaje con backoff exponencial (0,5 s → 30 s) **sin límite**, a propósito: si PostgreSQL cae 10 minutos, no queremos mandar miles de precios buenos a la DLQ. Mientras tanto `/readyz` responde 503 para que se vea el problema. | `processor.Handle`, `processor.reject`, `kafka.processPartition` |
| **4. Rebalanceos por falta de latido** | franz-go envía el *heartbeat* desde una goroutine propia, independiente del procesado, así que un mensaje lento no hace que Kafka nos dé por muertos. Además: las particiones se procesan en paralelo (una goroutine por carril), el lote está acotado y `BlockRebalanceOnPoll` evita que nos quiten un carril a mitad de lote (el reparto espera a que confirmemos). Se usa el reparto *cooperative-sticky*: en un rebalanceo solo se mueven los carriles necesarios. | `kafka/client.go` |
| **5. Fatiga de alertas** | Umbral mínimo real (20 % de bajada, configurable) y periodo anti-spam por usuario y ruta (24 h, configurable): solo se repite la alerta si el precio **mejora**. **Lo hemos hecho en PostgreSQL y no en Redis** a propósito: la consulta va dentro de la misma transacción que guarda la alerta, así que es siempre coherente (con Redis podría desincronizarse si el servicio cae entre los dos sistemas) y tenemos una pieza menos que pueda fallar. Hay un índice específico para que sea rápida. Si en el futuro hiciera falta, Redis se puede poner delante como caché. | `detector.Evaluate`, `RecentlyAlerted`, índice `fare_alerts_cooldown_idx` |

---

## 5. Fichero a fichero

### `services/price-consumer/`

| Fichero | Qué es y por qué existe |
|---|---|
| `go.mod` / `go.sum` | La "lista de la compra" de librerías y sus huellas de seguridad. Usa el código generado de `gen/go` del propio repositorio (`replace`). |
| `cmd/price-consumer/main.go` | El punto de arranque. Lee la configuración, conecta PostgreSQL, aplica migraciones, carga suscripciones de ejemplo, crea el cliente de Kafka y lanza tres tareas en paralelo (consumidor, cartero y servidor de salud). Al recibir Ctrl+C o SIGTERM, apaga todo en orden. |
| `internal/config/config.go` | Lee y valida todas las variables de entorno de golpe. Se niega a arrancar si PostgreSQL va sin cifrar fuera de desarrollo. Nunca imprime la contraseña. |
| `internal/domain/domain.go` | Los "sustantivos" del negocio: `Observation` (un precio), `Subscription` (quién vigila qué), `Alert` (un aviso), `Money` (dinero en céntimos)… y sus reglas de validación. No depende de nada externo. |
| `internal/detector/detector.go` | El cerebro. Función pura: recibe historial, precio y suscripciones, devuelve alertas. Por eso es tan fácil de probar. |
| `internal/events/events.go` | El traductor: protobuf de Kafka → tipos de dominio (y al revés para las alertas). También fabrica los mensajes de la DLQ. |
| `internal/processor/processor.go` | El director de orquesta: decide qué hacer con cada mensaje (DLQ, repetido, guardar y detectar). Solo conoce interfaces, no PostgreSQL ni Kafka directamente: así se prueba con versiones falsas en memoria. |
| `internal/store/postgres.go` | El archivero: todas las consultas SQL (siempre con parámetros `$1`, nunca pegando texto, para evitar inyección SQL). Distingue errores de datos (→ DLQ) de errores de conexión (→ reintentar). |
| `internal/store/migrate.go` | Aplica las migraciones al arrancar. Usa un bloqueo de PostgreSQL para que, si arrancan 3 copias a la vez, solo una migre. Guarda la huella SHA-256 de cada migración: si alguien edita una ya aplicada, el servicio se niega a arrancar. |
| `internal/store/migrations/0001_price_history.sql` | Crea las tres tablas: `price_observations` (historial), `fare_subscriptions` (quién vigila qué) y `fare_alerts` (alertas, que hace también de bandeja de salida). Las restricciones `CHECK` impiden datos absurdos aunque el código fallara. |
| `internal/outbox/relay.go` | El cartero: publica las alertas pendientes en Kafka y las marca como enviadas. Se despierta en cuanto hay alertas nuevas y, por si acaso, cada 5 segundos. |
| `internal/kafka/client.go` | La conexión con Kafka: consumo en grupo, commit manual después de guardar, una goroutine por partición, reintentos con espera creciente y publicación de mensajes. |
| `*_test.go` | Los tests. Los normales no necesitan nada instalado. Los `*_integration_test.go` (etiqueta `integration`) usan PostgreSQL y Kafka reales. `kafka/e2e_integration_test.go` prueba el recorrido completo: publica 6 precios y un mensaje roto, y comprueba que sale la alerta correcta y que el roto acaba en la DLQ. |
| `Dockerfile` | Receta para la imagen: compila en una etapa y copia solo el binario a una imagen mínima sin shell, que se ejecuta sin root. |
| `README.md` | Ficha técnica rápida: estructura, garantías y todas las variables. |

### Cambios fuera del servicio

| Fichero | Cambio |
|---|---|
| `infrastructure/kafka/create-topics.sh` | Nuevo topic `flights.price-observed-dlq.v1` (3 particiones, 14 días). |
| `infrastructure/docker-compose.yml` | Servicio `price-consumer` en el perfil `apps`: sin privilegios, sistema de ficheros de solo lectura, espera a que Kafka y PostgreSQL estén listos, credenciales desde `.env`. |
| `infrastructure/.env.example` | Ejemplo de `SEED_SUBSCRIPTIONS`. |
| `.github/workflows/ci.yml` | Nuevo job `price-consumer` (formato, vet, tests con detector de carreras). En el job de integración: arranca ingestor + consumer, comprueba que los precios llegan a PostgreSQL y ejecuta los tests de integración. |
| `Makefile` | `make test` y `make test-integration` incluyen el nuevo servicio; `make alerts` muestra las últimas alertas. |
| `.vscode/extensions.json` | Añade a las recomendadas las extensiones de PostgreSQL y Markdown (ver sección 6). |
| `go.work` | Añade `services/price-consumer` al espacio de trabajo de Go (y `go.work.sum`, sus huellas). |

---

## 6. Trabajar con el proyecto desde Visual Studio Code

### Instalar lo necesario (una sola vez)

1. **Visual Studio Code**: <https://code.visualstudio.com>
2. **Git**: <https://git-scm.com> (en Windows, deja las opciones por defecto).
3. **Go 1.24 o superior**: <https://go.dev/dl>
4. **Docker Desktop**: <https://www.docker.com/products/docker-desktop>
   (ábrelo y espera a que la ballena diga "running").
5. En Windows, `make` no viene instalado. Puedes usar los comandos que hay
   dentro del `Makefile` directamente, o instalarlo con
   `winget install GnuWin32.Make`.

### Abrir el proyecto

1. Clona el repositorio: en VS Code, `Ctrl+Shift+P` → escribe
   **"Git: Clone"** → pega `https://github.com/dp2005dario/NoMad-IQ` → elige
   una carpeta. O, si ya lo tienes, **File → Open Folder** y elige la carpeta
   `NoMad-IQ` (la raíz, no una subcarpeta).
2. Abajo a la derecha aparecerá: *"Este espacio de trabajo tiene extensiones
   recomendadas"* → **Instalar todas**. Son las de `.vscode/extensions.json`:
   - **Go**: autocompletado, errores en rojo mientras escribes, botón para
     ejecutar tests y depurador. La primera vez te pedirá instalar
     herramientas (`gopls`, `dlv`…): acepta **Install All**.
   - **Docker**: icono de la ballena en la barra lateral para ver contenedores
     y sus logs con un clic.
   - **Buf**: colores y validación en los `.proto`.
   - **YAML** y **GitHub Actions**: validan `docker-compose.yml` y la CI.
   - **PostgreSQL**: explorar las tablas y lanzar consultas.
   - **Markdown All in One**: `Ctrl+Shift+V` abre la vista previa de esta guía.

### La terminal integrada

`Ctrl+ñ` (o **View → Terminal**) abre una terminal ya situada en la carpeta
del proyecto. Todos los comandos de la sección 7 se escriben ahí.

### Ejecutar tests sin escribir comandos

Abre cualquier fichero `_test.go` (por ejemplo
`services/price-consumer/internal/detector/detector_test.go`). Encima de cada
función `Test…` verás **run test | debug test**. Pulsa *run test*.

### Depurar (ver el programa "a cámara lenta")

1. Abre `detector.go` y haz clic a la izquierda del número de línea dentro de
   `Evaluate`: aparece un punto rojo (**breakpoint**).
2. En `detector_test.go`, pulsa **debug test** encima de `TestEvaluate`.
3. La ejecución se para en tu punto rojo. A la izquierda ves el valor de cada
   variable; con **F10** avanzas línea a línea.

### Consejos

- Usa la carpeta raíz como espacio de trabajo. El fichero `go.work` de la
  raíz le dice a la extensión de Go que hay varios módulos (`gen/go`,
  `services/flight-ingestor`, `services/price-consumer`); este PR añade el
  price-consumer a esa lista. Si creas otro servicio en Go, añádelo también.
- `.vscode/settings.json` ya formatea Go al guardar y activa la etiqueta
  `integration` para que el editor entienda también esos tests.
- Nunca subas tu `infrastructure/.env`: ya está en `.gitignore`.

---

## 7. Probarlo tú mismo

```bash
# 1. Secretos locales (solo la primera vez)
cp infrastructure/.env.example infrastructure/.env
#    Rellena las contraseñas y el KAFKA_CLUSTER_ID como explica el propio fichero.
#    Para ver alertas sin app móvil, añade también:
#    SEED_WATCHES=MAD-NRT:2026-12-01:ECONOMY
#    SEED_SUBSCRIPTIONS=dario|MAD-NRT:2026-12-01:ECONOMY
#    POLL_INTERVAL=10s

# 2. Arranca todo (infraestructura + ingestor + consumer)
make up-apps

# 3. ¿Está sano?
curl http://127.0.0.1:8082/readyz        # debe responder "ready"

# 4. Mira qué hace (Ctrl+C para salir de los logs)
docker compose -f infrastructure/docker-compose.yml logs -f price-consumer
#    Busca "chollo detectado" y "alertas publicadas". El ingestor simula una
#    tarifa error en el 1 % de las consultas; para verlas antes, añade
#    SIMULATED_ERROR_FARE_RATE=0.2 a infrastructure/.env y repite make up-apps.

# 5. Las alertas guardadas, en una tabla legible
make alerts

# 6. Tests
make test               # unitarios
make test-integration   # con Kafka y PostgreSQL reales (necesita make up)
```

Lo hemos comprobado de punta a punta: con el ingestor publicando cada 5 s y
un 30 % de tarifas error simuladas, el consumer guardó cada precio, detectó
las tarifas error (por ejemplo 12,21 € frente a una mediana de 38,58 €, una
bajada del 68 %) y publicó las alertas en `flights.fare-alerts.v1`.

---

## 7 bis. La API de vuelos de la app y el "encargado" de rutas

Desde este PR, el price-consumer también atiende a la **app**: la pestaña
**Vuelos** le pregunta por los chollos y por las rutas que vigilas.

### Qué puede pedir la app

Todo pasa por la puerta de entrada (`edge`, puerto 8080). Los **chollos** y
el **historial** son públicos: los ve todo el mundo, también quien entra como
invitado, porque los precios son los mismos para todos (y se guardan 1 minuto
en caché para aguantar muchos usuarios). Lo **tuyo** (rutas vigiladas y
avisos) necesita tu pase (token): sin él, la puerta contesta 401.

| Petición | Para qué |
|---|---|
| `GET /v1/fares/deals?origin=MAD` | Chollos de hoy desde Madrid, ordenados por cuánto han bajado (público) |
| `GET /v1/fares/search?origin=MAD&destination=NRT&departure=2026-12-15&return=2026-12-22&adults=2` | **Buscador**: ofertas para ese viaje, de la más barata a la más cara, con precio por persona y total (público). Lo responde el flight-ingestor por gRPC (`FareSearchService`), que guarda cada búsqueda 10 min y junta las búsquedas iguales en una sola petición al proveedor. Si el proveedor pide frenar: 429 "inténtalo en unos segundos" |
| `GET /v1/fares/watches` | Las rutas que vigilas, con su último precio |
| `PUT /v1/fares/watches/MAD-NRT:2026-12-01:ECONOMY` | Vigilar una ruta (opcional: `{"target":{"amount_minor":45000,"currency":"EUR"}}` = avísame por debajo de 450 €) |
| `DELETE /v1/fares/watches/…` | Dejar de vigilarla |
| `GET /v1/fares/history/…` | El precio más bajo de cada día (para la gráfica; público) |
| `GET /v1/fares/alerts` | Tus últimos avisos de precio |

Con analogías:

- **"Lo que suele costar"** es la **mediana** de los últimos 30 días: el
  precio que queda en medio si los ordenas. Un precio raro (muy alto o muy
  bajo) no la mueve, igual que en el detector.
- **Límites por persona:** como mucho 50 rutas, y solo vuelos de los próximos
  330 días. Así nadie puede hacer que consultemos millones de rutas.
- **Enlaces seguros:** solo se mandan a la app enlaces de compra `https://`.
  Un enlace raro de un proveedor (`javascript:`…) se borra por el camino.

### El "encargado" de rutas (watchsync)

El flight-ingestor apunta en **memoria** qué rutas consultar: si se
reinicia, las olvida. La lista buena está en PostgreSQL.

Analogía: el **encargado** de un almacén compara cada minuto la lista de
pedidos con lo que hay en las estanterías, y corrige lo que no cuadra.

- Pide al ingestor (por gRPC) las rutas que vigila alguien y las rutas
  populares de la portada (`POPULAR_ROUTES`).
- Le quita las rutas que ya nadie quiere, para no gastar consultas al
  proveedor de precios.
- Borra las suscripciones a vuelos que ya salieron.
- Si el ingestor no responde, lo vuelve a intentar al minuto siguiente. Los
  precios se siguen procesando igual.

Las rutas populares se vigilan el **día 15** del mes que viene y del
siguiente. Así las fechas no cambian cada día y el historial (lo que suele
costar) se va llenando durante semanas.

### Probarlo en tu PC (PowerShell)

```powershell
cd infrastructure
docker compose --profile apps up -d --build
# Entra con una cuenta (cámbiala por la tuya) y guarda el pase:
$body = '{"email":"yo@example.com","password":"caballo correcto grapa pila"}'
curl.exe -s -X POST http://localhost:8080/v1/auth/register -H "Content-Type: application/json" -d $body
$token = (curl.exe -s -X POST http://localhost:8080/v1/auth/login -H "Content-Type: application/json" -d $body | ConvertFrom-Json).access_token
# Chollos desde Madrid (espera un par de minutos a que lleguen precios):
curl.exe -s -H "Authorization: Bearer $token" "http://localhost:8080/v1/fares/deals?origin=MAD"
```

---

## 8. Cómo contarlo en una entrevista (30 segundos)

> "El price-consumer es un consumidor de Kafka en Go que cierra el bucle del
> detector de chollos. Consume en grupo con commit manual para tener entrega
> al menos una vez, y lo hace idempotente con el `event_id` como clave primaria
> en PostgreSQL. El precio y las alertas se escriben en la misma transacción y
> se publican con el patrón Transactional Outbox, así que no se pierde ni se
> duplica nada aunque el servicio caiga en cualquier punto. Los mensajes
> venenosos van a una DLQ y los fallos temporales se reintentan con backoff
> exponencial. La regla de detección es una función pura sobre la mediana
> del historial, robusta a valores atípicos, con anti-spam por usuario. Todo
> está probado con tests unitarios y de integración contra Kafka y PostgreSQL
> reales en la CI."

Preguntas que te pueden hacer, y la respuesta corta:

- *¿Por qué no exactamente una vez (exactly-once)?* — Requiere transacciones
  de Kafka y que la base de datos participe; es mucho más complejo. Al menos
  una vez + idempotencia da el mismo resultado práctico con menos piezas.
- *¿Cómo escala?* — Añadiendo copias con el mismo `KAFKA_GROUP_ID`; Kafka les
  reparte las 12 particiones. Más de 12 copias no ayudaría: habría que subir
  las particiones.
- *¿Qué pasa si PostgreSQL cae?* — El consumer reintenta el mismo mensaje con
  espera creciente, no confirma offsets, `/readyz` devuelve 503 y, cuando
  vuelve la base de datos, sigue donde estaba sin perder nada.

---

## 9. Siguientes pasos

1. **Medir antes de optimizar:** métricas de *consumer lag*, mensajes por
   segundo y latencia (Prometheus/OpenTelemetry). Con datos reales, decidir si
   agrupar varios precios por transacción o usar `COPY` (riesgo 2 de Gemini).
2. **Retención del historial:** particionar `price_observations` por mes y
   borrar lo antiguo, para que la tabla no crezca sin límite.
3. **Usuario de base de datos propio** para el price-consumer con permisos
   solo sobre sus tablas (mínimo privilegio), y TLS con PostgreSQL en local.
4. ~~Gestión de suscripciones real~~: hecho, con la API de vuelos (7 bis).
5. **Servicio de notificaciones** que consuma `flights.fare-alerts.v1`,
   descarte repetidos por `alert_id` y envíe el aviso al móvil.
6. **Herramienta para la DLQ:** ver los mensajes devueltos y reinyectarlos
   cuando se corrija el fallo.
7. **Redis** delante del anti-spam solo si las métricas muestran que la
   consulta en PostgreSQL se queda corta.
