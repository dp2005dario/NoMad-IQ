"""Configuración del servicio, leída de variables de entorno y validada al arrancar.

¿Por qué variables de entorno?
    Porque el mismo programa se ejecuta en tu portátil, en la CI y en
    producción con valores distintos (direcciones, contraseñas...). Ninguna
    contraseña se escribe en el código: llegan desde fuera (.env en local, un
    gestor de secretos en producción).

¿Por qué validar tanto?
    Analogía: el piloto revisa la lista de comprobación ANTES de despegar, no
    en pleno vuelo. Si falta un dato o la configuración es insegura (por
    ejemplo, base de datos sin cifrar fuera de tu ordenador), el servicio se
    niega a arrancar con un mensaje claro, en vez de fallar a medianoche.
    Lo inseguro solo se permite si se pide explícitamente con un *_INSECURE_DEV.
"""

from __future__ import annotations

import re
from pathlib import Path
from typing import Literal, Self

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from ai_orchestrator.audioguides.domain import SUPPORTED_LANGUAGES
from ai_orchestrator.pseudonym import Pseudonymizer

# El único modo de TLS de PostgreSQL que comprueba el certificado Y el nombre
# del servidor. Los demás ("require", "prefer"...) cifran, pero no impiden
# hablar con un impostor.
SECURE_PG_SSLMODES = frozenset({"verify-full"})


