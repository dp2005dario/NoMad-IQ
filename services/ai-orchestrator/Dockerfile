# syntax=docker/dockerfile:1
# Construcción en varias etapas:
#   1. "build": instala las librerías con uv en un entorno virtual (.venv).
#   2. "piper-build": instala Piper (motor de voz) en otro entorno aparte.
#   3. "audio-worker": imagen del worker que graba las audioguías.
#   4. Imagen final (la API): solo Python + el .venv. Sin uv, sin compiladores,
#      sin herramientas de desarrollo, y ejecutándose sin root.
#
# Se construye desde la raíz del repositorio (como los demás servicios):
#   docker build -f services/ai-orchestrator/Dockerfile .

FROM python:3.13-slim AS build
# uv en una versión fija: la misma construcción da siempre el mismo resultado.
COPY --from=ghcr.io/astral-sh/uv:0.11.32 /uv /usr/local/bin/uv
# UV_COMPILE_BYTECODE: precompila los .py (arranque más rápido).
# UV_LINK_MODE=copy: copia ficheros en vez de enlazarlos (necesario entre capas).
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app

# Primero solo las dependencias: Docker cachea esta capa y no la repite
# mientras pyproject.toml y uv.lock no cambien.
COPY services/ai-orchestrator/pyproject.toml services/ai-orchestrator/uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# Después el código. --no-editable lo instala como paquete normal dentro de .venv.
COPY services/ai-orchestrator/README.md ./
COPY services/ai-orchestrator/src ./src
RUN uv sync --frozen --no-dev --no-editable

# --- Piper (el motor de voz), en un entorno APARTE ------------------------------
# Piper es GPL-3.0: lo instalamos en /opt/piper, separado de nuestro código, y
# el worker lo usa como un programa externo (texto por la entrada, sonido por
# la salida). --require-hashes: cada paquete se comprueba con su huella SHA-256,
# así nadie puede colarnos un paquete manipulado (cadena de suministro).
FROM python:3.13-slim AS piper-build
COPY --from=ghcr.io/astral-sh/uv:0.11.32 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
COPY services/ai-orchestrator/tts/requirements.txt /tmp/tts-requirements.txt
RUN uv venv /opt/piper && uv pip install --python /opt/piper/bin/python --require-hashes -r /tmp/tts-requirements.txt

# --- Imagen del worker de audio (docker compose: target "audio-worker") ----------
# La misma aplicación + Piper + opusenc (el compresor Opus, unos cientos de KB).
FROM python:3.13-slim AS audio-worker
RUN apt-get update \
    && apt-get install -y --no-install-recommends opus-tools \
    && rm -rf /var/lib/apt/lists/*
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app \
    && install -d -o 10001 -g 10001 /var/lib/nomadiq/audio
COPY --from=build /app/.venv /app/.venv
COPY --from=piper-build /opt/piper /opt/piper
ENV PATH="/app/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    TTS_PIPER_BIN=/opt/piper/bin/piper TTS_OPUSENC_BIN=/usr/bin/opusenc \
    AUDIO_DIR=/var/lib/nomadiq/audio TTS_VOICES_DIR=/voices
USER 10001:10001
EXPOSE 8086
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 CMD ["ai-orchestrator", "--healthcheck"]
ENTRYPOINT ["ai-orchestrator", "--audio-worker"]

# --- Imagen de la API (la de siempre; al ser la última, es la que se construye por defecto)
FROM python:3.13-slim
# Usuario sin privilegios con un UID fijo (10001): si alguien rompiera el
# programa, no tendría permisos de administrador dentro del contenedor.
# La carpeta del audio (volumen compartido con el worker) es suya; la API
# solo la lee.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app \
    && install -d -o 10001 -g 10001 /var/lib/nomadiq/audio
COPY --from=build /app/.venv /app/.venv
# PYTHONDONTWRITEBYTECODE: no intenta escribir .pyc (el disco es de solo lectura).
# PYTHONUNBUFFERED: los logs salen al instante, sin quedarse en un búfer.
ENV PATH="/app/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10001:10001
EXPOSE 8085 8086
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 CMD ["ai-orchestrator", "--healthcheck"]
ENTRYPOINT ["ai-orchestrator"]
