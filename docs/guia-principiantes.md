# Guía para principiantes absolutos

> Si nunca has programado un servidor, no sabes qué es Docker o te suena a
> chino "Kafka" o "gRPC", **esta guía es para ti**. No hace falta saber nada.
> Cuando termines, te recomiendo pasar a [`guia-aprendizaje.md`](guia-aprendizaje.md),
> que entra en el detalle técnico.

---

## Parte 1. ¿Qué estamos construyendo?

ECLIPTA es una app de viajes. Una de sus funciones es **avisarte cuando un
vuelo baja de precio**. Para eso, alguien tiene que estar mirando precios todo
el rato, día y noche. Ese "alguien" es un programa que vive en un servidor.

Lo que hay en este repositorio hoy es **la primera parte** de ese sistema:

1. Un programa que **mira precios de vuelos** cada pocos minutos.
2. Un **tablón de anuncios** donde ese programa deja apuntado cada precio que ve,
   para que otros programas lo lean.
3. Las **reglas** que todos los programas usan para entenderse.
4. Unas **bases de datos** preparadas para lo que vendrá después.

---

## Parte 2. La gran analogía: una empresa de viajes

Imagina ECLIPTA como una empresa con varios empleados. Cada empleado es un
programa (lo llamamos **microservicio**) y cada uno hace una sola cosa muy bien:

| Empleado (microservicio) | Qué hace en la "empresa" | Lenguaje |
|---|---|---|
| **flight-ingestor** | El vigilante de precios: llama a las aerolíneas sin parar y apunta precios | Go |
| **auth-gateway** | El recepcionista: comprueba quién eres antes de dejarte pasar | Java |
| geo-engine *(futuro)* | El experto en mapas: calcula distancias y rutas | Rust |
| **ai-orchestrator** | El asistente inteligente: convierte alertas en consejos con IA local (ver [`guia-ai-orchestrator.md`](guia-ai-orchestrator.md)) | Python |

**¿Por qué no un solo programa gigante?** Por la misma razón que una empresa no
tiene un único empleado que lo hace todo: si se pone enfermo, se para todo. Con
varios, si uno falla los demás siguen, y si hay mucho trabajo de un tipo, se
contratan más empleados de ese tipo (eso es **escalar**).

---

## Parte 3. Los conceptos, uno a uno

### 🗣️ Protocol Buffers (protobuf): el idioma común

Los empleados hablan idiomas distintos (Go, Java, Rust, Python). Necesitan un
**formulario oficial** que todos sepan rellenar y leer.

- Un fichero `.proto` es ese formulario: dice "un precio tiene una divisa y un
  importe", "una ruta tiene un aeropuerto de origen y uno de destino".
- A partir del formulario, una herramienta genera automáticamente el código para
  cada idioma. Así nadie se equivoca al interpretarlo.
- Es como un formulario de Hacienda: da igual quién lo rellene, las casillas
  significan siempre lo mismo.

📁 Dónde está: carpeta `proto/`. El código generado automáticamente está en `gen/go/`.

### 📞 gRPC: la llamada de teléfono

Cuando un empleado necesita que otro haga algo **ahora** y le conteste, le llama
por teléfono. Eso es gRPC.

- Ejemplo: el recepcionista llama al vigilante: "vigila el vuelo Madrid–Tokio
  del 1 de diciembre". El vigilante contesta: "hecho, tu número de seguimiento es el 123".
- Usa los formularios de protobuf, así que la conversación es rapidísima y sin malentendidos.

### 📌 Kafka: el tablón de anuncios

A veces un empleado no necesita hablar con nadie en concreto: solo quiere
**anunciar** algo. Para eso hay un tablón de anuncios enorme, que es Kafka.

- El vigilante clava una nota: "Madrid–Tokio, 1 de diciembre: 549 €".
- Cualquiera interesado lee el tablón cuando quiere. El vigilante ni sabe quién lo lee.
- Si quien lee está de vacaciones, las notas **siguen ahí** cuando vuelve. Nada se pierde.
- El tablón tiene **secciones** (se llaman **topics**): una para precios, otra para alertas.
- Cada sección se divide en **columnas** (se llaman **particiones**) para que
  muchos lean a la vez. Todas las notas de una misma ruta van a la misma columna,
  así siempre se leen en orden.

