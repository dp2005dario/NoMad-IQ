"""Tipos de dominio: el "vocabulario" del servicio, con sus reglas.

¿Qué es Pydantic?
    Una librería que comprueba los datos al crearlos. Si declaras que un
    importe es un entero mayor que cero y alguien intenta crear uno con -5,
    Pydantic lanza un error en ese mismo momento. Es como un portero que
    revisa cada dato en la puerta: lo que está dentro ya es de fiar.

``frozen=True`` hace los objetos inmutables (no se pueden modificar después
de crearlos). Así nadie cambia por accidente un precio a mitad de camino.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
from decimal import Decimal
from enum import StrEnum
from typing import Annotated, Literal, Self

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, model_validator

# Códigos IATA de aeropuerto: 3 letras mayúsculas ("MAD", "NRT").
IataCode = Annotated[str, Field(pattern=r"^[A-Z]{3}$")]
# Divisa ISO 4217: 3 letras mayúsculas ("EUR").
CurrencyCode = Annotated[str, Field(pattern=r"^[A-Z]{3}$")]
# Identificador de usuario tal y como lo emite el auth-gateway (un UUID),
# acotado igual que en la base de datos del price-consumer.
UserId = Annotated[str, Field(min_length=1, max_length=128)]


def _canonical_uuid(value: str) -> str:
    # Normaliza "ABC-..." y "abc-..." a la misma forma: así no cuentan como
    # dos alertas distintas.
    return str(uuid.UUID(value))


UuidStr = Annotated[str, AfterValidator(_canonical_uuid)]


def _https_or_empty(value: str) -> str:
    # El enlace de reserva se mostrará al usuario: solo https, nada de
    # "javascript:" ni http en claro.
    if value and not value.startswith("https://"):
        raise ValueError("el enlace de reserva debe ser https")
    return value


class Cabin(StrEnum):
    ECONOMY = "ECONOMY"
    PREMIUM_ECONOMY = "PREMIUM_ECONOMY"
    BUSINESS = "BUSINESS"
    FIRST = "FIRST"


class AlertType(StrEnum):
    PRICE_DROP = "PRICE_DROP"
    ERROR_FARE = "ERROR_FARE"
    TARGET_REACHED = "TARGET_REACHED"


class Verdict(StrEnum):
    """Lo que le aconsejamos al usuario. Pocas opciones, cerradas: el LLM no
    puede inventarse una cuarta."""

    BUY_NOW = "BUY_NOW"  # compra ya
    CONSIDER = "CONSIDER"  # buen precio, sin urgencia
    WAIT = "WAIT"  # mejor esperar


# Divisas sin decimales (100 JPY son 100 yenes, no 1,00). Para el resto, 2.
_ZERO_DECIMAL_CURRENCIES = frozenset({"JPY", "KRW", "CLP", "ISK", "VND", "XOF", "XAF"})


class Money(BaseModel):
    """Dinero en la unidad mínima (céntimos), igual que en los contratos proto.

    Nunca usamos float para dinero: 0.1 + 0.2 da 0.30000000000000004.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    currency: CurrencyCode
    amount_minor: int = Field(gt=0)

    def display(self) -> str:
        """Formato legible en español: 129,99 EUR."""
        digits = 0 if self.currency in _ZERO_DECIMAL_CURRENCIES else 2
        value = Decimal(self.amount_minor).scaleb(-digits)
        # f"{value:,.2f}" da "1,234.50"; lo pasamos a "1.234,50" (estilo español).
        text = f"{value:,.{digits}f}".replace(",", "_").replace(".", ",").replace("_", ".")
        return f"{text} {self.currency}"


class FareAlert(BaseModel):
    """Una alerta de chollo, ya leída de Kafka y validada."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    alert_id: UuidStr
    user_id: UserId
    alert_type: AlertType
    watch_id: str = Field(default="", max_length=128)
    origin: IataCode
    destination: IataCode
    departure_date: date
    cabin: Cabin
    reference_price: Money
    current_price: Money
    # Bajada en puntos básicos: 2500 = 25,00 %. Entero para evitar flotantes.
    drop_basis_points: int = Field(ge=0, le=10_000)
    booking_deep_link: Annotated[str, AfterValidator(_https_or_empty)] = Field(default="", max_length=2048)
    correlation_id: str = Field(default="", max_length=128)
    occurred_at: datetime

    @model_validator(mode="after")
    def _consistent(self) -> Self:
        if self.origin == self.destination:
            raise ValueError("origen y destino no pueden ser el mismo aeropuerto")
        if self.reference_price.currency != self.current_price.currency:
            raise ValueError("precio actual y de referencia deben ir en la misma divisa")
        if self.occurred_at.tzinfo is None:
            raise ValueError("occurred_at debe llevar zona horaria")
        return self


class PriceStats(BaseModel):
    """Resumen del historial real de precios de una ruta (sale de PostgreSQL)."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    window_days: int = Field(gt=0)
    samples: int = Field(gt=0)
    minimum: Money
    maximum: Money
    median: Money


class KnowledgeSnippet(BaseModel):
    """Un fragmento de conocimiento recuperado de Qdrant (por ejemplo, una
    nota sobre el destino). Se le pasa al LLM como contexto, con su fuente."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    text: str = Field(min_length=1)
    source: str = Field(default="desconocida", max_length=200)
    score: float


class Recommendation(BaseModel):
    """Lo que guardamos y servimos al usuario por cada alerta."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    alert_id: UuidStr
    user_id: UserId
    verdict: Verdict
    headline: str = Field(min_length=1, max_length=300)
    body: str = Field(min_length=1, max_length=2000)
    # "llm" = redactada por el modelo; "rules" = plan B determinista (sin IA).
    source: Literal["llm", "rules"]
    model: str = ""
    # Los datos reales que respaldan el texto (precio, fechas...), tal cual.
    facts: dict[str, str]
    booking_deep_link: str = ""
    correlation_id: str = ""
    alert_occurred_at: datetime
    created_at: datetime
