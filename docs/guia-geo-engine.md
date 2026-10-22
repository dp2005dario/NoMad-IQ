# Guía del geo-engine: el motor geoespacial en Rust, explicado desde cero

Esta guía es para alguien que **no ha programado nunca en Rust** (ni sabe qué
es un R-tree). Al terminarla deberías poder explicar qué hace el servicio, por
qué está diseñado así y cómo trabajar con él desde Visual Studio Code.

- Código: [`services/geo-engine/`](../services/geo-engine/)
- Ficha técnica: [`services/geo-engine/README.md`](../services/geo-engine/README.md)
- Contratos: [`proto/nomadiq/geo/v1/`](../proto/nomadiq/geo/v1/)

---

## 0. La idea con una analogía (sin tecnicismos)

Imagina la **oficina de turismo** de una ciudad enorme:

- En el **archivo del sótano** (PostgreSQL + PostGIS) están todos los planos
  oficiales: cada aeropuerto del mundo y cada zona marcada (el centro de Madrid,
  el Louvre, el aeropuerto de Barajas...). Es la fuente de verdad, pero bajar al
  sótano cada vez que alguien pregunta sería lentísimo.
- Por eso, en el **mostrador** (el geo-engine, en Rust) hay una **fotocopia** de
  esos planos, con un **índice** que permite encontrar cualquier cosa al
  instante. Cada 30 segundos alguien pregunta al archivo "¿ha cambiado algo?". Si
  sí, prepara una fotocopia nueva **en otra mesa** y, cuando está lista, la
  cambia por la vieja en un segundo. Nadie que esté consultando tiene que esperar.
- Los empleados del mostrador responden tres tipos de preguntas:
  1. "¿Cuál es el aeropuerto más cercano a donde estoy?"
  2. "Quiero ver estos 8 sitios: ¿en qué orden ando menos?" (cuando la pregunta
     es difícil, apuntan la respuesta en una **pizarra** —Redis— durante 15 minutos:
     si alguien repite exactamente la misma pregunta, leen la pizarra).
  3. "¿Estoy dentro de alguna zona especial?"
- Además hay un empleado que escucha una **radio** (Kafka) por la que los móviles
  de los viajeros dicen "estoy aquí". Cuando alguien **cruza la puerta** de una
  zona (entra o sale), lo anuncia por otra radio para que, por ejemplo, la app
  le diga "¡Bienvenido al centro de Madrid! Aquí tienes una audioguía".

Eso es todo el servicio. El resto de la guía explica cada pieza.

---

## 1. Glosario para principiantes

| Palabra | Qué significa, en sencillo |
|---|---|
| **Rust** | Lenguaje de programación tan rápido como C, pero cuyo compilador impide los errores de memoria típicos (el programa no compila si los tiene). |
| **Crate** | Una librería de Rust (como un paquete de Python o un módulo de Go). |
| **Cargo** | La herramienta de Rust para compilar, probar y descargar crates. `Cargo.toml` es su "lista de la compra". |
| **rustup** | El instalador de Rust. Lee `rust-toolchain.toml` y descarga la versión exacta del proyecto. |
| **`unsafe`** | Palabra clave de Rust que desactiva algunas comprobaciones de seguridad. En este servicio está **prohibida** (`unsafe_code = "forbid"`). |
| **FFI** | "Foreign Function Interface": llamar desde Rust a código escrito en C. Si ese C falla, el proceso muere aunque Rust sea seguro. |
| **WGS84** | El "idioma" de coordenadas del GPS: latitud (-90 a 90) y longitud (-180 a 180). |
| **Distancia geodésica** | La distancia real sobre la superficie de la Tierra (que no es una esfera perfecta, está algo achatada). |
| **PostGIS** | Extensión de PostgreSQL que entiende puntos, polígonos y distancias. |
| **Polígono / MultiPolygon** | Una forma cerrada (el contorno de una zona). Un MultiPolygon son varias formas que cuentan como una (dos museos separados = una zona). |
| **WKB** | "Well-Known Binary": formato estándar para guardar una geometría como bytes. Lo hablan PostGIS, QGIS, Android, iOS... |
| **R-tree** | Índice espacial: agrupa objetos cercanos en "cajas" para buscar sin mirarlos todos. |
| **Geofence** | Una "valla virtual" alrededor de una zona. Cruzarla dispara un aviso. |
| **Snapshot (foto)** | Copia en memoria, que no cambia, de todos los datos en un momento dado. |
| **ArcSwap** | Puntero que se puede cambiar de golpe por otro: así se sustituye la foto sin que nadie espere. |
| **gRPC** | Forma rápida y tipada de que dos servicios se llamen entre sí (sobre HTTP/2). |
| **mTLS** | TLS "mutuo": el servidor y el cliente se enseñan certificados. Solo entra quien tiene un certificado de nuestra CA. |
| **Idempotente** | Que hacer la misma operación dos veces da el mismo resultado que hacerla una. Permite reintentar sin miedo. |
| **TTL** | "Time to live": tiempo tras el cual una entrada de caché se borra sola. |
| **DLQ** | "Dead Letter Queue": buzón donde van los mensajes imposibles de procesar, para revisarlos sin bloquear al resto. |
| **Heurística** | Método que da una respuesta muy buena rápido, aunque no garantiza la perfecta. |

