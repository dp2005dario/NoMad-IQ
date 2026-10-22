# ai-orchestrator (Python FastAPI + Ollama)

Cerebro de IA de NomadIQ. Lee las alertas de chollos que publica el
`price-consumer` en Kafka y las convierte en una **recomendación corta y
fundamentada** ("Compra ya: 520,00 EUR, el mínimo del último mes") usando un
modelo de lenguaje **local** (Ollama). El modelo nunca inventa precios ni fechas.

> ¿Empiezas desde cero? Lee primero [`docs/guia-ai-orchestrator.md`](../../docs/guia-ai-orchestrator.md).

```
Kafka flights.fare-alerts.v1 ──► consumer ──► recommender ──┬─► PostgreSQL: historial de precios real (RAG)
            │ (protobuf)          │               │         ├─► Qdrant: notas de viaje (RAG, opcional)
            ▼                     │               │         └─► Ollama /api/chat (JSON con esquema, temperatura baja)
 flights.fare-alerts-dlq.v1       │               ▼
   (mensajes ilegibles)           │      validación Pydantic + "huecos" {precio_actual} ─► reintento acotado
                                  │               │ si falla o no hay LLM: reglas deterministas
                                  ▼               ▼
                         ai.fare_recommendations (PostgreSQL) ◄── GET /v1/recommendations (mTLS + X-User-ID)
```

## Endpoints

| Método y ruta | Acceso | Qué hace |
|---|---|---|
| `GET /v1/recommendations?limit=20` | `X-User-ID` + rol `USER` | Últimas recomendaciones del usuario (1–50). |
| `GET /v1/recommendations/{alert_id}` | `X-User-ID` + rol `USER` | Una recomendación; 404 si no existe **o no es tuya**. |
| `GET /v1/audioguides/{zone_id}?lang=es` | `X-User-ID` + rol `USER` | Guion de la audioguía de una zona (genérico, desde la caché de Redis); 404 si aún no está listo. |
| `GET /v1/audioguides/{zone_id}/audio?lang=es` | `X-User-ID` + rol `USER` | Manifiesto del audio: URLs de cada párrafo, duración y texto. Si la versión actual aún se graba, devuelve la anterior con `stale: true`; 404 si no hay ninguna (la app puede usar la voz del teléfono). |
| `GET /v1/audio/<zona>/<idioma>/v<N>/<huella>/parte-<n>.opus` | ninguna (contenido público) | Archivo Ogg Opus **inmutable** (`Cache-Control: immutable`, 1 año). En producción lo sirve la CDN. |
| `GET :8086/healthz`, `GET :8086/readyz` | red interna | Salud (readyz: PostgreSQL + consumidores Kafka + Redis; Ollama no cuenta porque hay plan B). |

La identidad llega en `X-User-ID` / `X-User-Roles`, ya verificada por el
`auth-gateway` (forward auth del proxy de borde). El puerto 8085 exige **mTLS
con TLS 1.3**, así que solo el proxy puede enviarlas. Errores en RFC 9457
(`application/problem+json`). Ningún endpoint espera al LLM.

## Mitigación de los riesgos de un sistema con LLM

| Riesgo | Cómo se resuelve | Dónde |
|---|---|---|
| 1. Bloqueo del event loop | Todo es `async` (httpx, asyncpg, aiokafka). La inferencia ocurre en el consumidor de Kafka, en segundo plano; la API solo lee PostgreSQL. Semáforo de concurrencia hacia Ollama y tiempo máximo por llamada. | `llm/client.py`, `consumer.py` |
| 2. JSON roto o con "charla" | Esquema JSON de Pydantic enviado a Ollama (`format`), temperatura 0.1, validación estricta (`extra="forbid"`), reintentos con el error explicado, **máximo 3**. | `llm/structured.py` |
| 3. Alucinaciones | RAG sobre datos reales (historial en PostgreSQL, notas en Qdrant). El modelo **no puede escribir cifras**: usa huecos `{precio_actual}` que rellenamos nosotros; cualquier dígito o hueco desconocido = respuesta rechazada. Plan B por reglas. | `grounding.py`, `recommender.py`, `retrieval.py` |
| 4. Saturación del contexto | Estimación de tokens, presupuesto por llamada, recorte de notas, historial de chat con los mensajes recientes + resumen acotado de lo antiguo. | `context.py` |
| 6. Audioguías: latencia, estampidas y privacidad | Consumidor propio de `geo.zone-entries.v1` (entradas **anónimas**: solo `zone_id` + idioma). Guion **genérico por zona+idioma** en Redis; un lote agrupa las entradas repetidas, *single flight* en el proceso y cerrojo `SET NX` entre réplicas: un autobús = una generación. Hechos verificados en `ai.zone_facts`; cada párrafo cita sus hechos y se rechaza cualquier cifra que no esté en ellos. Plan B por reglas con caducidad corta. La clave lleva la **versión del contenido** de la zona (`ai:audioguide:v2:<zona>:<idioma>:<versión>`), que un trigger sube al tocar `ai.zone_facts`; la versión se recuerda 60 s en memoria, así que corregir un hecho se nota en ≤ 60 s sin consultar PostgreSQL en cada entrada. | `audioguides/`, `migrations/0003_zone_content_version.sql` |
| 7. Voz (TTS): CPU, audio viejo y doble escritura | **Pregeneración en segundo plano**, nunca al vuelo: al subir la versión, un trigger apunta el trabajo en `ai.audio_jobs` en la **misma transacción** (outbox, sin doble escritura) y avisa con `pg_notify`; un worker aparte (`--audio-worker`, con techo de CPU) lo coge con `FOR UPDATE SKIP LOCKED` y préstamo con caducidad. Piper (local, gratis) + Opus a 24 kbps, como programas externos con tiempo máximo y sin heredar secretos. **URLs inmutables** con versión y huella del guion: ni CDN ni móvil sirven audio viejo y nunca hay que purgar. Mientras se graba la versión nueva, suena la anterior (`stale`). | `audioguides/audio_*.py`, `speech.py`, `migrations/0004_audio_outbox.sql` |
| 5. Bucles en la negociación | Esqueleto con máximo de rondas (techo absoluto 10), tiempo por ronda, contexto de una sola postura por agente y árbitro determinista (Borda + desempates fijos). | `negotiation.py` |

