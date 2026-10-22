"""El servicio de negociación: junta todas las piezas para UNA negociación.

Pasos de ``run`` (lo llama el consumidor de Kafka por cada orden de trabajo):
    1. "Reclama" la negociación (queued -> running). Si no estaba en cola es
       un duplicado de Kafka o ya la hizo otro: no hace nada. Así repetir una
       orden es inofensivo (idempotencia).
    2. Sienta a la mesa a un agente por cada miembro que envió preferencias
       (LLM si está activado; si no, reglas).
    3. Deja que el motor negocie (engine.py, con todas sus reglas y límites).
    4. Guarda el resultado, borra las preferencias privadas y deja el anuncio
       para Kafka en el outbox, todo en una transacción (store.conclude).
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum

from ai_orchestrator.llm.client import LLMClient
from ai_orchestrator.negotiation.agents import AgentSettings, LLMAgent, RuleAgent
from ai_orchestrator.negotiation.domain import (
    MIN_MEMBERS,
    AgentPosition,
    GroupOption,
    Member,
    MemberResult,
    NegotiationResult,
    Outcome,
)
from ai_orchestrator.negotiation.engine import EngineResult, NegotiationAgent, NegotiationEngine, Seat
from ai_orchestrator.negotiation.events import concluded_message
from ai_orchestrator.negotiation.store import NegotiationStore
from ai_orchestrator.pseudonym import Pseudonymizer

log = logging.getLogger(__name__)


class RunOutcome(StrEnum):
    CONCLUDED = "concluded"
    # No estaba en cola: duplicado de Kafka o la terminó otro proceso.
    SKIPPED = "skipped"
    # Menos de dos miembros con preferencias: no hay nada que negociar.
    EXPIRED = "expired"


@dataclass(frozen=True, slots=True)
class NegotiationSettings:
    results_topic: str
    lease_seconds: int
    round_timeout_seconds: float
    total_timeout_seconds: float
    agent: AgentSettings


class NegotiationService:
    def __init__(
        self,
        *,
        store: NegotiationStore,
        llm: LLMClient | None,
        settings: NegotiationSettings,
        pseudonymizer: Pseudonymizer | None = None,
        on_outbox: Callable[[], None] | None = None,
    ) -> None:
        self._store = store
        self._llm = llm
        self._settings = settings
        self._pseudonymizer = pseudonymizer
        # Se llama al dejar algo en el outbox: "toca el timbre" del relé.
        self._on_outbox = on_outbox

    async def run(self, negotiation_id: str) -> RunOutcome:
        record = await self._store.claim(negotiation_id, lease_seconds=self._settings.lease_seconds)
        if record is None:
            log.info("negociación que no estaba en cola: se ignora", extra={"negotiation_id": negotiation_id})
            return RunOutcome.SKIPPED

        seats: list[Seat] = []
        for m in record.members:
            if m.preferences is None:
                continue  # no envió sus preferencias a tiempo: no tiene asiento
            member = Member(alias=m.alias, preferences=m.preferences)
            seats.append(
                Seat(self._agent(member, record.currency, record.language), m.preferences.budget_max_minor)
            )

        if len(seats) < MIN_MEMBERS:
            # No debería pasar (solo se pone en cola con dos o más listos),
            # pero si pasa no hay grupo que negociar: se caduca, sin romper nada.
            await self._store.expire(negotiation_id)
            log.error(
                "negociación sin participantes suficientes: caducada",
                extra={"negotiation_id": negotiation_id, "members": len(seats)},
            )
            return RunOutcome.EXPIRED

        engine = NegotiationEngine(
            max_rounds=record.max_rounds,
            round_timeout_seconds=self._settings.round_timeout_seconds,
            total_timeout_seconds=self._settings.total_timeout_seconds,
        )
        outcome = await engine.run(record.options, seats)
        result = build_result(outcome, record.options, [s.agent.agent_id for s in seats], record.language)

        recipients = (
            [self._pseudonymizer.recipient(m.user_id) for m in record.members] if self._pseudonymizer else []
        )
        message = concluded_message(
            self._settings.results_topic, negotiation_id, result, recipients, datetime.now(UTC)
        )
        saved = await self._store.conclude(negotiation_id, result, message)
        if saved and self._on_outbox is not None:
            self._on_outbox()
        log.info(
            "negociación terminada",
            extra={
                "negotiation_id": negotiation_id,
                "outcome": result.outcome.value,
                "rounds": result.rounds,
                "members": len(seats),
                "llm_used": result.llm_used,
                "fallbacks": len(outcome.fallbacks),
                "saved": saved,
            },
        )
        return RunOutcome.CONCLUDED

    def _agent(self, member: Member, currency: str, language: str) -> NegotiationAgent:
        if self._llm is None:
            return RuleAgent(member, language=language)
        return LLMAgent(
            member, llm=self._llm, currency=currency, language=language, settings=self._settings.agent
        )


def build_result(
    outcome: EngineResult, options: tuple[GroupOption, ...], aliases: list[str], language: str
) -> NegotiationResult:
    """Convierte lo que devuelve el motor en el resultado que se guarda y se enseña."""
    chosen = outcome.option_id
    members = []
    for alias in aliases:
        p: AgentPosition | None = outcome.positions.get(alias)
        if p is None:
            # Solo pasa si no había opciones posibles: no hubo posturas.
            members.append(
                MemberResult(
                    alias=alias, ranking=(), acceptable=(), argument="", source="rules", chosen_rank=None
                )
            )
            continue
        members.append(
            MemberResult(
                alias=alias,
                ranking=p.ranking,
                # Ordenados como su ranking (un conjunto no tiene orden).
                acceptable=tuple(o for o in p.ranking if o in p.acceptable),
                argument=p.argument,
                source=p.source,
                chosen_rank=p.ranking.index(chosen) + 1 if chosen in p.ranking else None,
            )
        )
    labels = {o.option_id: o.label for o in options}
    return NegotiationResult(
        outcome=outcome.outcome,
        chosen_option_id=chosen,
        rounds=outcome.rounds,
        explanation=explain(outcome, labels, language),
        excluded_over_budget=outcome.excluded_over_budget,
        members=tuple(members),
        llm_used=any(p.source == "llm" for p in outcome.positions.values()),
    )


def explain(outcome: EngineResult, labels: dict[str, str], language: str) -> str:
    """Explicación en lenguaje llano, escrita por CÓDIGO (no por el LLM): así
    nunca puede contradecir lo que de verdad decidieron las reglas."""
    es = language == "es"
    label = labels.get(outcome.option_id or "", "")
    excluded = len(outcome.excluded_over_budget)
    if outcome.outcome is Outcome.NO_FEASIBLE_OPTION:
        return (
            "Ninguna opción cabe en el presupuesto de todo el grupo. Probad con opciones más baratas "
            "o revisad los presupuestos."
            if es
            else "No option fits everyone's budget. Try cheaper options or review the budgets."
        )
    if outcome.outcome is Outcome.CONSENSUS and outcome.rounds == 0:
        return (
            f"Solo «{label}» cabe en el presupuesto de todo el grupo, así que no hizo falta negociar."
            if es
            else f"Only “{label}” fits everyone's budget, so no negotiation was needed."
        )
    if outcome.outcome is Outcome.CONSENSUS:
        text = (
            f"Acuerdo en la ronda {outcome.rounds}: todos aceptan «{label}»."
            if es
            else f"Agreement in round {outcome.rounds}: everyone accepts “{label}”."
        )
    else:
        text = (
            f"No hubo acuerdo en {outcome.rounds} rondas. El árbitro eligió «{label}»: es la opción que "
            "deja mejor a la persona peor parada del grupo."
            if es
            else f"No agreement after {outcome.rounds} rounds. The arbiter chose “{label}”: the option "
            "that leaves the least satisfied person best off."
        )
    if excluded:
        text += (
            f" Se descartaron {excluded} opciones por superar el presupuesto de alguien."
            if es
            else f" {excluded} options were dropped for exceeding someone's budget."
        )
    return text