class Settings(BaseSettings):
    """Todas las opciones del servicio. Cada campo = una variable de entorno.

    El nombre de la variable es el del campo en MAYÚSCULAS: el campo
    ``kafka_brokers`` se lee de ``KAFKA_BROKERS``.
    """

    # extra="ignore": el entorno tiene muchas otras variables (PATH, HOME...)
    # que no son nuestras; las ignoramos en vez de fallar.
    model_config = SettingsConfigDict(extra="ignore", frozen=True)

    # --- Servidores HTTP -------------------------------------------------------
    http_port: int = Field(default=8085, ge=1, le=65535)
    # Puerto aparte para /healthz y /readyz: así Docker/Kubernetes pueden
    # preguntar "¿estás vivo?" sin necesitar un certificado de cliente.
    management_port: int = Field(default=8086, ge=1, le=65535)
    # mTLS: certificado y clave del servicio + CA con la que se comprueban los
    # certificados de quien nos llama (el proxy de borde). Las tres juntas.
    tls_cert_file: Path | None = None
    tls_key_file: Path | None = None
    tls_client_ca_file: Path | None = None
    http_insecure_dev: bool = False
    # Documentación interactiva /docs: útil en local, nunca expuesta en producción.
    expose_api_docs: bool = False

    # --- Kafka -----------------------------------------------------------------
    kafka_brokers: str = Field(min_length=1)
    kafka_client_id: str = "ai-orchestrator"
    kafka_group_id: str = "ai-orchestrator"
    kafka_topic_fare_alerts: str = "flights.fare-alerts.v1"
    kafka_topic_dlq: str = "flights.fare-alerts-dlq.v1"
    kafka_tls_ca_file: Path | None = None
    # Cuántos mensajes se piden a Kafka de golpe. Pocos, porque cada uno puede
    # implicar una llamada al LLM de varios segundos.
    kafka_max_poll_records: int = Field(default=20, ge=1, le=500)

    # --- Audioguías por zona (ver el paquete audioguides/) ------------------------
    # Interruptor general. Necesita Redis (la caché de guiones).
    audioguides_enabled: bool = True
    kafka_topic_zone_entries: str = "geo.zone-entries.v1"
    kafka_topic_zone_entries_dlq: str = "geo.zone-entries-dlq.v1"
    # Grupo de consumidores PROPIO: las audioguías avanzan a su ritmo, sin
    # frenar ni ser frenadas por las alertas de precio.
    kafka_audioguides_group_id: str = "ai-orchestrator-audioguides"
    # Idioma si la app no indica uno (o pide uno que no sabemos redactar).
    audioguide_default_language: str = "en"
    # Cuánto vive en caché un guion del LLM (24 horas) y uno de reglas (1 hora:
    # es el plan B y conviene reintentar pronto con el LLM). Una corrección de
    # hechos NO espera a esto: cambia la versión de la zona y con ella la clave.
    audioguide_llm_ttl_seconds: int = Field(default=24 * 3600, ge=60, le=30 * 24 * 3600)
    audioguide_rules_ttl_seconds: int = Field(default=3600, ge=60, le=7 * 24 * 3600)
    # Cuánto recuerda cada copia del servicio la versión de contenido de una
    # zona (ver audioguides/versions.py). Es el retraso máximo con el que se
    # nota una corrección de hechos, y a la vez lo que protege a PostgreSQL:
    # como mucho una consulta por zona y por este intervalo.
    audioguide_version_cache_seconds: float = Field(default=60.0, ge=1.0, le=3600.0)
    # Unas 260 palabras ≈ menos de dos minutos de audio.
    audioguide_max_words: int = Field(default=260, ge=50, le=1000)
    audioguide_max_output_tokens: int = Field(default=900, ge=128, le=4096)

    # --- Audio de las audioguías (Piper + Opus, ver audioguides/audio_worker.py) ----
    # Carpeta donde se guardan los .opus (un volumen de Docker). Si no se
    # define, la API no ofrece audio (solo el guion de texto).
    audio_dir: Path | None = None
    # Prefijo de las URLs de audio que se dan a la app. En local, la propia
    # API; en producción, la URL de la CDN delante del almacén de objetos.
    audio_public_base_url: str = "/v1/audio"
    # Cuánto recuerda la API el manifiesto de audio de una zona.
    audio_manifest_cache_seconds: float = Field(default=60.0, ge=1.0, le=3600.0)
    # Solo el worker: una carpeta por idioma con UNA voz de Piper dentro.
    tts_voices_dir: Path = Path("/voices")
    tts_piper_bin: str = "piper"
    tts_opusenc_bin: str = "opusenc"
    # 24 kbps: voz clara y ~180 KB por minuto.
    tts_bitrate_kbps: int = Field(default=24, ge=6, le=64)
    tts_timeout_seconds: float = Field(default=120.0, gt=0, le=900)
    # Cola de trabajos (outbox): préstamo de un trabajo, revisión periódica y
    # cuántos fallos seguidos se toleran antes de abandonarlo.
    audio_job_lease_seconds: int = Field(default=900, ge=60, le=6 * 3600)
    audio_poll_seconds: float = Field(default=30.0, ge=1.0, le=3600.0)
    audio_max_attempts: int = Field(default=5, ge=1, le=20)
    # Recolector de basura del audio (audioguides/audio_gc.py): cada cuánto
    # pasa, cuántas grabaciones recientes nunca se tocan (N y N-1), cuántos
    # días de cuarentena tiene una grabación sustituida antes de borrarse y
    # cuántas horas debe tener un archivo huérfano para borrarlo.
    audio_gc_interval_seconds: float = Field(default=6 * 3600.0, ge=60.0, le=7 * 24 * 3600.0)
    audio_gc_keep: int = Field(default=2, ge=1, le=20)
    audio_gc_grace_days: float = Field(default=30.0, ge=0.0, le=365.0)
    audio_gc_orphan_hours: float = Field(default=24.0, ge=1.0, le=24 * 30.0)

    # --- Negociación de grupo (ver el paquete negotiation/) ---------------------------
    negotiations_enabled: bool = True
    # Órdenes de trabajo (las publica nuestro propio outbox) y su DLQ.
    kafka_topic_negotiation_requests: str = "ai.group-negotiation-requests.v1"
    kafka_topic_negotiation_requests_dlq: str = "ai.group-negotiation-requests-dlq.v1"
    # Resultados: el notifier avisa "ya tenéis destino".
    kafka_topic_negotiation_results: str = "ai.group-negotiations.v1"
    # "Mensajes nuevos en el chat del viaje" (el notifier manda el push).
    kafka_topic_group_chat_activity: str = "ai.group-chat-activity.v1"
    # Como mucho un aviso de chat por viaje cada tantos segundos.
    group_chat_push_seconds: int = Field(default=120, ge=10, le=3600)
    # Grupo de consumidores PROPIO: una negociación larga no frena las alertas.
    kafka_negotiations_group_id: str = "ai-orchestrator-negotiations"
    # Rondas si el organizador no dice otra cosa (el techo absoluto es 10).
    negotiation_default_max_rounds: int = Field(default=3, ge=1, le=10)
    # Cuánto se espera a que todos envíen sus preferencias (72 h = 3 días).
    negotiation_collect_hours: float = Field(default=72.0, ge=0.01, le=30 * 24.0)
    # Tiempo máximo de UNA ronda y de TODA la negociación. Una ronda puede
    # necesitar varios reintentos del LLM por agente (OLLAMA_TIMEOUT_SECONDS x
    # LLM_MAX_ATTEMPTS); quien no conteste a tiempo usa su plan B por reglas.
    negotiation_round_timeout_seconds: float = Field(default=180.0, gt=0, le=1800)
    negotiation_total_timeout_seconds: float = Field(default=480.0, gt=0, le=3600)
    # La respuesta de un agente es corta: ranking, aceptables y una frase.
    negotiation_max_output_tokens: int = Field(default=300, ge=64, le=2048)
    # Las negociaciones terminadas se borran pasado este tiempo.
    negotiation_retention_days: int = Field(default=90, ge=1, le=3650)
    # Cada cuánto revisa el relé el outbox si nadie toca el timbre.
    outbox_poll_seconds: float = Field(default=2.0, ge=0.1, le=60.0)
    # Clave de los seudónimos de las notificaciones (la MISMA que el notifier
    # y el geo-engine, en hexadecimal). Opcional: sin ella, el resultado se
    # anuncia sin destinatarios. En producción, desde un gestor de secretos.
    notify_pseudonym_key: SecretStr | None = None

    # --- Fichas de ciudad (ver el paquete places/) ------------------------------------
    # Necesita Redis (la caché de fichas) y salida a internet hacia Wikimedia.
    places_enabled: bool = True
    # Wikimedia exige un User-Agent que diga quién llama y cómo contactar.
    wikimedia_user_agent: str = Field(
        default="NomadIQ/0.1 (https://github.com/dp2005dario/NoMad-IQ)", min_length=10, max_length=200
    )
    # Peticiones por segundo a Wikimedia (por copia del servicio). Cada ficha
    # nueva son 5; con la caché de 7 días casi nunca se llega al límite.
    wikimedia_rate_per_second: float = Field(default=5.0, gt=0, le=50)
    wikimedia_burst: int = Field(default=10, ge=1, le=100)
    wikimedia_timeout_seconds: float = Field(default=15.0, gt=0, le=60)
    place_ttl_seconds: int = Field(default=7 * 24 * 3600, ge=3600, le=90 * 24 * 3600)

    # --- Fotos reales de la calle (ver el paquete streetview/) ------------------------
    # La "client token" gratuita de Mapillary. Sin ella, el botón "Ver la calle
    # de verdad" simplemente no aparece (la ruta no existe). Es un secreto:
    # en producción, desde un gestor de secretos, nunca en git.
    mapillary_token: SecretStr | None = None
    mapillary_rate_per_second: float = Field(default=5.0, gt=0, le=50)
    mapillary_burst: int = Field(default=10, ge=1, le=100)
    mapillary_timeout_seconds: float = Field(default=10.0, gt=0, le=60)
    street_ttl_seconds: int = Field(default=6 * 3600, ge=600, le=48 * 3600)

    # --- Gastos compartidos (ver el paquete expenses/): solo necesita PostgreSQL ---
    expenses_enabled: bool = True

    # --- Tipos de cambio (ver el paquete fx/): del BCE, gratis y sin clave --------------
    fx_enabled: bool = True
    fx_ttl_seconds: int = Field(default=6 * 3600, ge=600, le=48 * 3600)

    # --- Cajeros cercanos (ver el paquete atms/): OpenStreetMap, gratis y sin clave ----
    atms_enabled: bool = True
    # El buscador Overpass. Se puede cambiar por otro espejo o uno propio.
    overpass_url: str = "https://overpass-api.de/api/interpreter"
    # Su norma de uso justo: muy pocas peticiones por segundo (por copia).
    overpass_rate_per_second: float = Field(default=1.0, gt=0, le=10)
    overpass_burst: int = Field(default=3, ge=1, le=20)
    overpass_timeout_seconds: float = Field(default=25.0, gt=0, le=60)
    atm_ttl_seconds: int = Field(default=24 * 3600, ge=3600, le=7 * 24 * 3600)

    # --- Cerca de ti (ver el paquete nearby/): el mismo Overpass, una semana de caché ----
    nearby_enabled: bool = True
    nearby_ttl_seconds: int = Field(default=7 * 24 * 3600, ge=24 * 3600, le=30 * 24 * 3600)

    # --- Modo coche (ver el paquete drive/): el mismo Overpass, casillas de ~5 km
    drive_enabled: bool = True
    drive_ttl_seconds: int = Field(default=7 * 24 * 3600, ge=24 * 3600, le=30 * 24 * 3600)
    # Dormir barato (estaciones + alojamientos de OpenStreetMap): un mes de caché.
    stays_enabled: bool = True
    stays_ttl_seconds: int = Field(default=30 * 24 * 3600, ge=24 * 3600, le=60 * 24 * 3600)

    # --- Guía del aeropuerto (ver el paquete airport_guide/): el mismo Overpass ------
    airport_guide_enabled: bool = True
    # Un aeropuerto casi no cambia: un mes de caché por aeropuerto.
    airport_guide_ttl_seconds: int = Field(default=30 * 24 * 3600, ge=24 * 3600, le=90 * 24 * 3600)

    # --- Cromos con amigos (ver el paquete leagues/): solo PostgreSQL
    leagues_enabled: bool = True

    # --- Quedadas con otros viajeros (ver el paquete meetups/): solo PostgreSQL
    meetups_enabled: bool = True

    # --- Copia este viaje (ver el paquete shared_trips/): PostgreSQL; adaptar necesita Ollama y Redis
    shared_trips_enabled: bool = True
    # Adaptaciones por persona y día (las que salen de la caché no cuentan).
    trip_adapt_daily_limit: int = Field(default=10, ge=1, le=200)
    trip_adapt_timeout_seconds: float = Field(default=60.0, gt=0, le=180)

    # --- Traductor de cartas (ver el paquete menu/): necesita Ollama y Redis ----------
    menu_enabled: bool = True
    # Cartas gratis por persona y día: el tope que evita sorpresas de coste.
    menu_daily_limit: int = Field(default=20, ge=1, le=200)
    menu_timeout_seconds: float = Field(default=60.0, gt=0, le=180)

    # --- Clima medio por meses (ver el paquete climate/): NASA POWER, gratis -----------
    climate_enabled: bool = True
    nasa_power_url: str = "https://power.larc.nasa.gov/api/temporal/climatology/point"
    nasa_rate_per_second: float = Field(default=1.0, gt=0, le=10)
    nasa_burst: int = Field(default=3, ge=1, le=20)
    nasa_timeout_seconds: float = Field(default=25.0, gt=0, le=60)
    climate_ttl_seconds: int = Field(default=30 * 24 * 3600, ge=24 * 3600, le=90 * 24 * 3600)

    # --- Radar local (ver el paquete radar/): lluvia de MET Norway + avisos ---------
    radar_enabled: bool = True
    met_url: str = "https://api.met.no/weatherapi/locationforecast/2.0/compact"
    met_rate_per_second: float = Field(default=5.0, gt=0, le=20)
    rain_ttl_seconds: int = Field(default=15 * 60, ge=5 * 60, le=3 * 3600)

    # --- Qué pasa en tus fechas (ver el paquete city_events/) --------------------------
    # Festivos de Nager.Date (gratis, sin clave) y, si hay clave, eventos de
    # Ticketmaster (clave gratis con cupo diario). La clave es un secreto:
    # en producción, desde un gestor de secretos, nunca en git.
    events_enabled: bool = True
    nager_url: str = "https://date.nager.at/api/v3/PublicHolidays"
    ticketmaster_api_key: SecretStr | None = None
    ticketmaster_url: str = "https://app.ticketmaster.com/discovery/v2/events.json"
    ticketmaster_daily_limit: int = Field(default=4000, ge=1, le=5000)
    events_rate_per_second: float = Field(default=2.0, gt=0, le=5)
    events_timeout_seconds: float = Field(default=10.0, gt=0, le=60)

    # --- Chat libre con Flyra (ver el paquete flyra/) --------------------------------
    # Necesita Ollama (LLM_ENABLED) y Redis (el contador de preguntas diarias).
    flyra_enabled: bool = True
    # Preguntas gratis por persona y día: el tope que evita sorpresas de coste.
    flyra_daily_limit: int = Field(default=50, ge=1, le=1000)
    # Si el modelo tarda más que esto, "Flyra está ocupada" y no cuenta.
    flyra_timeout_seconds: float = Field(default=45.0, gt=0, le=300)

    # --- Modo cámara: reconocer monumentos (ver el paquete landmarks/) --------------
    # Necesita Redis (caché y cupo) y salida a Wikimedia, como las fichas.
    landmarks_enabled: bool = True
    # Usos gratis del modo cámara por persona y día.
    landmark_daily_limit: int = Field(default=100, ge=1, le=2000)
    # Modelo de Ollama "con ojos" que mira la foto (p. ej. "qwen2.5vl:3b",
    # hay que descargarlo con "ollama pull"). Vacío = sin visión: se decide
    # solo por GPS y brújula y la app pregunta "¿Es este?".
    landmark_vision_model: str | None = Field(default=None, max_length=100)
    landmark_vision_timeout_seconds: float = Field(default=25.0, gt=0, le=120)

    # --- Redis (caché de audioguías y fichas de ciudad) -----------------------------------------------
    redis_host: str | None = None
    redis_port: int = Field(default=6379, ge=1, le=65535)
    redis_password: SecretStr | None = None
    redis_tls: bool = True
    redis_tls_ca_file: Path | None = None
    redis_insecure_dev: bool = False

    # --- PostgreSQL ------------------------------------------------------------
    # Mismos nombres que usa psql, para no inventar otros.
    pghost: str = Field(min_length=1)
    pgport: int = Field(default=5432, ge=1, le=65535)
    pguser: str = Field(min_length=1)
    pgpassword: SecretStr
    pgdatabase: str = Field(min_length=1)
    pgsslmode: str = "verify-full"
    pgsslrootcert: Path | None = None
    pg_max_conns: int = Field(default=10, ge=1, le=100)
    db_insecure_dev: bool = False

    # --- Ollama (modelo de lenguaje local) --------------------------------------
    ollama_url: str = "http://localhost:11434"
    ollama_model: str = "llama3.1:8b"
    # Modelo que convierte texto en vectores (para buscar en Qdrant).
    ollama_embed_model: str = "nomic-embed-text"
    # Tiempo máximo que esperamos UNA respuesta del modelo. Si se pasa, la
    # alerta recibe la recomendación por reglas (no se queda colgada).
    ollama_timeout_seconds: float = Field(default=60.0, gt=0, le=600)
    # Peticiones simultáneas máximas a Ollama. Un servidor local con una GPU
    # atiende pocas a la vez; el resto espera turno en vez de saturarlo.
    ollama_max_concurrency: int = Field(default=2, ge=1, le=64)
    # Tamaño de la ventana de contexto que pedimos al modelo (en tokens).
    ollama_num_ctx: int = Field(default=4096, ge=512, le=131072)
    ollama_tls_ca_file: Path | None = None
    ollama_tls_cert_file: Path | None = None
    ollama_tls_key_file: Path | None = None
    # Ollama no trae TLS de serie: en producción va detrás de un proxy con mTLS.
    ollama_insecure_dev: bool = False
    # Interruptor general: sin LLM todas las recomendaciones salen de reglas.
    llm_enabled: bool = True

    # --- Comportamiento del LLM -------------------------------------------------
    # Temperatura baja = respuestas más predecibles y fieles al formato JSON.
    llm_temperature: float = Field(default=0.1, ge=0.0, le=1.0)
    # Intentos para obtener un JSON válido antes de rendirse (y usar reglas).
    llm_max_attempts: int = Field(default=3, ge=1, le=5)
    # Tokens máximos de la respuesta: una recomendación es corta.
    llm_max_output_tokens: int = Field(default=400, ge=64, le=4096)

    # --- Recuperación de datos (RAG) --------------------------------------------
    price_history_window_days: int = Field(default=30, ge=1, le=365)
    qdrant_url: str | None = None
    qdrant_api_key: SecretStr | None = None
    qdrant_collection: str = "travel_knowledge"
    qdrant_tls_ca_file: Path | None = None
    qdrant_insecure_dev: bool = False
    knowledge_max_snippets: int = Field(default=3, ge=0, le=10)

    # --- Registros (logs) ---------------------------------------------------------
    log_level: Literal["debug", "info", "warning", "error"] = "info"

    @field_validator("notify_pseudonym_key", "mapillary_token", "ticketmaster_api_key", mode="before")
    @classmethod
    def _empty_is_none(cls, value: object) -> object:
        # docker compose pasa "NOTIFY_PSEUDONYM_KEY=" o "MAPILLARY_TOKEN="
        # (vacías) si no están en el .env: para nosotros eso es "no
        # configurada", no una clave inválida.
        return None if value == "" else value

    # ------------------------------------------------------------------------------
    # Validaciones que relacionan varios campos (no se pueden expresar en uno solo).
    # ------------------------------------------------------------------------------

    @model_validator(mode="after")
    def _check_security(self) -> Self:
        problems: list[str] = []

        tls_files = [self.tls_cert_file, self.tls_key_file, self.tls_client_ca_file]
        if any(tls_files) and not all(tls_files):
            problems.append("TLS_CERT_FILE, TLS_KEY_FILE y TLS_CLIENT_CA_FILE van juntas: falta alguna")
        if not all(tls_files) and not self.http_insecure_dev:
            problems.append(
                "la API exige mTLS: define TLS_CERT_FILE, TLS_KEY_FILE y TLS_CLIENT_CA_FILE "
                "o, solo en local, HTTP_INSECURE_DEV=true"
            )
        if all(tls_files) and self.http_insecure_dev:
            problems.append("HTTP_INSECURE_DEV=true contradice los certificados TLS: quita una de las dos")

        if self.pgsslmode not in SECURE_PG_SSLMODES and not self.db_insecure_dev:
            problems.append(
                f"PGSSLMODE={self.pgsslmode} no verifica al servidor: usa verify-full "
                "o, solo en local, DB_INSECURE_DEV=true"
            )
        if self.pgsslmode in SECURE_PG_SSLMODES and self.db_insecure_dev:
            problems.append("DB_INSECURE_DEV=true contradice PGSSLMODE=verify-full: quita una de las dos")

        problems += _check_url("OLLAMA_URL", self.ollama_url, insecure_ok=self.ollama_insecure_dev)
        if bool(self.ollama_tls_cert_file) != bool(self.ollama_tls_key_file):
            problems.append("OLLAMA_TLS_CERT_FILE y OLLAMA_TLS_KEY_FILE van juntas")

        if self.qdrant_url is not None:
            problems += _check_url("QDRANT_URL", self.qdrant_url, insecure_ok=self.qdrant_insecure_dev)
            if self.qdrant_api_key is None:
                problems.append("QDRANT_URL necesita QDRANT_API_KEY (Qdrant nunca va sin autenticación)")

        if self.audioguides_enabled:
            if not self.redis_host or self.redis_password is None:
                problems.append(
                    "las audioguías necesitan Redis: define REDIS_HOST y REDIS_PASSWORD "
                    "(o AUDIOGUIDES_ENABLED=false)"
                )
            if not self.redis_tls and not self.redis_insecure_dev:
                problems.append("REDIS_TLS=false solo se permite con REDIS_INSECURE_DEV=true (solo en local)")
            if self.audioguide_default_language not in SUPPORTED_LANGUAGES:
                problems.append(
                    f"AUDIOGUIDE_DEFAULT_LANGUAGE debe ser uno de: {', '.join(SUPPORTED_LANGUAGES)}"
                )

        if self.places_enabled and (not self.redis_host or self.redis_password is None):
            problems.append(
                "las fichas de ciudad necesitan Redis: define REDIS_HOST y REDIS_PASSWORD "
                "(o PLACES_ENABLED=false)"
            )
        if self.mapillary_token is not None and (not self.redis_host or self.redis_password is None):
            problems.append(
                "las fotos de calle necesitan Redis: define REDIS_HOST y REDIS_PASSWORD "
                "(o quita MAPILLARY_TOKEN)"
            )
        if self.landmarks_enabled and (not self.redis_host or self.redis_password is None):
            problems.append(
                "el modo cámara necesita Redis: define REDIS_HOST y REDIS_PASSWORD "
                "(o LANDMARKS_ENABLED=false)"
            )
        if self.flyra_enabled and self.llm_enabled and (not self.redis_host or self.redis_password is None):
            problems.append(
                "el chat con Flyra necesita Redis: define REDIS_HOST y REDIS_PASSWORD (o FLYRA_ENABLED=false)"
            )
        if self.mapillary_token is not None and not re.fullmatch(
            r"MLY\|[0-9]+\|[0-9a-f]+", self.mapillary_token.get_secret_value()
        ):
            # No repetimos el valor en el mensaje: es un secreto.
            problems.append("MAPILLARY_TOKEN no tiene forma de token de Mapillary (MLY|...)")
        if (
            (
                self.places_enabled
                or self.landmarks_enabled
                or self.mapillary_token is not None
                or self.flyra_enabled
            )
            and not self.audioguides_enabled
            and not self.redis_tls
            and not self.redis_insecure_dev
        ):
            problems.append("REDIS_TLS=false solo se permite con REDIS_INSECURE_DEV=true (solo en local)")

        if not (
            self.audio_public_base_url.startswith("https://")
            or re.fullmatch(r"/[A-Za-z0-9/_-]*", self.audio_public_base_url)
        ):
            problems.append("AUDIO_PUBLIC_BASE_URL debe ser https://... o una ruta que empiece por /")

        if self.negotiation_round_timeout_seconds > self.negotiation_total_timeout_seconds:
            problems.append(
                "NEGOTIATION_ROUND_TIMEOUT_SECONDS no puede ser mayor que NEGOTIATION_TOTAL_TIMEOUT_SECONDS"
            )
        if self.notify_pseudonym_key is not None:
            try:
                Pseudonymizer.from_hex(self.notify_pseudonym_key.get_secret_value())
            except ValueError as exc:
                # El mensaje nunca incluye la clave, solo qué le pasa.
                problems.append(f"NOTIFY_PSEUDONYM_KEY: {exc}")

        if self.http_port == self.management_port:
            problems.append("HTTP_PORT y MANAGEMENT_PORT deben ser distintos")
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,255}", self.qdrant_collection):
            problems.append("QDRANT_COLLECTION solo admite letras, números, '.', '_' y '-'")

        if problems:
            # Todos los problemas a la vez: arreglas el .env de una sola pasada.
            raise ValueError("configuración inválida:\n  - " + "\n  - ".join(problems))
        return self

    @property
    def audioguide_lock_ttl_seconds(self) -> int:
        """Lo máximo que puede tardar una generación (todos los intentos) + margen."""
        return int(self.ollama_timeout_seconds * self.llm_max_attempts) + 30

    @property
    def negotiation_lease_seconds(self) -> int:
        """Cuánto "reserva" una copia del servicio una negociación en marcha:
        lo máximo que puede durar + margen. Si muere, otra la retoma después."""
        return int(self.negotiation_total_timeout_seconds) + 120

    @property
    def kafka_broker_list(self) -> list[str]:
        """KAFKA_BROKERS admite varios separados por comas: "k1:9092,k2:9092"."""
        return [b.strip() for b in self.kafka_brokers.split(",") if b.strip()]


def _check_url(name: str, url: str, *, insecure_ok: bool) -> list[str]:
    """Exige https salvo que se haya pedido explícitamente el modo inseguro local."""
    if url.startswith("https://"):
        return []
    if url.startswith("http://"):
        if insecure_ok:
            return []
        flag = name.removesuffix("_URL") + "_INSECURE_DEV"
        return [f"{name} usa http sin cifrar: usa https o, solo en local, {flag}=true"]
    return [f"{name} debe empezar por https:// (o http:// en local)"]
