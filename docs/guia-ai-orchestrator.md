# Guía del ai-orchestrator: el cerebro de IA, explicado desde cero

Esta guía es para alguien que **no sabe nada** de inteligencia artificial ni
de Python. Si es tu primera vez con el proyecto, lee antes
[`guia-principiantes.md`](guia-principiantes.md) (qué es cada carpeta y cómo
instalarlo todo) y [`guia-price-consumer.md`](guia-price-consumer.md) (de
dónde salen las alertas que este servicio recibe). Si algo no se entiende, la
culpa es de la guía, no tuya. Ve por orden.

---

## 0. La idea con una analogía (sin tecnicismos)

Seguimos en la **lonja de pescado** de la guía del price-consumer:

1. El tasador (`price-consumer`) ya ha dejado en una cinta
   (`flights.fare-alerts.v1`) notas del tipo *"Madrid–Tokio ha bajado un 35 %"*.
2. Al final de esa cinta trabaja ahora un **asesor** (`ai-orchestrator`, lo
   que hemos construido). Por cada nota:
   - va al **archivo** (`PostgreSQL`) y mira los precios reales de ese vuelo
     en el último mes: el más bajo, el más alto, el habitual;
   - si tiene una **biblioteca de notas de viaje** (`Qdrant`), busca algo útil
     sobre el destino;
   - le pasa todo eso a un **redactor muy elocuente pero poco fiable con los
     números** (el modelo de IA, ejecutado por `Ollama` en tu ordenador) y le
     pide un consejo corto: *¿compro ya, me lo pienso o espero?*
3. El redactor tiene una regla de hierro: **no puede escribir ni una cifra**.
   Donde va un precio escribe un hueco, por ejemplo `{precio_actual}`, y el
   asesor rellena los huecos con el sello de contabilidad (el dato real).
   Si el redactor se salta la regla, se le devuelve la nota para que la
   corrija… como mucho 3 veces.
4. Si el redactor no está (Ollama apagado), tarda demasiado o no hay manera
   de que lo haga bien, el asesor escribe él mismo un consejo con una
   **plantilla fija** (reglas). Menos bonito, igual de correcto.
5. El consejo se guarda en el archivo (`ai.fare_recommendations`). Cuando el
   usuario abre la app, la **ventanilla** (la API) se lo entrega al instante:
   la ventanilla nunca espera al redactor.

Lo importante: **la IA razona y redacta; los datos los ponemos nosotros.**

---

## 1. Glosario para principiantes

| Palabra | Qué significa, en sencillo |
|---|---|
| **LLM** (modelo de lenguaje) | Un programa entrenado con muchísimo texto que sabe continuar frases. Muy bueno redactando, poco fiable con datos concretos. |
| **Ollama** | Programa gratuito que ejecuta LLMs en tu propio ordenador. Nada sale a internet y no cuesta dinero por uso (presupuesto 0 €). |
| **Modelo** (`llama3.1:8b`) | El "cerebro" que carga Ollama. `8b` = 8 mil millones de parámetros: cabe en un portátil con 8–16 GB de RAM. |
| **Prompt** | Las instrucciones y datos que le damos al modelo. |
| **Token** | El trozo de texto con el que cuentan los modelos (≈ ¾ de palabra). Los límites se miden en tokens. |
| **Ventana de contexto** | Cuánto texto puede "leer" el modelo de una vez. Si te pasas, falla u olvida. |
| **Temperatura** | Lo "creativo" que es el modelo. 0 = siempre lo mismo y obediente; 1 = imaginativo. Usamos 0,1. |
| **Alucinación** | Cuando el modelo se inventa algo y lo dice con total seguridad (un precio, una fecha). |
| **RAG** | *Retrieval-Augmented Generation*: antes de preguntar al modelo, buscamos nosotros los datos y se los damos. Examen "a libro abierto" con el libro que elegimos. |
| **Grounding** (anclaje) | Garantizar que lo que dice el modelo se apoya en datos reales. Aquí, con los huecos `{nombre}`. |
| **Salida estructurada** | Pedir al modelo que conteste en un formato exacto (JSON) en vez de texto libre. |
| **JSON** | Formato de texto para datos: `{"verdict": "BUY_NOW", "headline": "..."}`. |
| **Esquema JSON** | La "plantilla" que dice qué campos debe tener un JSON y de qué tipo. |
| **Pydantic** | Librería de Python que comprueba que los datos cumplen sus reglas (tipos, longitudes...). Es el portero del servicio. |
| **Embedding / vector** | Una lista de números que representa el *significado* de un texto. Textos parecidos → números parecidos. |
| **Qdrant** | Base de datos de vectores: encuentra los textos que *significan* lo mismo que tu pregunta. |
| **FastAPI** | Librería de Python para hacer APIs web, rápida y con tipos. |
| **async / await** | Forma de programar en la que, mientras esperas algo lento (la red, el modelo), el programa atiende otras cosas. |
| **Event loop** | El "camarero" de Python que reparte el tiempo entre todas las tareas `async`. Si alguien lo bloquea, se para todo. |
| **httpx / asyncpg / aiokafka** | Las librerías asíncronas para hablar con Ollama, PostgreSQL y Kafka. |
| **Semáforo** | Contador de turnos: como mucho N tareas a la vez hacen algo (aquí, hablar con Ollama). |
| **Plan B / fallback** | Lo que se hace cuando lo principal falla (aquí, las reglas). |
| **DLQ** | *Dead Letter Queue*: buzón de mensajes imposibles de leer, para revisarlos sin bloquear al resto. |
| **Idempotencia** | Hacer lo mismo dos veces da el mismo resultado que una. Si Kafka repite una alerta, no se duplica nada. |
| **mTLS** | TLS "mutuo": el servidor y quien le llama se enseñan certificados. Solo entra quien tiene uno nuestro. |
| **RBAC** | Control de acceso por roles: sin el rol `USER`, no hay recomendaciones. |
| **uv** | Gestor de Python ultrarrápido: instala Python y las librerías exactas de `uv.lock`. |
| **mypy** | Revisa los tipos del código sin ejecutarlo: muchos errores aparecen al escribir. |
| **ruff** | Formatea el código y avisa de fallos típicos (también de seguridad). |
| **pytest** | La herramienta de tests de Python. |
| **Fake** (doble de pruebas) | Una versión de juguete de algo real. Los tests usan un "LLM falso" que contesta lo que le digamos. |

