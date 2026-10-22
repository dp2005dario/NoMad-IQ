"""Registros (logs) en formato JSON, una línea por evento.

¿Por qué JSON y no texto normal?
    Con millones de líneas, nadie las lee a mano: las lee una herramienta
    (Loki, Elasticsearch...). En JSON cada dato va en su campo
    ("alert_id": "...") y se puede filtrar: "enséñame todo lo de esta alerta".

Privacidad: nunca registramos el texto de los prompts ni las respuestas del
modelo, ni contraseñas. Solo identificadores y motivos de error.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

# Atributos que trae todo LogRecord de Python; el resto son nuestros "extra".
# color_message lo añade uvicorn (texto con colores para terminal): no lo queremos.
_STANDARD = set(logging.makeLogRecord({}).__dict__) | {"message", "asctime", "taskName", "color_message"}


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry: dict[str, Any] = {
            "time": datetime.fromtimestamp(record.created, UTC).isoformat(),
            "level": record.levelname.lower(),
            "logger": record.name,
            "msg": record.getMessage(),
        }
        for key, value in record.__dict__.items():
            if key not in _STANDARD and not key.startswith("_"):
                entry[key] = value
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False, default=str)


def setup_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())
    # aiokafka y httpx son muy habladores en "info": solo avisos y errores.
    for noisy in ("aiokafka", "httpx", "httpcore"):
        logging.getLogger(noisy).setLevel(max(logging.WARNING, root.level))