## Estructura

| Módulo | Responsabilidad |
|---|---|
| `config.py` | Variables de entorno tipadas y validadas (no arranca si algo es inseguro) |
| `domain.py` | Tipos de dominio con Pydantic: `FareAlert`, `Money`, `Recommendation`... |
| `events.py` | Protobuf de Kafka → `FareAlert` (y cabeceras de DLQ) |
| `llm/client.py` | Cliente asíncrono de Ollama (`/api/chat`, `/api/embed`) |
| `llm/structured.py` | Salidas estructuradas con validación y reintentos acotados |
| `grounding.py` | Hechos verificados, control de huecos y rellenado |
| `retrieval.py` | Fuentes de contexto: historial de precios y Qdrant |
| `recommender.py` | Prompt, llamada al LLM y plan B por reglas |
| `context.py` | Presupuesto de tokens, recorte y resumen |
| `negotiation.py` | Motor de negociación multi-agente acotado (esqueleto) |
| `store.py` | PostgreSQL: migraciones, historial y recomendaciones |
| `audioguides/` | Audioguías por zona: eventos, hechos, redactor anclado, caché Redis + *single flight*, servicio y consumidor; y la voz: cola outbox, worker de audio, Piper + Opus, almacén y catálogo |
| `tts/` | Piper fijado con huellas SHA-256 (se instala aparte, en la imagen del worker) |
| `consumer.py` | Bucle de Kafka: commits manuales, DLQ y reintentos |
| `api.py` | FastAPI: identidad, RBAC y errores RFC 9457 |
| `__main__.py` | Arranque, mTLS y apagado ordenado |
| `src/nomadiq/` | Código **generado** desde `proto/` (no editar: `make proto-python`) |

## Configuración