---

## 2. El viaje de una alerta, paso a paso

1. **Kafka entrega un mensaje** en `flights.fare-alerts.v1` (protobuf binario).
2. **`events.py` lo traduce** a un `FareAlert` y revisa los papeles: UUID
   válido, aeropuertos de 3 letras, misma divisa, enlace `https`... Si algo
   falla, el mensaje original va a `flights.fare-alerts-dlq.v1` con el motivo.
3. **`consumer.py` mira si ya existe** una recomendación para ese `alert_id`
   (Kafka puede repetir mensajes). Si existe, no se gasta GPU en repetirla.
4. **`recommender.py` recupera datos reales** (`store.py`): cuántas veces se
   ha visto ese vuelo en 30 días, mínimo, máximo y mediana.
5. **`grounding.py` los convierte en hechos**:
   `{"precio_actual": "520,00 EUR", "precio_mediano_historial": "780,00 EUR", ...}`.
6. **Se pide al LLM** (con `llm/client.py`) un JSON con tres campos:
   `verdict` (BUY_NOW / CONSIDER / WAIT), `headline` y `explanation`, usando
   huecos. A Ollama le pasamos el esquema JSON y temperatura 0,1.
7. **`llm/structured.py` valida** la respuesta: ¿es JSON? ¿cumple el esquema?
   ¿tiene cifras escritas a mano o huecos inventados (`{hora_salida}`)? Si
   falla, se le explica el error y se reintenta, **3 veces como mucho**.
8. **Se rellenan los huecos** con los datos reales.
   Si cualquier cosa del paso 6–7 falla → **reglas** (mismo formato, sin IA).
9. **Se guarda** en `ai.fare_recommendations` y, al terminar el lote,
   se confirma a Kafka ("commit"). Si el proceso muere antes, Kafka
   lo vuelve a entregar y la idempotencia evita duplicados.
10. **El usuario consulta** `GET /v1/recommendations`. El proxy de borde ya
    validó su token con el auth-gateway y nos pasa `X-User-ID`; solo ve
    lo suyo.

---

## 3. Los 5 riesgos que señaló Gemini y qué hemos hecho con cada uno

