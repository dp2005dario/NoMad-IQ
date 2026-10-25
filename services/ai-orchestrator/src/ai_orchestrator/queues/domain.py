"""Sin colas: lo que se guarda y lo que se enseña.

REGLA: nada inventado. Las esperas las avisan viajeros que están en el sitio,
y solo se enseñan cuando lo han dicho varias personas distintas.
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict

# Cuántas personas distintas hacen falta para enseñar algo.
MIN_NOW_REPORTERS = 2
MIN_HOUR_REPORTERS = 3
# "Ahora" = avisos de los últimos 90 minutos.
NOW_MINUTES = 90
# "Por horas" = avisos de los últimos 60 días.
HOURS_DAYS = 60
# Para no llenar la base: avisos que una persona puede mandar al día.
MAX_REPORTS_PER_DAY = 20
# Los niveles de espera: 0 sin cola, 1 <15 min, 2 15-30, 3 30-60, 4 >60.
MAX_WAIT = 4


class WaitNow(BaseModel):
    model_config = ConfigDict(frozen=True)

    # La mediana de lo avisado (0-4) y cuántas personas lo dijeron.
    wait: int
    reporters: int
    # Hace cuántos minutos llegó el último aviso.
    minutes_ago: int


class WaitHour(BaseModel):
    model_config = ConfigDict(frozen=True)

    hour: int
    wait: int
    reporters: int


class PlaceQueue(BaseModel):
    model_config = ConfigDict(frozen=True)

    place: str
    now: WaitNow | None
    hours: list[WaitHour]
    # ¿Ya avisaste tú esta misma hora? (para no pedírtelo otra vez).
    reported_this_hour: bool


class QueueLimitError(Exception):
    """Demasiados avisos hoy."""
