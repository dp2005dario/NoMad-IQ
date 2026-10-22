"""Esqueleto de la negociación multi-agente para viajes en grupo.

Idea del producto: cada persona del grupo tiene un "agente" (normalmente un
LLM con sus preferencias) que ordena las opciones de viaje de mejor a peor.
Los agentes van revisando sus posturas viendo las de los demás hasta ponerse
de acuerdo.

El problema (riesgo nº 5 de la revisión):
    Dos agentes pueden quedarse eternamente en "contraoferta, contra-
    contraoferta...", gastando GPU sin fin y dejando al usuario esperando.

Las reglas de parada que impone este motor (no dependen de los agentes):
    1. Número MÁXIMO de rondas (max_rounds), fijado por nosotros.
    2. Tiempo máximo por ronda: el agente que no contesta a tiempo se queda
       con su postura anterior (o se abstiene). Nadie bloquea a los demás.
    3. Si tras la última ronda no hay consenso, decide un ÁRBITRO
       DETERMINISTA: una fórmula fija (recuento Borda) que con las mismas
       posturas da siempre el mismo resultado. Sin IA, sin azar.
    4. Cada ronda los agentes solo ven la postura MÁS RECIENTE de los demás,
       no todo el historial: el contexto no crece con las rondas (riesgo nº 4).

Este fichero es la base. Los agentes con LLM se conectarán en el siguiente
paso; hoy los tests usan agentes "de guion" para comprobar las reglas.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from typing import Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.domain import CurrencyCode

log = logging.getLogger(__name__)

# Techo absoluto, aunque alguien configure más: la negociación es acotada sí o sí.
HARD_MAX_ROUNDS = 10


class GroupOption(BaseModel):
    """Una opción de viaje sobre la que se negocia (precio REAL, ya recuperado)."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    option_id: str = Field(pattern=r"^[A-Za-z0-9_-]{1,64}$")
    label: str = Field(min_length=1, max_length=200)
    price_minor: int = Field(ge=0)
    currency: CurrencyCode


class AgentPosition(BaseModel):
    """La postura de un agente: opciones ordenadas de mejor a peor."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    agent_id: str
    ranking: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class NegotiationState:
    """Lo que ve cada agente al empezar una ronda."""

    round: int
    max_rounds: int
    options: tuple[GroupOption, ...]
    # Solo la última postura de cada agente (contexto acotado).
    latest: Mapping[str, AgentPosition]


class NegotiationAgent(Protocol):
    @property
    def agent_id(self) -> str: ...

    async def respond(self, state: NegotiationState) -> AgentPosition: ...


@dataclass(frozen=True, slots=True)
class NegotiationResult:
    option_id: str
    outcome: Literal["consensus", "arbitration"]
    rounds: int
    positions: Mapping[str, AgentPosition]


class NegotiationEngine:
    def __init__(self, *, max_rounds: int = 3, round_timeout_seconds: float = 30.0) -> None:
        if not 1 <= max_rounds <= HARD_MAX_ROUNDS:
            raise ValueError(f"max_rounds debe estar entre 1 y {HARD_MAX_ROUNDS}")
        if round_timeout_seconds <= 0:
            raise ValueError("round_timeout_seconds debe ser > 0")
        self._max_rounds = max_rounds
        self._round_timeout = round_timeout_seconds

    async def run(
        self, options: Sequence[GroupOption], agents: Sequence[NegotiationAgent]
    ) -> NegotiationResult:
        if not options:
            raise ValueError("no hay opciones que negociar")
        if not agents:
            raise ValueError("no hay agentes")
        ids = [o.option_id for o in options]
        if len(set(ids)) != len(ids):
            raise ValueError("option_id repetido")
        if len({o.currency for o in options}) != 1:
            # El desempate compara precios: solo tiene sentido en la misma divisa.
            raise ValueError("todas las opciones deben ir en la misma divisa")
        agent_ids = [a.agent_id for a in agents]
        if len(set(agent_ids)) != len(agent_ids):
            raise ValueError("agent_id repetido")

        latest: dict[str, AgentPosition] = {}
        for round_no in range(1, self._max_rounds + 1):
            state = NegotiationState(round_no, self._max_rounds, tuple(options), dict(latest))
            # Todos los agentes piensan A LA VEZ (asyncio.gather), no uno tras otro.
            answers = await asyncio.gather(*(self._ask(agent, state) for agent in agents))
            for agent, answer in zip(agents, answers, strict=True):
                if answer is not None:
                    latest[agent.agent_id] = _sanitize(answer, agent.agent_id, set(ids))

            agreed = _consensus(latest, len(agents))
            if agreed is not None:
                return NegotiationResult(agreed, "consensus", round_no, dict(latest))

        winner = arbitrate(options, latest.values())
        log.info("negociación sin consenso: decide el árbitro", extra={"option_id": winner})
        return NegotiationResult(winner, "arbitration", self._max_rounds, dict(latest))

    async def _ask(self, agent: NegotiationAgent, state: NegotiationState) -> AgentPosition | None:
        try:
            async with asyncio.timeout(self._round_timeout):
                return await agent.respond(state)
        except TimeoutError:
            log.warning(
                "agente sin respuesta a tiempo", extra={"agent_id": agent.agent_id, "round": state.round}
            )
        except Exception:
            # Un agente roto no tumba la negociación: conserva su postura anterior.
            log.exception("agente falló", extra={"agent_id": agent.agent_id, "round": state.round})
        return None


def _sanitize(position: AgentPosition, agent_id: str, valid: set[str]) -> AgentPosition:
    """Quita opciones inventadas (un LLM podría "alucinar" un id) y repetidas.

    Además fija el agent_id real: un agente no puede hablar en nombre de otro.
    """
    seen: set[str] = set()
    ranking = []
    for option_id in position.ranking:
        if option_id in valid and option_id not in seen:
            ranking.append(option_id)
            seen.add(option_id)
    return AgentPosition(agent_id=agent_id, ranking=tuple(ranking))


def _consensus(latest: Mapping[str, AgentPosition], n_agents: int) -> str | None:
    """Hay consenso si TODOS los agentes tienen la misma opción favorita."""
    if len(latest) < n_agents:
        return None
    favourites = {p.ranking[0] for p in latest.values() if p.ranking}
    complete = all(p.ranking for p in latest.values())
    return favourites.pop() if complete and len(favourites) == 1 else None


def arbitrate(options: Sequence[GroupOption], positions: Iterable[AgentPosition]) -> str:
    """Árbitro determinista: recuento Borda con desempates fijos.

    Recuento Borda: con N opciones, la favorita de cada agente suma N-1
    puntos, la segunda N-2... y las que no menciona, 0. Gana la que más suma.
    Empate -> la más barata. Si sigue el empate -> el option_id menor
    alfabéticamente. Mismas entradas = mismo ganador, siempre.
    """
    n = len(options)
    scores = {o.option_id: 0 for o in options}
    for position in positions:
        for rank, option_id in enumerate(position.ranking):
            if option_id in scores:
                scores[option_id] += n - 1 - rank
    best = min(options, key=lambda o: (-scores[o.option_id], o.price_minor, o.option_id))
    return best.option_id
