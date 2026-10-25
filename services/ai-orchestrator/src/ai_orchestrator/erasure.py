""" "Borrar mis datos": lo que este servicio sabe de una persona, fuera.

Lo llama la app justo antes de borrar la cuenta en el auth-gateway (Google
Play y el RGPD exigen que se pueda borrar TODO desde la app).

Qué pasa con cada cosa:

- **Recomendaciones de vuelos**: son solo tuyas → se borran.
- **Botes de gastos**: si estabas solo, el bote entero se borra. Si hay más
  gente, el bote es también de ellos (sus cuentas no pueden descuadrarse de
  repente), así que tu asiento se queda pero **anónimo**: sin tu cuenta y
  con el nombre "—". Es como tachar tu nombre de la libreta del piso.
- **Viajes compartidos** ("Copia este viaje"): los tuyos se dejan de
  compartir (se borran), y se olvida qué viajes copiaste tú.
- **Ligas de cromos**: sales de todas (tus cromos, tu ciudad y tus cambios
  se borran; si eras la última persona, la liga entera).
- **Quedadas**: las que propusiste se cancelan; de las demás sales, y
  tus denuncias se olvidan (el contador de la quedada no baja: la
  denuncia ya se hizo).
- **Negociaciones de grupo**: igual. Tu asiento queda anónimo y tus
  preferencias privadas (presupuesto, gustos) se borran. Tus votos de
  "Elegid planes" van por asiento, así que también quedan anónimos, y tu
  asiento deja de contar para los "match".

El "anónimo" es `erased:` + 32 letras al azar: no se puede volver a unir a
nadie (el auth-gateway solo emite UUID) y es distinto en cada borrado.
"""

from __future__ import annotations

import logging
import secrets
from dataclasses import dataclass
from typing import Protocol

import asyncpg

from ai_orchestrator.store import Pool, StoreError

log = logging.getLogger(__name__)

# Lo que se enseña a los demás en vez de tu nombre.
ERASED_NAME = "—"
# Así empiezan los ids anónimos (los planes del grupo no cuentan esos asientos).
ERASED_PREFIX = "erased:"


def anonymous_id() -> str:
    """Un id nuevo que no es de nadie (cabe en los 128 caracteres de user_id)."""
    return ERASED_PREFIX + secrets.token_hex(16)


@dataclass(frozen=True, slots=True)
class ErasureReport:
    """Cuántas cosas se tocaron (para el log; nunca qué ni de quién)."""

    recommendations: int
    groups_deleted: int
    seats_anonymized: int
    negotiation_seats_anonymized: int
    shared_trips_deleted: int = 0
    leagues_left: int = 0
    meetups_cancelled: int = 0


class UserDataEraser(Protocol):
    async def erase(self, user_id: str) -> ErasureReport: ...


class PostgresEraser:
    def __init__(self, pool: Pool) -> None:
        self._pool = pool

    async def erase(self, user_id: str) -> ErasureReport:
        anon = anonymous_id()
        try:
            async with self._pool.acquire() as conn, conn.transaction():
                # Todo en UNA transacción: o se borra todo o nada (si se corta
                # a medias, la app lo reintenta y empieza limpio).
                recs = await conn.execute("DELETE FROM ai.fare_recommendations WHERE user_id = $1", user_id)
                # Botes donde solo estabas tú: fuera enteros (gastos, pagos...
                # se van solos por ON DELETE CASCADE).
                groups = await conn.execute(
                    """
                    DELETE FROM ai.expense_groups g
                     WHERE EXISTS (SELECT 1 FROM ai.expense_members m
                                    WHERE m.group_id = g.group_id AND m.user_id = $1)
                       AND NOT EXISTS (SELECT 1 FROM ai.expense_members m
                                        WHERE m.group_id = g.group_id AND m.user_id <> $1)
                    """,
                    user_id,
                )
                seats = await conn.execute(
                    "UPDATE ai.expense_members SET user_id = $2, display_name = $3 WHERE user_id = $1",
                    user_id,
                    anon,
                    ERASED_NAME,
                )
                shared = await conn.execute("DELETE FROM ai.shared_trips WHERE owner_id = $1", user_id)
                await conn.execute("DELETE FROM ai.shared_trip_copies WHERE user_id = $1", user_id)
                await conn.execute(
                    "DELETE FROM ai.league_swaps s USING ai.league_members m"
                    " WHERE m.user_id = $1 AND s.league_id = m.league_id"
                    " AND (s.from_seat = m.seat OR s.to_seat = m.seat)",
                    user_id,
                )
                left = await conn.execute("DELETE FROM ai.league_members WHERE user_id = $1", user_id)
                await conn.execute(
                    "DELETE FROM ai.leagues l WHERE NOT EXISTS"
                    " (SELECT 1 FROM ai.league_members m WHERE m.league_id = l.league_id)"
                )
                meetups = await conn.execute("DELETE FROM ai.meetups WHERE creator_id = $1", user_id)
                await conn.execute("DELETE FROM ai.meetup_members WHERE user_id = $1", user_id)
                await conn.execute("DELETE FROM ai.meetup_reports WHERE user_id = $1", user_id)
                negotiation_seats = await conn.execute(
                    "UPDATE ai.group_negotiation_members SET user_id = $2, preferences = NULL"
                    " WHERE user_id = $1",
                    user_id,
                    anon,
                )
                await conn.execute(
                    "UPDATE ai.group_negotiations SET organizer_id = $2 WHERE organizer_id = $1",
                    user_id,
                    anon,
                )
        except (asyncpg.PostgresError, OSError, TimeoutError) as exc:
            raise StoreError(str(exc)) from exc
        report = ErasureReport(
            recommendations=_count(recs),
            groups_deleted=_count(groups),
            seats_anonymized=_count(seats),
            negotiation_seats_anonymized=_count(negotiation_seats),
            shared_trips_deleted=_count(shared),
            leagues_left=_count(left),
            meetups_cancelled=_count(meetups),
        )
        # Solo números: ni el user_id ni el id anónimo (unirlos en un log
        # desharía el anonimato).
        log.info(
            "datos de una persona borrados",
            extra={
                "recommendations": report.recommendations,
                "groups_deleted": report.groups_deleted,
                "seats_anonymized": report.seats_anonymized,
                "negotiation_seats_anonymized": report.negotiation_seats_anonymized,
                "shared_trips_deleted": report.shared_trips_deleted,
                "leagues_left": report.leagues_left,
                "meetups_cancelled": report.meetups_cancelled,
            },
        )
        return report


def _count(status: str) -> int:
    """asyncpg devuelve "DELETE 3" / "UPDATE 2": nos quedamos con el número."""
    try:
        return int(status.rsplit(" ", 1)[-1])
    except ValueError:
        return 0