---

## 2. El viaje de dos peticiones, paso a paso

### A) "Ordena mi ruta" (gRPC `OptimizeRoute`)

1. Otro servicio (por ejemplo, el ai-orchestrator) llama al geo-engine por gRPC
   con su certificado. Si no lo tiene, o es de otra CA, o no está en la lista
   `GRPC_ALLOWED_CLIENTS`, la conexión se corta antes de llegar al código (`tls.rs`).
2. Se valida todo: entre 2 y 50 paradas, ids únicos, coordenadas en rango, tipo
   de ruta indicado (`grpc.rs`).
3. Se calcula la **huella** de la petición (SHA-256 de paradas + tipo) y se busca
   en Redis. Si está → se devuelve con `from_cache = true` (`cache.rs`).
4. Si no está: si ya hay alguien calculando exactamente lo mismo (un reintento
   llegado a la vez), se espera a ese cálculo en vez de repetirlo ("single flight").
5. Si nadie lo calcula, se pide turno al **semáforo** (como las plazas de un
   aparcamiento: solo N cálculos a la vez) y se calcula en un hilo aparte
   (`spatial/route.rs`):
   - hasta 12 paradas: **algoritmo exacto** (Held-Karp), siempre el mejor orden;
   - más: **vecino más cercano + 2-opt** (deshacer cruces), casi óptimo y rápido.
6. El resultado se guarda en Redis 15 minutos y se devuelve, con el recorrido
   como LineString en **WKB** listo para pintarse en un mapa.

### B) "Un usuario se mueve" (Kafka)

1. La app publica `UserPositionReported` en `geo.user-positions.v1` con clave
   `user_id` (todas las posiciones de Ana van a la misma partición, en orden).
2. El geo-engine lo lee y lo valida (`stream/geofence.rs`). Si es basura → DLQ.
   Si el GPS es demasiado impreciso (> 100 m) o la posición es más antigua que la
   última procesada → se ignora.
3. Lee de Redis en qué zonas estaba Ana (`geo:presence:v1:ana`).
4. Calcula en qué zonas está ahora con el índice en memoria (microsegundos).
5. Por cada zona nueva publica un `GeofenceTransitioned` ENTER; por cada zona
   abandonada, un EXIT. Espera a que Kafka confirme.
6. Guarda el estado nuevo en Redis y marca el mensaje como procesado.

Si el servicio se cae entre el paso 5 y el 6, el mensaje se procesa otra vez y
genera **los mismos eventos con los mismos ids** (un UUID v5 calculado a partir
de la posición, la zona y el tipo). Quien los consuma detecta el duplicado.

---

## 3. Los 5 riesgos que señaló Gemini y qué hemos hecho con cada uno

