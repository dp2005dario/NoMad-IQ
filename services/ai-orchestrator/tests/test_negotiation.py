"""Tests del motor: las reglas se cumplen pase lo que pase con los agentes."""

from __future__ import annotations

import asyncio
from collections.abc import Sequence

import pytest

from ai_orchestrator.negotiation.domain import AgentPosition, GroupOption, Outcome
from ai_orchestrator.negotiation.engine import NegotiationEngine, NegotiationState, Seat, arbitrate

OPTIONS = [
    GroupOption(option_id="tokio", label="Tokio", price_minor=90000),
    GroupOption(option_id="lisboa", label="Lisboa", price_minor=30000),
    GroupOption(option_id="roma", label="Roma", price_minor=40000),
]
BIG_BUDGET = 1_000_000


class ScriptedAgent:
    """Agente que responde según un guion por ronda (la última se repite).

    Cada paso del guion es (ranking, aceptables).
    """

    def __init__(
        self, agent_id: str, script: Sequence[tuple[Sequence[str], Sequence[str]]], delay: float = 0.0
    ) -> None:
        self._id = agent_id
        self._script = [(tuple(r), frozenset(a)) for r, a in script]
        self._delay = delay
        self.calls = 0
        self.fallbacks = 0
        self.seen: list[NegotiationState] = []

    @property
    def agent_id(self) -> str:
        return self._id

    async def respond(self, state: NegotiationState) -> AgentPosition:
        self.calls += 1
        self.seen.append(state)
        if self._delay:
            await asyncio.sleep(self._delay)
        ranking, acceptable = self._script[min(state.round, len(self._script)) - 1]
        # Intenta hacerse pasar por otro: el motor debe impedirlo.
        return AgentPosition(
            agent_id="me-hago-pasar-por-otro", ranking=ranking, acceptable=acceptable, source="llm"
        )

    def fallback(self, state: NegotiationState) -> AgentPosition:
        self.fallbacks += 1
        ids = tuple(o.option_id for o in state.options)
        return AgentPosition(agent_id=self._id, ranking=ids, acceptable=frozenset(ids[:1]))


class BrokenAgent(ScriptedAgent):
    async def respond(self, state: NegotiationState) -> AgentPosition:
        raise RuntimeError("se rompió")


def seats(*agents: ScriptedAgent, budget: int = BIG_BUDGET) -> list[Seat]:
    return [Seat(a, budget) for a in agents]


async def test_overlap_in_first_round_is_consensus() -> None:
    a = ScriptedAgent("ana", [(["tokio", "roma"], ["tokio", "roma"])])
    b = ScriptedAgent("beto", [(["lisboa", "roma"], ["lisboa", "roma"])])
    result = await NegotiationEngine(max_rounds=5).run(OPTIONS, seats(a, b))
    assert result.outcome is Outcome.CONSENSUS
    assert result.option_id == "roma"
    assert result.rounds == 1
    assert a.calls == 1  # no se gastan más rondas de las necesarias


async def test_concessions_lead_to_consensus() -> None:
    a = ScriptedAgent("ana", [(["tokio", "roma"], ["tokio"]), (["tokio", "roma"], ["roma"])])
    b = ScriptedAgent("beto", [(["lisboa", "roma"], ["lisboa"]), (["lisboa", "roma"], ["roma"])])
    result = await NegotiationEngine(max_rounds=5).run(OPTIONS, seats(a, b))
    assert result.outcome is Outcome.CONSENSUS
    assert result.option_id == "roma"
    assert result.rounds == 2
    # Las concesiones no se retiran: ana sigue aceptando tokio (de la ronda 1).
    assert result.positions["ana"].acceptable == {"tokio", "roma"}


async def test_several_common_options_pick_the_fairest() -> None:
    # Las tres son aceptables para los dos. Roma es la segunda para ambos;
    # Tokio y Lisboa son la favorita de uno y la ÚLTIMA del otro.
    a = ScriptedAgent("ana", [(["tokio", "roma", "lisboa"], ["tokio", "roma", "lisboa"])])
    b = ScriptedAgent("beto", [(["lisboa", "roma", "tokio"], ["tokio", "roma", "lisboa"])])
    result = await NegotiationEngine().run(OPTIONS, seats(a, b))
    assert result.outcome is Outcome.CONSENSUS
    assert result.option_id == "roma"


