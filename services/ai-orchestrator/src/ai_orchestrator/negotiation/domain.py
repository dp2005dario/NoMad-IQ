"""Vocabulario de la negociación de grupo: opciones, preferencias y posturas.

Todos son modelos de Pydantic con ``frozen=True`` (inmutables) y
``extra="forbid"`` (si llega un campo que no conocemos, error): lo que pasa
de aquí hacia dentro ya está revisado.

Reglas importantes que viven en los propios tipos:
    - Los importes son enteros en céntimos (``price_minor``), como en el resto
      de la plataforma: nunca float para dinero.
    - Las etiquetas ("playa", "museos") tienen un formato muy cerrado
      (minúsculas, números y guiones). Además de ordenar los datos, cierra la
      puerta a que alguien cuele instrucciones para el LLM dentro de una
      etiqueta ("ignora tus órdenes y...").
    - Las notas libres de cada viajero están acotadas en longitud y se limpian
      de caracteres de control. Aun así, el LLM las trata como DATOS, nunca
      como órdenes (ver agents.py).
"""

from __future__ import annotations

import re
import unicodedata
from enum import StrEnum
from typing import Annotated, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field

# Límites del producto. Pocos y explícitos: una negociación de 8 personas con
# 10 opciones ya es mucho trabajo para un LLM local, y estos números acotan
# cuántas llamadas al modelo puede provocar UNA petición (rondas x miembros).
MIN_MEMBERS = 2
MAX_MEMBERS = 8
MIN_OPTIONS = 2
MAX_OPTIONS = 10
MAX_TAGS = 10
MAX_NOTES_CHARS = 280

# Identificador de opción: lo elige quien crea la negociación ("lisboa", "op-2").
OptionId = Annotated[str, Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")]

_TAG = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")


def _normalize_tags(values: tuple[str, ...]) -> tuple[str, ...]:
    """Minúsculas, sin repetir y con un formato muy cerrado."""
    out: list[str] = []
    for raw in values:
        tag = raw.strip().lower()
        if not _TAG.fullmatch(tag):
            raise ValueError(f"etiqueta inválida {raw!r}: usa minúsculas, números y guiones (máx. 32)")
        if tag not in out:
            out.append(tag)
    return tuple(out)


Tags = Annotated[tuple[str, ...], Field(max_length=MAX_TAGS), AfterValidator(_normalize_tags)]


def _clean_notes(value: str) -> str:
    # Fuera caracteres de control (saltos de línea raros, "borrar", códigos de
    # terminal...): en un prompt pueden servir para disfrazar instrucciones.
    # Los espacios seguidos se juntan en uno.
    kept = "".join(" " if unicodedata.category(c).startswith("C") else c for c in value)
    return " ".join(kept.split())


Notes = Annotated[str, Field(max_length=MAX_NOTES_CHARS), AfterValidator(_clean_notes)]


class GroupOption(BaseModel):
    """Una opción de viaje sobre la que se negocia (precio por persona, real)."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    option_id: OptionId
    label: str = Field(min_length=1, max_length=120)
    # Precio por persona en céntimos de la divisa de la negociación.
    price_minor: int = Field(gt=0, le=100_000_000)
    # Qué ofrece la opción: "playa", "museos", "fiesta", "montaña"...
    tags: Tags = ()


class MemberPreferences(BaseModel):
    """Lo que cada persona cuenta de sí misma. Es PRIVADO: ni los demás
    miembros ni los agentes de los demás lo ven nunca."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    # Presupuesto máximo por persona, en céntimos de la divisa de la negociación.
    # Es una restricción DURA: ninguna IA puede saltársela.
    budget_max_minor: int = Field(gt=0, le=100_000_000)
    # Lo que le gusta y lo que quiere evitar (mismo vocabulario que las etiquetas).
    interests: Tags = ()
    avoid: Tags = ()
    # Una frase libre ("viajo con mi perro", "odio madrugar").
    notes: Notes = ""


class Member(BaseModel):
    """Un miembro tal y como lo ve el motor: un alias, nunca su user_id.

    El alias ("Viajero 2") es lo único que llega al LLM y a los demás
    miembros. Así el modelo no recibe datos personales.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    alias: str = Field(pattern=r"^[A-Za-z0-9 ]{1,32}$")
    preferences: MemberPreferences


class AgentPosition(BaseModel):
    """La postura de un agente en una ronda.

    - ranking: opciones de mejor a peor (todas las que se negocian).
    - acceptable: las que su viajero aceptaría. Aquí está la clave de la
      negociación: si hay una opción que TODOS aceptan, hay acuerdo.
    - argument: una frase para las personas ("prefiere playa y es la más
      barata"). Nunca se le enseña a los OTROS agentes (ver engine.py).
    - source: "llm" si la decidió el modelo, "rules" si salió del plan B.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    agent_id: str
    ranking: tuple[str, ...]
    acceptable: frozenset[str]
    argument: str = Field(default="", max_length=300)
    source: Literal["llm", "rules"] = "rules"


class Outcome(StrEnum):
    """Cómo terminó una negociación (mismo vocabulario que el proto)."""

    CONSENSUS = "consensus"
    ARBITRATION = "arbitration"
    NO_FEASIBLE_OPTION = "no_feasible_option"


class Status(StrEnum):
    """Ciclo de vida de una negociación guardada en PostgreSQL.

    collecting -> queued -> running -> concluded
         \\-> expired (venció el plazo con menos de dos miembros listos)
    """

    COLLECTING = "collecting"
    QUEUED = "queued"
    RUNNING = "running"
    CONCLUDED = "concluded"
    EXPIRED = "expired"


class MemberResult(BaseModel):
    """La postura final de un miembro y cómo de contento queda."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    alias: str
    ranking: tuple[str, ...]
    acceptable: tuple[str, ...]
    argument: str
    source: Literal["llm", "rules"]
    # Puesto de la opción elegida en SU ranking (1 = su favorita). None si no hubo elección.
    chosen_rank: int | None


class NegotiationResult(BaseModel):
    """El resultado completo, tal y como se guarda y se enseña."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    outcome: Outcome
    chosen_option_id: str | None
    rounds: int = Field(ge=0)
    # Explicación en lenguaje llano, escrita por código (no por el LLM).
    explanation: str
    # Opciones que no se pudieron negociar porque superan el presupuesto de
    # alguien. NO se dice de quién: el presupuesto de cada uno es privado.
    excluded_over_budget: tuple[str, ...]
    members: tuple[MemberResult, ...]
    llm_used: bool