| # | Riesgo | Qué hemos hecho | Analogía |
|---|---|---|---|
| 1 | Duplicar el trabajo de PostGIS (o sobrecargarlo) | PostGIS guarda, indexa y **valida** (rechaza polígonos rotos). Rust nunca le pregunta por cada petición: solo comprueba cada 30 s una versión diminuta y recarga si cambió. | Archivo en el sótano, fotocopia en el mostrador. |
| 2 | Librerías GIS en C (`GEOS`, `GDAL`, `PROJ`) con `unsafe` | Todo el cálculo geográfico es Rust puro (`geo`, `rstar`, `wkb`) y `unsafe` está prohibido. La única pieza en C es el cliente de Kafka (librdkafka, usado por todo el sector), y vive encerrada en un solo fichero. | No meter en casa un electrodoméstico sin homologar; el único que hay está en su propio enchufe con diferencial. |
| 3 | Bloqueos en el índice compartido | La foto **no cambia nunca**: leerla no necesita cerrojos. La nueva se prepara aparte y se cambia de golpe (`ArcSwap`). En Kafka, cada usuario tiene un único "dueño" (su partición): nadie se pelea por su estado. | Cambiar la pizarra entera en vez de borrarla mientras la leen. |
| 4 | Serializar geometrías campo a campo | Los polígonos y recorridos viajan como bytes **WKB**, el mismo formato que sale de PostGIS. Además, el WKB de cada zona se guarda una vez y se comparte sin copiarlo (`Bytes`). | Enviar el plano en un sobre cerrado en vez de dictarlo punto por punto. |
| 5 | Recalcular rutas en cada reintento | Caché en Redis con clave = huella del contenido (la misma pregunta da la misma clave), caducidad de 15 min, cálculo compartido entre preguntas idénticas simultáneas y un límite de cálculos a la vez. Si Redis falla, se calcula igualmente. | La pizarra con respuestas recientes. |

Una decisión extra que conviene saber contar: **las distancias simples no se
cachean**. Calcular una cuesta ~1 microsegundo; ir a Redis, ~300. Cachear lo
barato lo haría más lento.

---

## 4. Fichero a fichero

### `services/geo-engine/`

| Fichero | Para qué sirve |
|---|---|
| `Cargo.toml` / `Cargo.lock` | Librerías y sus versiones exactas. Reglas de calidad (`[lints]`): `unsafe` prohibido, `unwrap()` prohibido. |
| `rust-toolchain.toml` | Fija Rust 1.97.0 para todos (tú, la CI y Docker). |
| `rustfmt.toml` | Estilo del código (lo aplica `cargo fmt`). |
| `build.rs` | Antes de compilar, convierte los `.proto` en código Rust (con `protox`, sin instalar `protoc`). |
| `migrations/0001_geo_schema.sql` | Tablas `geo.airports`, `geo.zones` y la "versión" de los datos (con triggers que la suben en cada cambio). |
| `migrations/0002_seed_airports.sql` | 1.151 aeropuertos grandes (OurAirports, dominio público). |
| `seeds/demo_zones.sql` | 6 zonas de ejemplo (Madrid, Barcelona, París, Tokio). Solo con `SEED_DEMO_ZONES=true`. |
| `src/main.rs` | Arranque, apagado ordenado y el modo `--healthcheck` para Docker. |
| `src/config.rs` | Lee y valida las variables de entorno; si algo es inseguro, no arranca. Las contraseñas nunca salen en los logs. |
| `src/spatial/coord.rs` | `LatLng`: una coordenada que solo existe si es válida. Distancias y rumbos. |
| `src/spatial/wkb.rs` | Leer y escribir WKB, validando tipo, tamaño, rangos y polígonos. |
| `src/spatial/index.rs` | La foto (`GeoSnapshot`) con sus dos R-trees. |
| `src/spatial/route.rs` | El optimizador de rutas. |
| `src/store.rs` | PostgreSQL: migraciones (con huella para detectar cambios indebidos) y carga coherente. |
| `src/snapshot.rs` | Construir y publicar la foto; el bucle que la refresca. |
| `src/cache.rs` | Redis y la huella de las rutas. |
| `src/grpc.rs` | La API `GeoService`. |
| `src/tls.rs` | TLS 1.3, mTLS y la lista de clientes permitidos. |
| `src/stream/` | El geofencing: `geofence.rs` (lógica pura), `processor.rs` (un mensaje de principio a fin), `kafka.rs` (conexión con Kafka). |
| `src/health.rs` | `/healthz` y `/readyz`. |
| `tests/mtls.rs` | Prueba que sin certificado, con certificado de otra CA, fuera de la lista o con TLS 1.2 **no se entra**. |
| `tests/integration.rs` | Pruebas con PostgreSQL, Redis y Kafka de verdad, y e2e contra el contenedor. |
| `Dockerfile` | Imagen de ~52 MB, sin shell ni root. |