| Riesgo | Qué hemos hecho | Dónde mirarlo |
|---|---|---|
| **1. Bloqueo del event loop.** Si se espera al modelo de forma bloqueante, dos peticiones a la vez tumban el servicio. | Todo es asíncrono (`httpx.AsyncClient`, `asyncpg`, `aiokafka`). Además, **la API nunca llama al LLM**: la inferencia ocurre en segundo plano en el consumidor, con **Kafka como cola de trabajo** (lo que Gemini sugería con Celery/RQ, pero usando la pieza que ya tenemos). Un semáforo limita las llamadas simultáneas a Ollama y cada llamada tiene tiempo máximo. | `llm/client.py`, `consumer.py`, `api.py` |
| **2. JSON frágil.** El modelo añade "¡Claro! Aquí tienes…" o rompe el JSON. | Esquema JSON generado por Pydantic y enviado a Ollama, temperatura 0,1, validación estricta (campos de más = error, valores cerrados), se tolera el envoltorio de texto alrededor del JSON pero no se "adivina" JSON roto, y **reintentos acotados** con el error explicado. | `llm/structured.py`, `recommender.py` (`FareAdvice`) |
| **3. Alucinaciones.** Precios u horarios inventados. | **RAG** con el historial real (PostgreSQL) y notas de Qdrant. Y algo más fuerte: el modelo **no puede escribir dígitos**; usa huecos que rellenamos con los datos reales. Una respuesta con un número escrito a mano o un hueco inexistente se rechaza. Si persiste, plan B por reglas. Se guardan los hechos usados (`facts`) para auditar. | `grounding.py`, `retrieval.py`, `store.py` |
| **4. Explosión de tokens.** El historial de un chat de grupo no cabe. | Presupuesto de tokens por llamada (ventana − respuesta × intentos). Las notas de Qdrant se recortan y solo entran las que caben; los hechos, siempre. Para chats: se conservan instrucciones + mensajes recientes y lo antiguo se sustituye por un resumen de tamaño máximo. | `context.py`, `recommender.py` |
| **5. Bucles infinitos entre agentes.** | Motor de negociación con **máximo de rondas** (techo absoluto 10), tiempo por ronda y total (el agente lento o roto no bloquea), concesiones que no se retiran, parada por estancamiento y, sin consenso, un **árbitro determinista** (primero el peor parado, luego Borda, luego precio, luego orden alfabético). Las opciones inventadas por un agente se descartan. Todo explicado en la [guía de la negociación de grupo](guia-negociacion-grupo.md). | `negotiation/engine.py`, `tests/test_negotiation.py` |

---

## 4. Fichero a fichero

### `services/ai-orchestrator/`

| Fichero | Para qué sirve |
|---|---|
| `pyproject.toml` | La "ficha" del proyecto: librerías, y reglas de ruff, mypy y pytest. |
| `uv.lock` | Versiones exactas de todas las librerías (no se edita a mano: `uv lock`). |
| `Dockerfile` | Receta de la imagen: dos etapas, sin herramientas de desarrollo, usuario sin privilegios. |
| `scripts/generate_proto.py` | Genera `src/nomadiq/` desde `proto/` (los "planos" de los mensajes de Kafka). |
| `src/nomadiq/` | Código **generado**: no se edita (VS Code lo marca como solo lectura). |
| `src/ai_orchestrator/config.py` | Lee y valida las variables de entorno. Lo inseguro no arranca. |
| `src/ai_orchestrator/domain.py` | Los tipos del negocio (`FareAlert`, `Money`, `Recommendation`...). |
| `src/ai_orchestrator/events.py` | Traduce protobuf ↔ dominio y prepara la DLQ. |
| `src/ai_orchestrator/llm/client.py` | Cliente asíncrono de Ollama con tiempos máximos y turnos. |
| `src/ai_orchestrator/llm/structured.py` | JSON válido o reintento (acotado). |
| `src/ai_orchestrator/grounding.py` | Hechos, control de huecos y rellenado. |
| `src/ai_orchestrator/retrieval.py` | Las fuentes de contexto (RAG): historial y Qdrant. |
| `src/ai_orchestrator/recommender.py` | El prompt, la llamada al modelo y el plan B por reglas. |
| `src/ai_orchestrator/context.py` | Cuenta tokens, recorta y resume. |
| `src/ai_orchestrator/negotiation/` | Negociación de grupo con agentes de IA (ver [su guía](guia-negociacion-grupo.md)). |
| `src/ai_orchestrator/store.py` | PostgreSQL: migraciones, historial y recomendaciones. |
| `src/ai_orchestrator/migrations/0001_*.sql` | La tabla `ai.fare_recommendations`. |
| `src/ai_orchestrator/consumer.py` | El bucle de Kafka: lotes, commits, DLQ y reintentos. |
| `src/ai_orchestrator/api.py` | La ventanilla: identidad, roles y errores bien formados. |
| `src/ai_orchestrator/logs.py` | Logs en JSON (sin prompts ni respuestas del modelo, por privacidad). |
| `src/ai_orchestrator/__main__.py` | Arranca todo, configura mTLS y apaga con orden. |