async def test_stalemate_goes_to_the_arbiter_early() -> None:
    a = ScriptedAgent("ana", [(["tokio", "roma", "lisboa"], ["tokio"])])
    b = ScriptedAgent("beto", [(["lisboa", "roma", "tokio"], ["lisboa"])])
    result = await NegotiationEngine(max_rounds=5).run(OPTIONS, seats(a, b))
    assert result.outcome is Outcome.ARBITRATION
    # Ronda 2 idéntica a la 1: no tiene sentido seguir hasta la 5.
    assert result.rounds == 2
    assert a.calls == 2
    # Igualitario: Roma es la segunda de los dos; Tokio/Lisboa dejan a uno en la última.
    assert result.option_id == "roma"


async def test_endless_disagreement_is_cut_by_max_rounds() -> None:
    # Cambian de postura cada ronda (sin conceder nada en común): no hay estancamiento.
    a = ScriptedAgent(
        "ana", [(["tokio", "roma", "lisboa"], ["tokio"]), (["roma", "tokio", "lisboa"], [])] * 3
    )
    b = ScriptedAgent(
        "beto", [(["lisboa", "roma", "tokio"], ["lisboa"]), (["lisboa", "tokio", "roma"], [])] * 3
    )
    result = await NegotiationEngine(max_rounds=3).run(OPTIONS, seats(a, b))
    assert result.outcome is Outcome.ARBITRATION
    assert result.rounds == 3
    assert a.calls == 3 and b.calls == 3


async def test_budget_is_a_hard_line() -> None:
    # Ana quiere Tokio a toda costa, pero Beto solo puede pagar 500 €.
    a = ScriptedAgent("ana", [(["tokio"], ["tokio"])])
    b = ScriptedAgent("beto", [(["tokio", "roma"], ["tokio", "roma"])])
    result = await NegotiationEngine().run(OPTIONS, [Seat(a, BIG_BUDGET), Seat(b, 50000)])
    assert result.excluded_over_budget == ("tokio",)
    assert result.option_id != "tokio"
    assert "tokio" not in result.positions["ana"].ranking
    assert all("tokio" not in [o.option_id for o in s.options] for s in a.seen)


async def test_no_feasible_option_spends_no_llm() -> None:
    a = ScriptedAgent("ana", [(["tokio"], ["tokio"])])
    result = await NegotiationEngine().run(OPTIONS, seats(a, budget=100))
    assert result.outcome is Outcome.NO_FEASIBLE_OPTION
    assert result.option_id is None
    assert a.calls == 0


async def test_single_feasible_option_needs_no_rounds() -> None:
    a = ScriptedAgent("ana", [(["lisboa"], ["lisboa"])])
    b = ScriptedAgent("beto", [(["lisboa"], ["lisboa"])])
    result = await NegotiationEngine().run(OPTIONS, seats(a, b, budget=35000))
    assert (result.outcome, result.option_id, result.rounds) == (Outcome.CONSENSUS, "lisboa", 0)
    assert a.calls == 0


async def test_agents_see_others_without_free_text() -> None:
    a = ScriptedAgent("ana", [(["tokio"], ["tokio"])])
    b = ScriptedAgent("beto", [(["lisboa"], ["lisboa"])])
    await NegotiationEngine(max_rounds=2).run(OPTIONS, seats(a, b))
    last = a.seen[-1]
    assert set(last.others) == {"beto"}  # solo los demás, una postura cada uno
    # Lo que ve de Beto no tiene campo de texto: no puede inyectarle nada.
    assert not hasattr(last.others["beto"], "argument")
    assert last.previous is not None and last.previous.agent_id == "ana"


async def test_hallucinated_options_and_impersonation_are_fixed() -> None:
    a = ScriptedAgent("ana", [(["paris", "roma", "roma"], ["paris", "roma"])])
    b = ScriptedAgent("beto", [(["roma"], ["roma"])])
    result = await NegotiationEngine(max_rounds=2).run(OPTIONS, seats(a, b))
    assert result.outcome is Outcome.CONSENSUS
    ana = result.positions["ana"]
    assert ana.agent_id == "ana"
    # Sin "paris" ni repetidos, y completado con lo que faltaba (de más barata a más cara).
    assert ana.ranking == ("roma", "lisboa", "tokio")
    assert ana.acceptable == {"roma"}