### Cambios fuera del servicio

- `proto/nomadiq/geo/v1/*.proto`: los contratos (y su código Go en `gen/go`).
- `infrastructure/docker-compose.yml`: el servicio `geo-engine` (puertos 50052 y 8087).
- `infrastructure/kafka/create-topics.sh`: topics `geo.*`. Las posiciones se
  guardan solo **24 horas**: son datos personales (RGPD, minimización).
- `.github/workflows/ci.yml`: job `geo-engine (Rust)` y tests en el job de integración.
- `Makefile`: `make test-rust`, `make test-rust-integration`, `make zones`.
- `.vscode/`: extensiones y ajustes de Rust.

---

## 5. Trabajar con el servicio desde Visual Studio Code

### Instalar lo necesario (una sola vez)

**En Windows:**

1. Instala las **Build Tools de Visual Studio** (Rust las necesita para enlazar
   en Windows): descarga "Build Tools for Visual Studio" desde
   <https://visualstudio.microsoft.com/visual-cpp-build-tools/> y marca
   **"Desarrollo para el escritorio con C++"**.
2. Descarga y ejecuta **`rustup-init.exe`** desde <https://rustup.rs>. Pulsa
   Enter para la instalación por defecto.
3. **Cierra y vuelve a abrir VS Code** (para que su terminal vea el nuevo `PATH`).
4. Comprueba en la terminal de VS Code (`Ctrl+ñ` o *Ver → Terminal*):
   ```powershell
   rustup --version
   cargo --version
   ```
5. La librería de Kafka (librdkafka) se compila con herramientas de Linux. En
   Windows lo más cómodo es trabajar dentro de **WSL** (Ubuntu): instala la
   extensión "WSL" de VS Code, abre una terminal Ubuntu y repite allí
   `curl https://sh.rustup.rs -sSf | sh` y `sudo apt install build-essential libssl-dev pkg-config`.
   Después, en VS Code: `F1` → "WSL: Open Folder in WSL" y abre el repositorio.
   Si no quieres instalar nada de esto, `make up-apps` compila el servicio
   dentro de Docker y funciona igual.

**En macOS / Linux:** `curl https://sh.rustup.rs -sSf | sh` y listo (en Linux,
además `build-essential libssl-dev pkg-config`).

No hace falta elegir versión: al ejecutar `cargo` dentro de `services/geo-engine`,
rustup lee `rust-toolchain.toml` y descarga Rust 1.97.0 automáticamente.

**Extensiones** (VS Code te las ofrecerá al abrir el repo, abajo a la derecha:
"Instalar todas"):
- **rust-analyzer**: autocompletado, errores mientras escribes y botones
  "▶ Run Test" encima de cada test.
- **Even Better TOML**: colorea `Cargo.toml`.
- **CodeLLDB**: depurador.

### Abrir el proyecto

*Archivo → Abrir carpeta…* y elige la carpeta raíz `NoMad-IQ`. El fichero
`.vscode/settings.json` ya le dice a rust-analyzer dónde está el `Cargo.toml`.
La primera vez tarda unos minutos en analizar (abajo verás "rust-analyzer: indexing").

### Comandos del día a día (terminal de VS Code)

```bash
cd services/geo-engine
cargo build                                   # compilar (la 1.ª vez tarda; después es incremental)
cargo test                                    # 56 tests sin contenedores, en segundos
cargo fmt                                     # ordenar el formato (la CI lo exige)
cargo clippy --all-targets -- -D warnings     # el "revisor automático" de Rust
cargo doc --open                              # abre la documentación de todo el código en el navegador
```

Desde la raíz del repo: `make test-rust`.

### Ejecutar tests sin escribir comandos

Abre cualquier fichero con tests (por ejemplo `src/spatial/route.rs`) y pulsa
"▶ Run Test" encima de `fn exacto_coincide_con_fuerza_bruta`.

### Depurar ("a cámara lenta")

Haz clic a la izquierda del número de línea para poner un punto rojo (punto de
ruptura) y pulsa "Debug" encima del test. El programa se para ahí y puedes ver
el valor de cada variable en el panel izquierdo.

### Consejos

- Los errores de Rust son largos pero muy buenos: lee la última línea `help:`,
  suele decir exactamente qué cambiar.
