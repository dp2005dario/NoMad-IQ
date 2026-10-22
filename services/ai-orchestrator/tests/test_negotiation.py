"""Tests de la negociación: siempre termina y el árbitro es determinista."""

from __future__ import annotations

import asyncio
from collections.abc import Sequence

import pytest

from ai_orchestrator.negotiation import (
    AgentPosition,
    GroupOption,
    NegotiationEngine,
    NegotiationState,
    arbitrate,
)

OPTIONS = [
    GroupOption(option_id="tokio", label="Tokio", price_minor=90000, currency="EUR"),
    GroupOption(option_id="lisboa", label="Lisboa", price_minor=30000, currency="EUR"),
    GroupOption(option_id="roma", label="Roma", price_minor=40000, currency="EUR"),
]


class ScriptedAgent:
    """Agente que responde según un guion por ronda (la última se repite)."""

    def __init__(self, agent_id: str, rankings: Sequence[Sequence[str]], delay: float = 0.0) -> None:
        self._id = agent_id
        self._rankings = [tuple(r) for r in rankings]
        self._delay = delay
        self.calls = 0
        self.seen: list[NegotiationState] = []

    @property
    def agent_id(self) -> str:
        return self._id

    async def respond(self, state: NegotiationState) -> AgentPosition:
        self.calls += 1
        self.seen.append(state)
        if self._delay:
            await asyncio.sleep(self._delay)
        ranking = self._rankings[min(state.round, len(self._rankings)) - 1]
        return AgentPosition(agent_id="me-hago-pasar-por-otro", ranking=ranking)


class BrokenAgent(ScriptedAgent):
    async def respond(self, state: NegotiationState) -> AgentPosition:
        raise RuntimeError("se rompió")


async def test_consensus_stops_early() -> None:
    a = ScriptedAgent("ana", [["tokio", "roma"], ["roma", "tokio"]])
    b = ScriptedAgent("beto", [["lisboa", "roma"], ["roma"]])
    result = await NegotiationEngine(max_rounds=5).run(OPTIONS, [a, b])
    assert result.outcome == "consensus"
    assert result.option_id == "roma"
    assert result.rounds == 2
    assert a.calls == 2  # no se gastan más rondas de las necesarias


async def test_endless_disagreement_is_cut_by_max_rounds() -> None:
    a = ScriptedAgent("ana", [["tokio", "roma", "lisboa"]])
    b = ScriptedAgent("beto", [["lisboa", "roma", "tokio"]])
    result = await NegotiationEngine(max_rounds=3).run(OPTIONS, [a, b])
    assert result.outcome == "arbitration"
    assert result.rounds == 3
    assert a.calls == 3 and b.calls == 3
    # Borda: tokio 2+0, lisboa 0+2, roma 1+1 -> triple empate a 2; gana la más barata.
    assert result.option_id == "lisboa"


async def test_agents_see_only_latest_positions() -> None:
    a = ScriptedAgent("ana", [["tokio"]])
    b = ScriptedAgent("beto", [["lisboa"]])
    await NegotiationEngine(max_rounds=3).run(OPTIONS, [a, b])
    last = a.seen[-1]
    assert set(last.latest) == {"ana", "beto"}  # una postura por agente, no un historial


async def test_hallucinated_options_and_impersonation_are_ignored() -> None:
    a = ScriptedAgent("ana", [["paris", "roma", "roma"]])
    b = ScriptedAgent("beto", [["roma"]])
    result = await NegotiationEngine(max_rounds=2).run(OPTIONS, [a, b])
    assert result.outcome == "consensus"
    assert result.positions["ana"].ranking == ("roma",)
    assert result.positions["ana"].agent_id == "ana"


async def test_slow_or_broken_agents_do_not_block() -> None:
    slow = ScriptedAgent("lento", [["tokio"]], delay=5)
    broken = BrokenAgent("roto", [["roma"]])
    ok = ScriptedAgent("ana", [["roma"]])
    engine = NegotiationEngine(max_rounds=2, round_timeout_seconds=0.05)
    result = await asyncio.wait_for(engine.run(OPTIONS, [slow, broken, ok]), timeout=2)
    assert result.outcome == "arbitration"
    assert result.option_id == "roma"


def test_arbitration_is_deterministic() -> None:
    positions = [
        AgentPosition(agent_id="a", ranking=("tokio", "roma", "lisboa")),
        AgentPosition(agent_id="b", ranking=("roma", "tokio", "lisboa")),
        AgentPosition(agent_id="c", ranking=("roma", "lisboa", "tokio")),
    ]
    winners = {arbitrate(OPTIONS, positions) for _ in range(20)}
    assert winners == {"roma"}
    assert arbitrate(OPTIONS, list(reversed(positions))) == "roma"
    assert arbitrate(OPTIONS, []) == "lisboa"  # sin posturas: la más barata


@pytest.mark.parametrize("rounds", [0, 11])
def test_round_limit_is_capped(rounds: int) -> None:
    with pytest.raises(ValueError, match="max_rounds"):
        NegotiationEngine(max_rounds=rounds)


async def test_invalid_inputs_are_rejected() -> None:
    engine = NegotiationEngine()
    a = ScriptedAgent("ana", [["tokio"]])
    with pytest.raises(ValueError, match="opciones"):
        await engine.run([], [a])
    with pytest.raises(ValueError, match="agentes"):
        await engine.run(OPTIONS, [])
    with pytest.raises(ValueError, match="divisa"):
        mixed = [*OPTIONS, GroupOption(option_id="ny", label="NY", price_minor=1, currency="USD")]
        await engine.run(mixed, [a])
