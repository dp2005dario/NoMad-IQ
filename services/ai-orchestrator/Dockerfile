# syntax=docker/dockerfile:1
# Construcción en dos etapas:
#   1. "build": instala las librerías con uv en un entorno virtual (.venv).
#   2. Imagen final: solo Python + ese .venv. Sin uv, sin compiladores, sin
#      herramientas de desarrollo, y ejecutándose sin root.
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

FROM python:3.13-slim
# Usuario sin privilegios con un UID fijo (10001): si alguien rompiera el
# programa, no tendría permisos de administrador dentro del contenedor.
RUN useradd --uid 10001 --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /app/.venv /app/.venv
# PYTHONDONTWRITEBYTECODE: no intenta escribir .pyc (el disco es de solo lectura).
# PYTHONUNBUFFERED: los logs salen al instante, sin quedarse en un búfer.
ENV PATH="/app/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER 10001:10001
EXPOSE 8085 8086
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 CMD ["ai-orchestrator", "--healthcheck"]
ENTRYPOINT ["ai-orchestrator"]