| Variable | Por defecto | Descripción |
|---|---|---|
| `HTTP_PORT` / `MANAGEMENT_PORT` | `8085` / `8086` | API / salud |
| `TLS_CERT_FILE`, `TLS_KEY_FILE`, `TLS_CLIENT_CA_FILE` | — | mTLS de la API (las tres juntas, PEM) |
| `HTTP_INSECURE_DEV` | `false` | Solo local: API sin TLS |
| `EXPOSE_API_DOCS` | `false` | Publica `/docs` y `/openapi.json` |
| `KAFKA_BROKERS` | **obligatoria** | Separados por comas |
| `KAFKA_GROUP_ID` / `KAFKA_CLIENT_ID` | `ai-orchestrator` | |
| `KAFKA_TOPIC_FARE_ALERTS` / `KAFKA_TOPIC_DLQ` | `flights.fare-alerts.v1` / `flights.fare-alerts-dlq.v1` | |
| `KAFKA_TLS_CA_FILE` | — | Activa TLS hacia Kafka |
| `KAFKA_MAX_POLL_RECORDS` | `20` | Mensajes por lote |
| `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGDATABASE` | **obligatorias** | PostgreSQL (esquema `ai`) |
| `PGPORT` / `PG_MAX_CONNS` | `5432` / `10` | |
| `PGSSLMODE` / `PGSSLROOTCERT` | `verify-full` / — | TLS 1.3 verificando el servidor |
| `DB_INSECURE_DEV` | `false` | Solo local: permite otros `PGSSLMODE` |
| `LLM_ENABLED` | `true` | `false` = todo por reglas |
| `OLLAMA_URL` / `OLLAMA_MODEL` / `OLLAMA_EMBED_MODEL` | `http://localhost:11434` / `llama3.1:8b` / `nomic-embed-text` | |
| `OLLAMA_TIMEOUT_SECONDS` / `OLLAMA_MAX_CONCURRENCY` / `OLLAMA_NUM_CTX` | `60` / `2` / `4096` | |
| `OLLAMA_TLS_CA_FILE`, `OLLAMA_TLS_CERT_FILE`, `OLLAMA_TLS_KEY_FILE` | — | mTLS hacia el proxy que protege Ollama |
| `OLLAMA_INSECURE_DEV` | `false` | Solo local: Ollama por http |
| `LLM_TEMPERATURE` / `LLM_MAX_ATTEMPTS` / `LLM_MAX_OUTPUT_TOKENS` | `0.1` / `3` / `400` | |
| `PRICE_HISTORY_WINDOW_DAYS` | `30` | Ventana del historial que se le da al modelo |
| `QDRANT_URL`, `QDRANT_API_KEY`, `QDRANT_COLLECTION` | — / — / `travel_knowledge` | Notas de viaje (opcional) |
| `QDRANT_TLS_CA_FILE` / `QDRANT_INSECURE_DEV` | — / `false` | |
| `KNOWLEDGE_MAX_SNIPPETS` | `3` | Notas por recomendación (0 = ninguna) |
| `AUDIOGUIDES_ENABLED` | `true` | Consumidor de entradas a zonas + API de audioguías (necesita Redis) |
| `KAFKA_TOPIC_ZONE_ENTRIES` / `KAFKA_TOPIC_ZONE_ENTRIES_DLQ` | `geo.zone-entries.v1` / `geo.zone-entries-dlq.v1` | |
| `KAFKA_AUDIOGUIDES_GROUP_ID` | `ai-orchestrator-audioguides` | Grupo propio (no frena a las alertas) |
| `REDIS_HOST`, `REDIS_PASSWORD` | **obligatorias** con audioguías | Caché de guiones |
| `REDIS_PORT` / `REDIS_TLS` / `REDIS_TLS_CA_FILE` | `6379` / `true` / — | TLS 1.3 |
| `REDIS_INSECURE_DEV` | `false` | Solo local: permite `REDIS_TLS=false` |
| `AUDIOGUIDE_DEFAULT_LANGUAGE` | `en` | Si la app no indica idioma (admitidos: es, en, fr, de, it, pt) |
| `AUDIOGUIDE_LLM_TTL_SECONDS` / `AUDIOGUIDE_RULES_TTL_SECONDS` | `86400` / `3600` | Vida en caché del guion del LLM (24 h) / del plan B |
| `AUDIOGUIDE_VERSION_CACHE_SECONDS` | `60` | Cuánto recuerda cada réplica la versión del contenido de una zona: lo máximo que tarda en notarse un hecho corregido |
| `AUDIO_DIR` | — | Carpeta del audio grabado. Sin ella, la API no ofrece audio (solo texto) |
| `AUDIO_PUBLIC_BASE_URL` | `/v1/audio` | Prefijo de las URLs de audio (en producción, la CDN) |
| `AUDIO_MANIFEST_CACHE_SECONDS` | `60` | Cuánto recuerda la API el manifiesto de audio de una zona |
| `TTS_VOICES_DIR` | `/voices` | Solo el worker: `<dir>/<idioma>/<voz>.onnx` (una voz por idioma; `make voices`) |
| `TTS_PIPER_BIN` / `TTS_OPUSENC_BIN` | `piper` / `opusenc` | Programas de voz y de compresión |
| `TTS_BITRATE_KBPS` / `TTS_TIMEOUT_SECONDS` | `24` / `120` | Calidad Opus (≈180 KB/min) y tiempo máximo por párrafo |
| `AUDIO_JOB_LEASE_SECONDS` / `AUDIO_POLL_SECONDS` / `AUDIO_MAX_ATTEMPTS` | `900` / `30` / `5` | Préstamo de un trabajo, revisión de la cola sin aviso y fallos antes de abandonar |
| `AUDIOGUIDE_MAX_WORDS` / `AUDIOGUIDE_MAX_OUTPUT_TOKENS` | `260` / `900` | ≈ menos de dos minutos de audio |
| `LOG_LEVEL` | `info` | Logs JSON |

## Desarrollo

```bash
cd services/ai-orchestrator
uv sync                          # crea .venv con Python 3.13 y las librerías de uv.lock
uv run pytest                    # tests unitarios (LLM falso, sin Ollama)
uv run ruff format . && uv run ruff check . && uv run mypy
uv run pytest -m integration     # con "make up" y las variables PG* y REDIS_* (ver Makefile)
uv run python -m ai_orchestrator --pregenerate-audioguides es,en   # rellena la caché de todas las zonas
```

Desde la raíz: `make test-python`, `make test-integration`, `make up-apps`,
`make ollama` (descarga el modelo) y `make recommendations`.

Audio: `make voices` (descarga las voces, comprobando su SHA-256),
`make audio-worker` (arranca el worker de audio en Docker) y `make audio`
(qué hay grabado y qué queda en la cola).