### Tests (`tests/`)

| Fichero | Qué comprueba |
|---|---|
| `conftest.py` | Datos de ejemplo y los "fakes": LLM de guion, historial, base de datos en memoria. |
| `test_structured.py` | JSON roto → reintento; nunca más de 3 intentos; el esquema y la temperatura llegan a Ollama. |
| `test_grounding.py` | Cifras a mano o huecos inventados se rechazan; los valores reales se rellenan bien. |
| `test_recommender.py` | LLM correcto → texto con precios reales; LLM caído o mentiroso → reglas. |
| `test_negotiation.py` | Siempre termina; el árbitro da siempre el mismo ganador; agentes lentos no bloquean. |
| `test_context.py` | Lo reciente se queda, lo antiguo se resume, el total nunca se pasa. |
| `test_ollama_client.py` | Errores de red, tiempos máximos y que nunca hay más de N llamadas a la vez. |
| `test_api.py` | Sin identidad → 401; sin rol → 403; lo de otro → 404; sin detalles internos en errores. |
| `test_consumer.py` | Commit después de guardar; DLQ; reintentos sin perder el mensaje; sin LLM repetido. |
| `test_events.py`, `test_config.py`, `test_qdrant.py` | Traducción de Kafka, configuración segura y búsqueda en Qdrant. |
| `test_integration.py` | Con Kafka y PostgreSQL **reales**: de un mensaje en Kafka a una fila en la base de datos. |

### Cambios fuera del servicio

- `infrastructure/docker-compose.yml`: servicio `ai-orchestrator` (perfil
  `apps`) y `ollama` (perfil `ai`, opcional porque los modelos pesan GB).
- `infrastructure/kafka/create-topics.sh`: nuevo topic `flights.fare-alerts-dlq.v1`.
- `.github/workflows/ci.yml`: job `ai-orchestrator (Python)` y pasos en el de integración.
- `Makefile`: `test-python`, `proto-python`, `ollama`, `recommendations`.
- `.vscode/`: extensiones y ajustes de Python.

---

## 5. Trabajar con el servicio desde Visual Studio Code

### Instalar lo necesario (una sola vez)

1. **uv** (instala Python por ti, no hace falta instalar Python aparte):
   - macOS / Linux: `curl -LsSf https://astral.sh/uv/install.sh | sh`
   - Windows (PowerShell): `powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"`
   - Cierra y vuelve a abrir la terminal, y comprueba con `uv --version`.
2. **Docker Desktop** (ya lo tienes si seguiste las otras guías).
3. **Extensiones de VS Code**: al abrir la carpeta, VS Code te ofrecerá
   instalar las recomendadas. Pulsa **"Instalar todas"**. Para Python son:
   - *Python* (Microsoft): autocompletado, depurador y tests.
   - *Ruff*: formatea al guardar y avisa de fallos (igual que la CI).
   - *Mypy Type Checker*: subraya en rojo los errores de tipos.

### Preparar el entorno de Python

En la terminal integrada (`Ver → Terminal`, o `Ctrl + ñ`):

```bash
cd services/ai-orchestrator
uv sync
```

Eso crea la carpeta `.venv` (el "entorno virtual": una caja con Python 3.13
y las librerías exactas de este servicio, separada del resto de tu
ordenador). VS Code la detecta sola; si no, `Ctrl + Shift + P` →
*"Python: Select Interpreter"* → elige la de `services/ai-orchestrator/.venv`
(en Windows: `.venv\Scripts\python.exe`).

### Comandos del día a día

```bash
uv run pytest                 # tests (menos de 1 segundo, sin Ollama)
uv run pytest -k grounding    # solo los que contienen "grounding" en el nombre
uv run ruff format .          # ordena el código
uv run ruff check .           # busca fallos típicos
uv run mypy                   # revisa los tipos
```

`uv run` significa "ejecuta esto dentro de la caja `.venv`". O, desde la
raíz del proyecto, `make test-python` lo hace todo de una vez.

### Ejecutar tests sin escribir comandos

Icono del **matraz** (Testing) en la barra lateral → aparecen todos los tests
de `tests/`. Pulsa ▶ junto a uno para ejecutarlo; un tick verde es que pasa.

### Depurar (ver el programa "a cámara lenta")