async def test_slow_or_broken_agents_do_not_block() -> None:
    slow = ScriptedAgent("lento", [(["tokio"], ["tokio"])], delay=5)
    broken = BrokenAgent("roto", [(["roma"], ["roma"])])
    ok = ScriptedAgent("ana", [(["roma"], ["roma"])])
    engine = NegotiationEngine(max_rounds=2, round_timeout_seconds=0.05)
    result = await asyncio.wait_for(engine.run(OPTIONS, seats(slow, broken, ok)), timeout=2)
    # Los dos que fallan usan su plan B (aceptan solo su primera opción: tokio).
    assert slow.fallbacks >= 1 and broken.fallbacks >= 1
    assert result.fallbacks == {"lento", "roto"}
    assert set(result.positions) == {"lento", "roto", "ana"}


async def test_total_timeout_still_gives_an_answer() -> None:
    slow = ScriptedAgent("lento", [(["tokio"], ["tokio"])], delay=5)
    other = ScriptedAgent("otro", [(["roma"], ["roma"])], delay=5)
    engine = NegotiationEngine(max_rounds=3, round_timeout_seconds=0.05, total_timeout_seconds=0.08)
    result = await asyncio.wait_for(engine.run(OPTIONS, seats(slow, other)), timeout=2)
    # Nadie contestó a tiempo: los dos planes B deciden, y se acaba en una ronda.
    assert result.fallbacks == {"lento", "otro"}
    assert result.rounds == 1
    assert result.option_id is not None


def test_arbitration_is_deterministic_and_egalitarian() -> None:
    positions = [
        AgentPosition(agent_id="a", ranking=("tokio", "roma", "lisboa"), acceptable=frozenset()),
        AgentPosition(agent_id="b", ranking=("roma", "tokio", "lisboa"), acceptable=frozenset()),
        AgentPosition(agent_id="c", ranking=("roma", "lisboa", "tokio"), acceptable=frozenset()),
    ]
    assert {arbitrate(OPTIONS, positions) for _ in range(20)} == {"roma"}
    assert arbitrate(OPTIONS, list(reversed(positions))) == "roma"
    assert arbitrate(OPTIONS, []) == "lisboa"  # sin posturas: la más barata


def test_arbiter_protects_the_minority() -> None:
    # Dos personas adoran Tokio y odian Lisboa; una odia Tokio. Borda puro
    # elegiría Tokio (2+2+0 = 4 puntos frente a 3 de Roma). El criterio
    # igualitario prefiere Roma: nadie queda en su última opción.
    positions = [
        AgentPosition(agent_id="a", ranking=("tokio", "roma", "lisboa"), acceptable=frozenset()),
        AgentPosition(agent_id="b", ranking=("tokio", "roma", "lisboa"), acceptable=frozenset()),
        AgentPosition(agent_id="c", ranking=("lisboa", "roma", "tokio"), acceptable=frozenset()),
    ]
    assert arbitrate(OPTIONS, positions) == "roma"


@pytest.mark.parametrize("rounds", [0, 11])
def test_round_limit_is_capped(rounds: int) -> None:
    with pytest.raises(ValueError, match="max_rounds"):
        NegotiationEngine(max_rounds=rounds)


async def test_invalid_inputs_are_rejected() -> None:
    engine = NegotiationEngine()
    a = ScriptedAgent("ana", [(["tokio"], ["tokio"])])
    with pytest.raises(ValueError, match="opciones"):
        await engine.run([], seats(a))
    with pytest.raises(ValueError, match="agentes"):
        await engine.run(OPTIONS, [])
    with pytest.raises(ValueError, match="option_id repetido"):
        await engine.run([*OPTIONS, OPTIONS[0]], seats(a))
    with pytest.raises(ValueError, match="agent_id repetido"):
        await engine.run(OPTIONS, seats(a, a))
