"""Motor de la negociación: las REGLAS del juego, sin nada de IA.

Idea del producto: cada persona del grupo tiene un "agente" (normalmente un
LLM con sus preferencias) que defiende sus intereses. Los agentes van
revisando sus posturas, viendo las de los demás, hasta encontrar una opción
que todos acepten.

Analogía: una mesa de negociación con un moderador. Los agentes hablan, pero
las reglas las pone el moderador (este fichero), que no es una IA y no se
puede convencer de nada:

    1. Presupuesto = línea roja. Antes de empezar se descartan las opciones
       que superan el presupuesto de ALGUIEN. Ningún agente puede rescatarlas,
       porque el LLM podría "olvidarse" de un límite; el código no.
    2. Acuerdo = una opción que está en la lista de "aceptables" de TODOS.
       Si hay varias, se elige con la fórmula del árbitro (punto 6).
    3. Concesiones que no se deshacen: lo que un agente acepta en una ronda
       lo sigue aceptando en las siguientes. Así la negociación solo puede
       avanzar hacia el acuerdo, nunca dar vueltas en círculo.
    4. Límites: número MÁXIMO de rondas, tiempo máximo por ronda y para toda
       la negociación. El agente que no contesta a tiempo (o falla) mantiene
       su postura anterior; si aún no tenía, usa su plan B por reglas.
       Nadie bloquea a los demás.
    5. Si en una ronda nadie cambia de postura, seguir no sirve de nada:
       se pasa directamente al árbitro (ahorra GPU).
    6. Árbitro determinista: con las mismas posturas da siempre el mismo
       resultado. Primero busca la opción que deja MÁS contenta a la persona
       PEOR parada (criterio "igualitario": evita que la mayoría aplaste
       siempre a uno). Si empata, la que más puntos suma entre todos (Borda).
       Luego la más barata. Luego el option_id menor alfabéticamente.
    7. Cada agente ve de los demás solo su ÚLTIMA postura (ranking y
       aceptables), nunca su historial ni sus argumentos en texto libre:
         - el contexto del LLM no crece con las rondas;
         - un texto escrito por un LLM no puede "inyectar" órdenes en otro.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Protocol

from ai_orchestrator.negotiation.domain import AgentPosition, GroupOption, Outcome

log = logging.getLogger(__name__)

# Techo absoluto, aunque alguien configure más: la negociación es acotada sí o sí.
HARD_MAX_ROUNDS = 10


@dataclass(frozen=True, slots=True)
class PublicPosition:
    """Lo que un agente puede ver de otro: solo números de opciones, sin texto."""

    ranking: tuple[str, ...]
    acceptable: frozenset[str]


@dataclass(frozen=True, slots=True)
class NegotiationState:
    """Lo que ve UN agente al empezar una ronda."""

    round: int
    max_rounds: int
    # Solo las opciones que caben en el presupuesto de todos.
    options: tuple[GroupOption, ...]
    # La última postura de cada uno de los OTROS agentes (por alias).
    others: Mapping[str, PublicPosition]
    # Su propia postura de la ronda anterior (None en la primera).
    previous: AgentPosition | None


class NegotiationAgent(Protocol):
    """Lo que el motor necesita de un agente (LLM o reglas, le da igual)."""

    @property
    def agent_id(self) -> str: ...

    async def respond(self, state: NegotiationState) -> AgentPosition:
        """Su postura para esta ronda. Puede tardar o fallar: el motor lo controla."""
        ...

    def fallback(self, state: NegotiationState) -> AgentPosition:
        """Postura de emergencia por reglas: instantánea y sin errores posibles."""
        ...


@dataclass(frozen=True, slots=True)
class Seat:
    """Un asiento en la mesa: el agente y la línea roja de su viajero."""

    agent: NegotiationAgent
    budget_max_minor: int


@dataclass(frozen=True, slots=True)
class EngineResult:
    outcome: Outcome
    option_id: str | None
    rounds: int
    positions: Mapping[str, AgentPosition]
    excluded_over_budget: tuple[str, ...]
    # Agentes que tuvieron que usar el plan B en alguna ronda (para métricas).
    fallbacks: frozenset[str] = field(default_factory=frozenset)


class NegotiationEngine:
    def __init__(
        self,
        *,
        max_rounds: int = 3,
        round_timeout_seconds: float = 120.0,
        total_timeout_seconds: float = 300.0,
    ) -> None:
        if not 1 <= max_rounds <= HARD_MAX_ROUNDS:
            raise ValueError(f"max_rounds debe estar entre 1 y {HARD_MAX_ROUNDS}")
        if round_timeout_seconds <= 0 or total_timeout_seconds <= 0:
            raise ValueError("los tiempos máximos deben ser > 0")
        self._max_rounds = max_rounds
        self._round_timeout = round_timeout_seconds
        self._total_timeout = total_timeout_seconds

    async def run(self, options: Sequence[GroupOption], seats: Sequence[Seat]) -> EngineResult:
        _validate(options, seats)

        # Regla 1: el presupuesto es una línea roja que decide el código.
        feasible = tuple(o for o in options if all(o.price_minor <= s.budget_max_minor for s in seats))
        excluded = tuple(o.option_id for o in options if o not in feasible)
        if not feasible:
            log.info("negociación sin opciones dentro del presupuesto de todos")
            return EngineResult(Outcome.NO_FEASIBLE_OPTION, None, 0, {}, excluded)

        latest: dict[str, AgentPosition] = {}
        fallbacks: set[str] = set()

        if len(feasible) == 1:
            # Solo cabe una opción: no hay nada que negociar ni que gastar en GPU.
            state = NegotiationState(0, self._max_rounds, feasible, {}, None)
            for seat in seats:
                latest[seat.agent.agent_id] = _sanitize(
                    seat.agent.fallback(state), seat.agent.agent_id, feasible
                )
            return EngineResult(Outcome.CONSENSUS, feasible[0].option_id, 0, latest, excluded)

        loop = asyncio.get_running_loop()
        deadline = loop.time() + self._total_timeout
        rounds = 0
        for round_no in range(1, self._max_rounds + 1):
            remaining = deadline - loop.time()
            if remaining <= 0:
                log.warning("negociación sin tiempo: decide el árbitro", extra={"round": round_no})
                break
            rounds = round_no
            states = {
                seat.agent.agent_id: NegotiationState(
                    round=round_no,
                    max_rounds=self._max_rounds,
                    options=feasible,
                    others={
                        other_id: PublicPosition(p.ranking, p.acceptable)
                        for other_id, p in latest.items()
                        if other_id != seat.agent.agent_id
                    },
                    previous=latest.get(seat.agent.agent_id),
                )
                for seat in seats
            }
            timeout = min(self._round_timeout, remaining)
            # Todos los agentes piensan A LA VEZ (asyncio.gather), no uno tras otro.
            answers = await asyncio.gather(
                *(self._ask(s.agent, states[s.agent.agent_id], timeout) for s in seats)
            )

            changed = False
            for seat, answer in zip(seats, answers, strict=True):
                agent_id = seat.agent.agent_id
                state = states[agent_id]
                previous = latest.get(agent_id)
                if answer is None:
                    # Regla 4: sin respuesta, conserva su postura o usa el plan B.
                    fallbacks.add(agent_id)
                    answer = previous if previous is not None else seat.agent.fallback(state)
                position = _sanitize(answer, agent_id, feasible, previous)
                if previous is None or (position.ranking, position.acceptable) != (
                    previous.ranking,
                    previous.acceptable,
                ):
                    changed = True
                latest[agent_id] = position

            agreed = _consensus(feasible, latest)
            if agreed is not None:
                return EngineResult(
                    Outcome.CONSENSUS, agreed, round_no, dict(latest), excluded, frozenset(fallbacks)
                )
            if not changed:
                # Regla 5: estancamiento. Otra ronda daría exactamente lo mismo.
                log.info("negociación estancada: decide el árbitro", extra={"round": round_no})
                break

        # Si se acabó el tiempo antes de la primera ronda, los que no tienen
        # postura usan su plan B: el árbitro necesita a todos.
        for seat in seats:
            agent_id = seat.agent.agent_id
            if agent_id not in latest:
                fallbacks.add(agent_id)
                state = NegotiationState(rounds, self._max_rounds, feasible, {}, None)
                latest[agent_id] = _sanitize(seat.agent.fallback(state), agent_id, feasible)
        winner = arbitrate(feasible, latest.values())
        log.info("negociación sin consenso: decide el árbitro", extra={"option_id": winner, "rounds": rounds})
        return EngineResult(Outcome.ARBITRATION, winner, rounds, dict(latest), excluded, frozenset(fallbacks))

    async def _ask(
        self, agent: NegotiationAgent, state: NegotiationState, seconds: float
    ) -> AgentPosition | None:
        try:
            async with asyncio.timeout(seconds):
                return await agent.respond(state)
        except TimeoutError:
            log.warning(
                "agente sin respuesta a tiempo", extra={"agent_id": agent.agent_id, "round": state.round}
            )
        except Exception:
            # Un agente roto no tumba la negociación: el motor usa su plan B.
            log.exception("agente falló", extra={"agent_id": agent.agent_id, "round": state.round})
        return None


def _validate(options: Sequence[GroupOption], seats: Sequence[Seat]) -> None:
    if not options:
        raise ValueError("no hay opciones que negociar")
    if not seats:
        raise ValueError("no hay agentes")
    ids = [o.option_id for o in options]
    if len(set(ids)) != len(ids):
        raise ValueError("option_id repetido")
    agent_ids = [s.agent.agent_id for s in seats]
    if len(set(agent_ids)) != len(agent_ids):
        raise ValueError("agent_id repetido")


def _sanitize(
    position: AgentPosition,
    agent_id: str,
    options: Sequence[GroupOption],
    previous: AgentPosition | None = None,
) -> AgentPosition:
    """Convierte lo que diga un agente en una postura VÁLIDA según las reglas.

    - Quita opciones inventadas (un LLM podría "alucinar" un id) y repetidas.
    - Completa el ranking con las opciones que olvidó, al final y de la más
      barata a la más cara (orden fijo, sin azar).
    - Regla 3: lo aceptado antes se sigue aceptando. Y su favorita, siempre.
    - Fija el agent_id real: un agente no puede hablar en nombre de otro.
    """
    valid = {o.option_id for o in options}
    ranking: list[str] = []
    for option_id in position.ranking:
        if option_id in valid and option_id not in ranking:
            ranking.append(option_id)
    for option in sorted(options, key=lambda o: (o.price_minor, o.option_id)):
        if option.option_id not in ranking:
            ranking.append(option.option_id)
    acceptable = (position.acceptable & valid) | {ranking[0]}
    if previous is not None:
        acceptable |= previous.acceptable
    return AgentPosition(
        agent_id=agent_id,
        ranking=tuple(ranking),
        acceptable=frozenset(acceptable),
        argument=position.argument,
        source=position.source,
    )


def _consensus(options: Sequence[GroupOption], latest: Mapping[str, AgentPosition]) -> str | None:
    """Regla 2: hay acuerdo si alguna opción está en los aceptables de TODOS."""
    common = frozenset.intersection(*(p.acceptable for p in latest.values()))
    if not common:
        return None
    return arbitrate([o for o in options if o.option_id in common], latest.values())


def arbitrate(options: Sequence[GroupOption], positions: Iterable[AgentPosition]) -> str:
    """Árbitro determinista (regla 6). Mismas entradas = mismo ganador, siempre.

    Satisfacción de un agente con una opción = cuántas de las opciones en
    juego deja por debajo en su ranking (su favorita de N vale N-1, la
    última 0; la que ni menciona, 0).

    Orden de criterios:
        1. Mayor satisfacción MÍNIMA (la persona peor parada, lo mejor posible).
        2. Mayor satisfacción TOTAL (recuento Borda).
        3. Precio más bajo.
        4. option_id menor alfabéticamente (para que nunca haya empate).
    """
    if not options:
        raise ValueError("no hay opciones que arbitrar")
    ids = {o.option_id for o in options}
    # Cada ranking, quedándonos solo con las opciones en juego (al decidir
    # entre las aceptadas por todos, las demás no cuentan).
    rankings = [tuple(r for r in p.ranking if r in ids) for p in positions]
    n = len(options)

    def satisfaction(ranking: tuple[str, ...], option_id: str) -> int:
        return n - 1 - ranking.index(option_id) if option_id in ranking else 0

    def key(o: GroupOption) -> tuple[int, int, int, str]:
        scores = [satisfaction(r, o.option_id) for r in rankings]
        # min() del signo cambiado = el mayor; así un único min() ordena todo.
        return (-min(scores, default=0), -sum(scores), o.price_minor, o.option_id)

    return min(options, key=key).option_id