Abre un test, por ejemplo `tests/test_recommender.py`, haz clic a la
izquierda del número de una línea (aparece un punto rojo, un *breakpoint*)
y, en el panel de tests, usa *"Debug Test"*. El programa se parará ahí y
podrás ver el valor de cada variable (por ejemplo, el prompt exacto que se
le envía al modelo).

### Consejos

- Si ves algo subrayado en rojo, pasa el ratón por encima: suele ser mypy
  diciéndote que un tipo no encaja. Arréglalo antes de subir: la CI falla igual.
- No edites `src/nomadiq/`: si cambian los `.proto`, ejecuta `make proto-python`.
- Si añades una librería: `uv add nombre` (actualiza `pyproject.toml` y `uv.lock`).

---

## 6. Probarlo tú mismo

```bash
# 1. Arranca todo (incluido el ai-orchestrator). Sin Ollama ya funciona: usa reglas.
make up-apps
curl http://127.0.0.1:8086/readyz

# 2. (Opcional) Arranca Ollama y descarga el modelo (~5 GB la primera vez).
make ollama

# 3. Provoca alertas: sube la probabilidad de tarifas error en infrastructure/.env
#    SIMULATED_ERROR_FARE_RATE=0.5
#    SEED_WATCHES=MAD-NRT:2026-12-01:ECONOMY
#    SEED_SUBSCRIPTIONS=dario|MAD-NRT:2026-12-01:ECONOMY
#    y reinicia: make up-apps

# 4. Mira las recomendaciones en la base de datos...
make recommendations

# 5. ...o por la API, haciéndote pasar por el proxy de borde (solo en local,
#    donde no hay mTLS; en producción esto es imposible sin certificado).
curl http://127.0.0.1:8085/v1/recommendations -H 'X-User-ID: dario' -H 'X-User-Roles: USER'

# 6. Documentación interactiva de la API (solo en local):
#    abre http://127.0.0.1:8085/docs en el navegador.
```

En la columna `source` verás `llm` (redactada por el modelo) o `rules`
(plan B). Prueba a apagar Ollama (`docker compose stop ollama` en
`infrastructure/`) y verás que las nuevas salen con `rules`, sin errores.

---

## 7. Cómo contarlo en una entrevista (30 segundos)

> "El orquestador de IA consume alertas de Kafka y genera recomendaciones con
> un LLM local vía Ollama, a coste cero. Lo diseñé contra los cinco fallos
> típicos de los sistemas con LLM: todo es asíncrono y la inferencia va en
> segundo plano con Kafka como cola, así la API responde en milisegundos; las
> salidas son JSON validado con Pydantic, temperatura baja y reintentos
> acotados; el modelo no puede escribir cifras, solo huecos que relleno con
> datos de PostgreSQL, así que es imposible que alucine un precio; controlo el
> presupuesto de tokens; y la negociación multi-agente tiene rondas máximas y
> un árbitro determinista. Si el modelo cae, hay un plan B por reglas: la
> funcionalidad se degrada, nunca se rompe. Y por seguridad, mTLS con TLS 1.3,
> identidad del auth-gateway y aislamiento por usuario en la consulta SQL."

---

## 8. Lo que NO está hecho todavía (siguientes pasos)

- ~~**Agentes LLM reales para la negociación en grupo**~~: hecho, ver la
  [guía de la negociación de grupo](guia-negociacion-grupo.md).
- **Cargar la base de conocimiento de Qdrant**: el buscador está listo, pero
  la colección `travel_knowledge` está vacía. Falta un proceso que la llene
  (guías de destinos con su fuente) y vectorice con `nomic-embed-text`.
- **Publicar la recomendación en Kafka** (`ai.fare-recommendations.v1`, con
  su contrato en `proto/`) para que un futuro servicio de notificaciones la
  envíe al móvil.
- **Re-generar con IA** las recomendaciones que salieron por reglas cuando
  Ollama vuelva (hoy se quedan como `rules`).
- **Usuario de base de datos propio** con permisos mínimos (solo lectura en
  `flights.price_observations`, escritura solo en el esquema `ai`) y, a
  escala, un índice o una réplica de lectura para la consulta del historial.
- **mTLS real en local**: una CA de desarrollo y el proxy de borde en
  docker compose (pendiente también del auth-gateway).
- **Métricas** (Prometheus): tiempo de inferencia, % de respuestas por
  reglas, reintentos por respuesta inválida.
- **Evaluación de calidad del prompt** con un conjunto de alertas de ejemplo
  y un modelo real (los tests actuales prueban las tuberías, no el estilo).
