"""El recomendador: de una alerta de precio a un consejo corto y fiable.

Pasos para cada alerta:
    1. Recuperar datos reales: historial de precios (PostgreSQL) y, si hay,
       notas de viaje (Qdrant).
    2. Convertirlos en "hechos" con nombre (grounding.py).
    3. Pedir al LLM un JSON con veredicto + titular + explicación, usando
       huecos {nombre} en vez de cifras. Se valida y, si hace falta, se
       reintenta un número limitado de veces (llm/structured.py).
    4. Rellenar los huecos con los valores reales.

Plan B: si Ollama no está, tarda demasiado o no da una respuesta válida, se
genera la recomendación con reglas fijas (sin IA). El usuario siempre recibe
algo correcto; solo cambia lo "bonito" que esté redactado. Así un fallo de la
IA nunca bloquea el flujo de alertas.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from ai_orchestrator.context import estimate_tokens, truncate_text
from ai_orchestrator.domain import AlertType, FareAlert, KnowledgeSnippet, PriceStats, Recommendation, Verdict
from ai_orchestrator.grounding import build_facts, grounding_problems, render
from ai_orchestrator.llm.client import ChatMessage, LLMClient, LLMError
from ai_orchestrator.llm.structured import StructuredOutputError, generate_structured
from ai_orchestrator.retrieval import KnowledgeBase, PriceHistory, RetrievalError

log = logging.getLogger(__name__)

# Una notita de Qdrant no puede comerse el contexto: máximo ~150 tokens cada una.
SNIPPET_MAX_TOKENS = 150


class FareAdvice(BaseModel):
    """Lo ÚNICO que le pedimos al LLM. Pydantic genera con esto el esquema JSON
    que recibe Ollama y valida la respuesta. extra="forbid": campos de más = error."""

    model_config = ConfigDict(extra="forbid")

    verdict: Verdict = Field(description="BUY_NOW, CONSIDER o WAIT")
    headline: str = Field(min_length=5, max_length=160, description="Titular breve con huecos {nombre}")
    explanation: str = Field(
        min_length=10, max_length=700, description="Dos o tres frases con huecos {nombre}, sin cifras"
    )


SYSTEM_PROMPT = """Eres el asesor de vuelos de NomadIQ. Ayudas a un viajero a decidir si compra un billete.

Reglas obligatorias:
1. Usa EXCLUSIVAMENTE los hechos que te damos. No sabes nada más sobre precios, horarios ni aerolíneas.
2. NUNCA escribas cifras (ni precios, ni fechas, ni porcentajes). Para citar un dato escribe su hueco \
entre llaves, exactamente como aparece en la lista: por ejemplo {precio_actual}.
3. Si un dato no está en la lista, no lo menciones.
4. Las notas de viaje son contexto opcional; no las cites si no aportan nada.
5. Responde SOLO con un objeto JSON con los campos verdict, headline y explanation. Escribe en español, \
en tono cercano y claro.

