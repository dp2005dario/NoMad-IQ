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

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

from ai_orchestrator.audioguides.domain import SUPPORTED_LANGUAGES

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

    # --- Redis (caché de audioguías) -----------------------------------------------
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