- `unwrap()` está prohibido: en Rust los errores se devuelven con `Result` y el
  operador `?` (que significa "si esto falla, devuelve el error hacia arriba").
- Si cambias un `.proto`, basta con `cargo build`: `build.rs` regenera el código.

---

## 6. Probarlo tú mismo

```bash
# 1. Arranca la infraestructura y los servicios (el geo-engine se compila en Docker).
make up-apps

# 2. ¿Está listo? Debe decir "ready": true, 1151 aeropuertos y 6 zonas.
curl http://127.0.0.1:8087/readyz

# 3. Las zonas guardadas en PostGIS:
make zones

# 4. Llamar al gRPC a mano con grpcurl (https://github.com/fullstorydev/grpcurl).
#    En local no hay mTLS (-plaintext); en producción sería imposible sin certificado.
grpcurl -plaintext -import-path proto -proto nomadiq/geo/v1/geo_service.proto \
  -d '{"point":{"latitude":40.4168,"longitude":-3.7038},"limit":3}' \
  127.0.0.1:50052 nomadiq.geo.v1.GeoService/FindNearestAirports

grpcurl -plaintext -import-path proto -proto nomadiq/geo/v1/geo_service.proto \
  -d '{"shape":"ROUTE_SHAPE_ROUND_TRIP","stops":[
        {"stop_id":"hotel","location":{"latitude":40.4168,"longitude":-3.7038}},
        {"stop_id":"prado","location":{"latitude":40.4138,"longitude":-3.6921}},
        {"stop_id":"palacio","location":{"latitude":40.4180,"longitude":-3.7144}},
        {"stop_id":"retiro","location":{"latitude":40.4153,"longitude":-3.6845}}]}' \
  127.0.0.1:50052 nomadiq.geo.v1.GeoService/OptimizeRoute
# Repite el último comando: verás "fromCache": true (salió de Redis).

# 5. Los tests de integración y e2e (Kafka incluido):
make test-rust-integration
```

---

## 7. Cómo contarlo en una entrevista (30 segundos)

> "El geo-engine es un microservicio en Rust que responde consultas geoespaciales
> de alta frecuencia desde índices R-tree en memoria. PostGIS es la fuente de
> verdad; el servicio carga una foto inmutable y la sustituye con un swap
> atómico, así las lecturas nunca cogen cerrojos. Toda la geometría es Rust puro
> con `unsafe` prohibido: lo único en C es el cliente de Kafka, aislado. Las
> geometrías viajan en WKB por gRPC con mTLS y TLS 1.3. La optimización de rutas
> es exacta hasta 12 paradas y heurística por encima, con una caché en Redis
> direccionada por contenido que hace los reintentos idempotentes. Y hace
> geofencing en streaming sobre Kafka con entrega al menos una vez e ids de
> evento deterministas para deduplicar."

Preguntas que te pueden hacer (y la respuesta corta):

- *¿Por qué no usar solo PostGIS?* Porque cada consulta sería un viaje de red y
  carga para la base de datos; en memoria respondemos en microsegundos y
  escalamos añadiendo réplicas sin tocar la base de datos.
- *¿Por qué vectores 3D en el índice de aeropuertos?* Porque comparar grados como
  si fueran un plano falla cerca de los polos y del antimeridiano.
- *¿Qué pasa si se cae Redis?* Las rutas se calculan igual (sin caché) y el
  geofencing reintenta sin perder mensajes.

---

## 8. Lo que NO está hecho todavía (siguientes pasos)

- **Particionado regional del índice** (Europa, Asia...) para cuando haya
  millones de zonas y una sola foto no quepa cómodamente en memoria.
- **Recarga instantánea** con `LISTEN/NOTIFY` de PostgreSQL en lugar de mirar cada 30 s.
- **API de administración de zonas** (hoy se dan de alta por SQL).
- **Rutas por calles reales** (a pie, en transporte): ahora las distancias son
  en línea recta; haría falta un grafo de OpenStreetMap.
- **Histéresis en el geofencing** (no anunciar entrar/salir si alguien camina
  justo por el borde).
- Paralelizar el consumo por partición dentro de cada instancia, métricas
  (Prometheus) y una CA de desarrollo para probar mTLS en local.
- Usuario de base de datos con permisos mínimos (solo el esquema `geo`).