**¿Teléfono o tablón?** Teléfono (gRPC) cuando necesitas respuesta ya. Tablón
(Kafka) cuando solo avisas de que algo ha pasado.

### 🗄️ Las bases de datos: los archivadores

- **PostgreSQL**: un archivador con carpetas muy ordenadas (tablas con filas y columnas).
- **PostGIS**: un añadido de PostgreSQL que entiende de mapas ("¿qué hoteles hay
  a menos de 500 metros?").
- **Redis**: un post-it en la mesa. Rapidísimo de consultar, pero para cosas temporales (caché).
- **Qdrant**: un archivador especial para la inteligencia artificial: guarda
  cosas por su **significado** y no por su nombre ("busca algo parecido a
  *playa tranquila con niños*").

### 🐳 Docker: los contenedores de mercancía

Instalar Kafka, PostgreSQL, Redis y Qdrant a mano en tu ordenador sería un infierno
de versiones y configuraciones. Docker lo resuelve:

- Un **contenedor** es como un contenedor de barco: dentro va un programa con
  todo lo que necesita, y funciona igual en cualquier ordenador.
- Una **imagen** es el "molde" del que sale el contenedor.
- **Docker Compose** es la lista de la compra: "quiero estos 5 contenedores,
  conectados así". Con un comando (`docker compose up`) se levanta todo.

📁 Dónde está: `infrastructure/docker-compose.yml`.

### 🔐 Seguridad: TLS, mTLS y "Zero Trust"

- **TLS** es el candado del navegador: cifra la conversación para que nadie la
  pueda leer por el camino. Normalmente solo el **servidor** enseña su DNI
  (certificado) para demostrar que es quien dice ser.
- **mTLS** (TLS *mutuo*) es cuando **los dos** enseñan el DNI. Nuestros
  empleados solo hablan entre ellos si ambos tienen un carné firmado por la
  empresa. Un intruso sin carné ni siquiera consigue que le cojan el teléfono.
- **Zero Trust** ("confianza cero") significa: **no te fíes de nadie, ni de los
  de dentro**. Cada empleado comprueba cada petición aunque venga de un compañero.
- **Secretos** (contraseñas, claves): nunca se escriben en el código. Van en un
  fichero `.env` que **no se sube a internet**.

### 🏃 Go y las goroutines: muchos ayudantes a la vez

El vigilante tiene que consultar cientos de rutas. Si lo hiciera de una en una,
tardaría muchísimo, porque cada consulta implica esperar a que la aerolínea conteste.

- Go permite crear **goroutines**: ayudantes ligerísimos que trabajan a la vez.
  Mientras uno espera respuesta, otro ya está preguntando por otra ruta.
- Pero no queremos 10.000 ayudantes llamando a la vez a la misma aerolínea (nos
  bloquearía). Por eso hay un **límite**: por ejemplo, 32 a la vez. Es como un
  restaurante con 32 mesas: si están llenas, el siguiente espera en la puerta.

### ✅ Tests: los exámenes automáticos

Un **test** es un pequeño programa que comprueba que otro programa funciona.
Por ejemplo: "si le pido vigilar Madrid–Madrid, debe decir que es un error".

- Se ejecutan solos con un comando (`make test`).
- Si alguien rompe algo sin querer, un test falla y lo avisa.

### 🤖 CI (integración continua): el inspector automático

Cada vez que se propone un cambio en GitHub (un **Pull Request**), un robot
(GitHub Actions) descarga el código, ejecuta todos los tests y levanta los
contenedores para comprobar que todo funciona. Si algo falla, se ve una ❌ roja
antes de aceptar el cambio.

📁 Dónde está: `.github/workflows/ci.yml`.

---

## Parte 4. Un viaje completo, paso a paso

Sigamos a un precio desde que nace hasta que llega al tablón:

1. **Alguien pide vigilar una ruta.** Llega una "llamada" gRPC:
   *vigila Madrid → Tokio, 1 de diciembre, turista*.
2. **El vigilante comprueba los datos.** ¿"MAD" es un aeropuerto válido? ¿La fecha
   existe? Si algo está mal, contesta "petición inválida" y no hace nada más.
3. **La apunta en su libreta** (la *watchlist*). Si ya estaba apuntada, no la
   duplica: devuelve el mismo número de seguimiento.
4. **Cada pocos minutos, el vigilante repasa la libreta.** Lanza ayudantes
   (goroutines) para preguntar el precio de cada ruta, con un máximo a la vez y
   un tiempo límite por pregunta.
5. **Le contestan:** "549,99 €". Lo guarda como `54999` céntimos (con números
   enteros nunca hay errores de redondeo).
6. **Rellena el formulario oficial** (protobuf) con el precio, la ruta, la fecha y
   un número único para esa nota.
7. **Lo clava en el tablón** (Kafka), en la sección `flights.price-observed.v1`, y
   **espera a que Kafka le confirme** que la nota está bien guardada.
8. **En el futuro**, otro empleado (el "sniper") leerá esas notas y, si ve un
   precio anormalmente bajo, clavará una alerta en `flights.fare-alerts.v1`
   para avisarte en el móvil.

---

## Parte 5. Mapa de carpetas (qué hay en cada sitio)

```
ECLIPTA/
├── proto/                     ← Los "formularios oficiales" (protobuf)
├── gen/go/                    ← Código generado automáticamente desde proto/ (no tocar)
├── infrastructure/            ← Docker Compose: Kafka, PostgreSQL, Redis, Qdrant
│   ├── docker-compose.yml     ← La "lista de la compra" de contenedores
│   ├── .env.example           ← Plantilla de contraseñas (la real, .env, no se sube)
│   ├── kafka/create-topics.sh ← Crea las secciones del tablón
│   └── postgres/init/         ← Prepara la base de datos la primera vez
├── services/flight-ingestor/  ← El vigilante de precios (Go)
│   ├── cmd/flight-ingestor/   ← El "botón de encendido": arranca y conecta todo
│   ├── internal/domain/       ← Las reglas del negocio (qué es una ruta válida...)
│   ├── internal/watchlist/    ← La libreta de rutas vigiladas
│   ├── internal/provider/     ← Quien da los precios (de momento, uno simulado)
│   ├── internal/ingest/       ← El bucle que repasa la libreta con ayudantes
│   ├── internal/events/       ← Rellena el formulario para el tablón
│   ├── internal/publisher/    ← Clava las notas en Kafka
│   ├── internal/grpcserver/   ← Atiende las "llamadas de teléfono"
│   ├── internal/protomap/     ← Traduce entre el formulario y las reglas internas
│   ├── internal/config/       ← Lee la configuración y se niega a arrancar si es insegura
│   └── Dockerfile             ← Receta para meter el vigilante en un contenedor
├── docs/                      ← Estas guías
├── .github/workflows/ci.yml   ← El inspector automático
├── .vscode/                   ← Ajustes y extensiones recomendadas para VS Code
├── go.work                    ← Le dice a VS Code que hay varios módulos Go en el proyecto
└── Makefile                   ← Atajos: make test, make up, make down...
```

Los ficheros que terminan en `_test.go` son los exámenes automáticos del
fichero con el mismo nombre.

---

## Parte 6. Pruébalo tú (paso a paso, sin saltarte nada)

**Necesitas instalar:** [Docker Desktop](https://www.docker.com/products/docker-desktop/),
[Git](https://git-scm.com/downloads) y, para los tests, [Go](https://go.dev/dl/).

```bash
# 1. Descarga el proyecto
git clone https://github.com/dp2005dario/NoMad-IQ.git
cd ECLIPTA/infrastructure

# 2. Crea tu fichero de contraseñas a partir de la plantilla
cp .env.example .env
# Abre .env con un editor de texto y rellena cada línea vacía.
# Para inventar una contraseña segura, ejecuta:   openssl rand -base64 32
# Para KAFKA_CLUSTER_ID ejecuta el comando que viene explicado en el propio fichero.

# 3. Arranca la infraestructura (la primera vez tarda porque descarga imágenes)
docker compose up -d --wait

# 4. Comprueba que todo está sano: debe poner "healthy" en cada línea
docker compose ps

# 5. Arranca el vigilante con una ruta de ejemplo, mirando precios cada 10 segundos
SEED_WATCHES="MAD-NRT:2026-12-01:ECONOMY" POLL_INTERVAL=10s \
  docker compose --profile apps up -d --build --wait

# 6. Mira lo que va haciendo (Ctrl+C para salir)
docker compose logs -f flight-ingestor

# 7. Cuando acabes, apágalo todo (tus datos se conservan)
docker compose --profile apps down
```

En el paso 6 verás líneas como `"msg":"ciclo de ingesta terminado" ... "published":1`.
Eso significa que el vigilante ha consultado el precio y lo ha clavado en el tablón. 🎉

**Si algo falla:**
- *"required variable ... is missing a value"* → te falta rellenar esa línea en `.env`.
- *"port is already allocated"* → otro programa usa ese puerto; ciérralo o reinicia el ordenador.
- *"Cannot connect to the Docker daemon"* → abre Docker Desktop y espera a que arranque.

---

## Parte 7. Trabajar con Visual Studio Code

VS Code es el editor que vas a usar. El proyecto ya viene preparado para él.

### 7.1 Abrir el proyecto (una sola vez)

1. Abre VS Code → **File → Open Folder…** (en español: *Archivo → Abrir carpeta…*).
2. Elige la carpeta **raíz** `ECLIPTA` (la que contiene `README.md`), no una subcarpeta.
   Así VS Code ve todo el proyecto a la vez gracias al fichero `go.work`.
3. Si pregunta *"¿Confías en los autores de esta carpeta?"*, pulsa **Sí, confío**.
4. Abajo a la derecha aparecerá *"Este espacio de trabajo tiene extensiones
   recomendadas"* → pulsa **Instalar todas**. Son estas (vienen en `.vscode/extensions.json`):

| Extensión | Para qué sirve |
|---|---|
| **Go** (`golang.go`) | Colores, autocompletado, errores en rojo, ejecutar tests con un clic |
| **Buf** (`bufbuild.vscode-buf`) | Entiende y revisa los ficheros `.proto` |
| **Docker** (`ms-azuretools.vscode-docker`) | Ver y controlar los contenedores desde una pestaña lateral |
| **YAML** (`redhat.vscode-yaml`) | Avisa de errores en `docker-compose.yml` y en la CI |
| **GitHub Actions** (`github.vscode-github-actions`) | Ver el estado de la CI sin salir del editor |

5. La extensión de Go puede pedir instalar herramientas (*gopls*, *dlv*…):
   pulsa **Install All**. Necesitas tener [Go](https://go.dev/dl/) instalado antes.

### 7.2 La terminal integrada

No hace falta abrir otra ventana: **Terminal → New Terminal** (o `` Ctrl+` ``).
Se abre abajo, ya situada en la carpeta del proyecto. Todos los comandos de la
Parte 6 se escriben ahí.

> En **Windows**, los comandos de esta guía están pensados para una terminal tipo
> Linux. Lo más sencillo es elegir **Git Bash** en el desplegable `+ ⌄` de la
> terminal (se instala con Git), o usar WSL. `make` no viene en Windows: si no
> lo tienes, usa los comandos `docker compose ...` y `go test ...` que hay en la Parte 6.

### 7.3 El día a día

| Quiero… | Cómo |
|---|---|
| Arrancar la infraestructura | Terminal: `cd infrastructure` y `docker compose up -d --wait` |
| Ver si los contenedores están sanos | Pestaña lateral de Docker (icono de la ballena) o `docker compose ps` |
| Ver los logs de un contenedor | Pestaña de Docker → clic derecho en el contenedor → **View Logs** |
| Ejecutar un test | Abre un `_test.go` y pulsa **run test** encima de la función |
| Ejecutar todos los tests | Pestaña del matraz 🧪 (Testing) → ▶ |
| Saber qué hace una función | Pasa el ratón por encima: aparece su comentario |
| Ir a donde se define algo | `Ctrl+clic` (o `F12`) sobre el nombre |
| Buscar en todo el proyecto | `Ctrl+Shift+F` |
| Apagar todo | Terminal: `cd infrastructure` y `docker compose --profile apps down` |

Al guardar un fichero Go, VS Code lo **formatea solo** (ajuste incluido en
`.vscode/settings.json`), así que la CI nunca fallará por formato. La carpeta
`gen/` está marcada como **solo lectura**: es código generado y no se toca a mano.

### 7.4 Subir tus cambios a GitHub desde VS Code

1. Pestaña de **Control de código fuente** (el icono de las ramitas, `Ctrl+Shift+G`).
2. Verás los ficheros cambiados. Escribe un mensaje que explique el cambio.
3. Pulsa **Commit** y luego **Sync Changes** (o *Publicar rama*).
4. En GitHub, crea un Pull Request: la CI lo revisará automáticamente.

> ⚠️ El fichero `infrastructure/.env` (tus contraseñas) **nunca** aparecerá en
> esa lista: está ignorado a propósito para que no se suba por error.

---

## Parte 8. Glosario (de la A a la Z)

| Palabra | Explicación sencilla |
|---|---|
| **API** | La "ventanilla" de un programa: las peticiones que acepta y lo que contesta. |
| **Asíncrono** | "Te aviso cuando esté", sin quedarte esperando. Lo contrario de síncrono. |
| **Base de datos** | Un archivador donde los programas guardan información de forma ordenada. |
| **Broker** | Cada servidor de Kafka. El "edificio" donde está el tablón. |
| **Caché** | Copia rápida de algo para no tener que buscarlo otra vez. |
| **Certificado** | El DNI digital de un programa, firmado por una autoridad de confianza (CA). |
| **CI** | Robot que revisa automáticamente cada cambio antes de aceptarlo. |
| **Cifrado** | Convertir información en algo ilegible sin la clave. AES-256 es un tipo muy seguro. |
| **Concurrencia** | Hacer varias cosas a la vez. |
| **Contenedor** | Un programa empaquetado con todo lo que necesita para funcionar en cualquier sitio. |
| **Contrato** | El acuerdo de qué datos se intercambian dos programas (aquí, los `.proto`). |
| **Deep link** | Un enlace que lleva directamente a reservar un vuelo concreto, con nuestro código de afiliado. |
| **Evento** | Un aviso de que algo ha pasado ("he visto este precio"). |
| **Goroutine** | Un ayudante ligerísimo de Go que trabaja en paralelo con otros. |
| **gRPC** | Forma rápida de que un programa "llame" a otro y reciba respuesta. |
| **Healthcheck** | Pregunta periódica "¿estás bien?" a un programa, para reiniciarlo si no contesta. |
| **IATA** | Código de 3 letras de cada aeropuerto: MAD = Madrid, NRT = Tokio-Narita. |
| **Idempotente** | Hacerlo dos veces da el mismo resultado que hacerlo una. |
| **Imagen (Docker)** | El molde del que se crean contenedores. |
| **Kafka** | El tablón de anuncios gigante donde los programas publican eventos. |
| **KRaft** | El modo moderno de Kafka que no necesita ningún programa extra para organizarse. |
| **Log** | El diario de lo que va haciendo un programa. |
| **Microservicio** | Programa pequeño que hace una sola tarea dentro de un sistema mayor. |
| **mTLS** | Conexión cifrada en la que los dos lados enseñan su certificado. |
| **Partición** | Una "columna" de un topic de Kafka; permite repartir el trabajo. |
| **Productor / Consumidor** | Quien escribe en Kafka / quien lee de Kafka. |
| **Protobuf** | Formato para describir datos de forma estricta y compacta. |
| **Pull Request (PR)** | Propuesta de cambio en GitHub que se revisa antes de aceptarla. |
| **Puerto** | El "número de puerta" por el que un programa escucha (5432 = PostgreSQL). |
| **Repositorio** | La carpeta del proyecto con todo su historial de cambios (en GitHub). |
| **Secreto** | Contraseña o clave. Nunca se escribe en el código. |
| **Test** | Programa que comprueba automáticamente que otro funciona bien. |
| **Timeout** | Tiempo máximo de espera; si se supera, se da por fallido. |
| **TLS** | El "candado" que cifra una conexión (el de las webs `https`). |
| **Topic** | Una sección del tablón de Kafka (por ejemplo, la de precios). |
| **Variable de entorno** | Ajuste que se le pasa a un programa al arrancarlo, sin tocar su código. |
| **Volumen (Docker)** | Disco donde un contenedor guarda datos para no perderlos al apagarse. |
| **Zero Trust** | Política de no fiarse de nada ni de nadie, ni siquiera de lo de dentro. |