Significado de verdict: BUY_NOW = comprar ya; CONSIDER = buen precio sin urgencia; WAIT = mejor esperar."""


@dataclass(frozen=True, slots=True)
class RecommenderSettings:
    temperature: float
    max_output_tokens: int
    max_attempts: int
    history_window_days: int
    knowledge_max_snippets: int
    # Ventana de contexto total del modelo (num_ctx).
    context_tokens: int


class FareRecommender:
    def __init__(
        self,
        *,
        llm: LLMClient | None,
        history: PriceHistory,
        knowledge: KnowledgeBase,
        settings: RecommenderSettings,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._llm = llm
        self._history = history
        self._knowledge = knowledge
        self._settings = settings
        # El reloj se inyecta para que los tests sean deterministas.
        self._clock = clock

    async def recommend(self, alert: FareAlert) -> Recommendation:
        """Genera la recomendación. Solo lanza excepción si falla la base de
        datos de precios (problema temporal: el mensaje se reintentará)."""
        stats = await self._history.stats(alert, window_days=self._settings.history_window_days)
        facts = build_facts(alert, stats)

        if self._llm is None:
            return self._by_rules(alert, stats, facts)

        snippets = await self._snippets(alert)
        try:
            advice = await generate_structured(
                self._llm,
                self._prompt(facts, snippets),
                FareAdvice,
                temperature=self._settings.temperature,
                max_tokens=self._settings.max_output_tokens,
                max_attempts=self._settings.max_attempts,
                checks=lambda a: grounding_problems([a.headline, a.explanation], facts),
            )
        except (LLMError, StructuredOutputError) as exc:
            log.warning(
                "LLM no disponible o sin respuesta válida: se usan reglas",
                extra={"alert_id": alert.alert_id, "error": str(exc)},
            )
            return self._by_rules(alert, stats, facts)

        try:
            return self._build(
                alert,
                facts,
                verdict=advice.verdict,
                headline=render(advice.headline, facts),
                body=render(advice.explanation, facts),
                source="llm",
                model=self._llm.model,
            )
        except ValidationError:
            # Raro: al rellenar los huecos el texto superó el tamaño máximo.
            log.warning(
                "texto del LLM demasiado largo al rellenarlo: se usan reglas",
                extra={"alert_id": alert.alert_id},
            )
            return self._by_rules(alert, stats, facts)

    async def _snippets(self, alert: FareAlert) -> list[KnowledgeSnippet]:
        if self._settings.knowledge_max_snippets == 0:
            return []
        query = f"Consejos para viajar a {alert.destination} desde {alert.origin}"
        try:
            return await self._knowledge.search(query, limit=self._settings.knowledge_max_snippets)
        except RetrievalError as exc:
            # Las notas son un extra: sin ellas la recomendación sigue siendo válida.
            log.warning("sin notas de viaje", extra={"alert_id": alert.alert_id, "error": str(exc)})
            return []

    def _prompt(self, facts: dict[str, str], snippets: list[KnowledgeSnippet]) -> list[ChatMessage]:
        facts_part = "Hechos verificados (hueco -> valor):\n" + json.dumps(
            facts, ensure_ascii=False, indent=1
        )
        closing = "Redacta la recomendación siguiendo las reglas."

        # Presupuesto de contexto: la ventana total, menos lo reservado para
        # cada respuesta (los reintentos añaden mensajes), menos lo que ya
        # ocupan las instrucciones y los hechos. Las notas usan lo que sobre.
        # Los hechos nunca se recortan: sin ellos no hay recomendación fiable.
        reserved = self._settings.max_output_tokens * self._settings.max_attempts
        used = estimate_tokens(SYSTEM_PROMPT) + estimate_tokens(facts_part) + estimate_tokens(closing)
        free = self._settings.context_tokens - reserved - used

        notes: list[str] = []
        for s in snippets:
            note = f"- ({s.source}) {truncate_text(s.text, SNIPPET_MAX_TOKENS)}"
            cost = estimate_tokens(note)
            if cost > free:
                break
            notes.append(note)
            free -= cost

        parts = [facts_part]
        if notes:
            parts.append("Notas de viaje recuperadas:\n" + "\n".join(notes))
        parts.append(closing)
        return [ChatMessage("system", SYSTEM_PROMPT), ChatMessage("user", "\n\n".join(parts))]

    # ------------------------------------------------------------------------
    # Plan B: reglas deterministas (mismo resultado para la misma entrada).
    # ------------------------------------------------------------------------

    def _by_rules(self, alert: FareAlert, stats: PriceStats | None, facts: dict[str, str]) -> Recommendation:
        history = (
            " En los últimos {dias_historial} días el precio habitual fue {precio_mediano_historial} "
            "y el mínimo {precio_minimo_historial}."
            if "precio_mediano_historial" in facts
            else ""
        )
        if alert.alert_type is AlertType.ERROR_FARE:
            verdict = Verdict.BUY_NOW
            headline = "Posible tarifa error de {origen} a {destino}: {precio_actual}"
            body = (
                "El precio está un {bajada_porcentaje} por debajo de la referencia de {precio_referencia}. "
                "Las tarifas error suelen corregirse en pocas horas: si te encaja, reserva cuanto antes y "
                "espera la confirmación de la aerolínea antes de pagar hoteles."
            )
        elif alert.alert_type is AlertType.TARGET_REACHED:
            verdict = Verdict.BUY_NOW
            headline = "Precio objetivo alcanzado: {origen} a {destino} por {precio_actual}"
            body = (
                "Pediste aviso a {precio_referencia} y ya está en {precio_actual} "
                "para el {fecha_salida} en {cabina}."
            )
        else:
            at_minimum = stats is not None and alert.current_price.amount_minor <= stats.minimum.amount_minor
            if at_minimum or alert.drop_basis_points >= 2000:
                verdict = Verdict.BUY_NOW
                headline = "Buen momento para comprar {origen} a {destino}: {precio_actual}"
            elif alert.drop_basis_points >= 1000:
                verdict = Verdict.CONSIDER
                headline = "Bajada interesante de {origen} a {destino}: {precio_actual}"
            else:
                verdict = Verdict.WAIT
                headline = "Ligera bajada de {origen} a {destino}: {precio_actual}"
            body = (
                "El vuelo del {fecha_salida} en {cabina} ha bajado un {bajada_porcentaje} "
                "desde {precio_referencia}."
            )
        body += history

        # Las plantillas pasan el mismo control que el LLM: si alguien edita
        # una y mete una cifra o un hueco inexistente, los tests lo detectan.
        problems = grounding_problems([headline, body], facts)
        if problems:
            raise AssertionError(f"plantilla de reglas inválida: {problems}")
        return self._build(
            alert,
            facts,
            verdict=verdict,
            headline=render(headline, facts),
            body=render(body, facts),
            source="rules",
        )

    def _build(
        self,
        alert: FareAlert,
        facts: dict[str, str],
        *,
        verdict: Verdict,
        headline: str,
        body: str,
        source: str,
        model: str = "",
    ) -> Recommendation:
        return Recommendation.model_validate(
            {
                "alert_id": alert.alert_id,
                "user_id": alert.user_id,
                "verdict": verdict,
                "headline": headline,
                "body": body,
                "source": source,
                "model": model,
                "facts": facts,
                "booking_deep_link": alert.booking_deep_link,
                "correlation_id": alert.correlation_id,
                "alert_occurred_at": alert.occurred_at,
                "created_at": self._clock(),
            }
        )
