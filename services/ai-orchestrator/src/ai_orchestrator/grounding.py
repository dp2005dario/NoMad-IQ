"""Anclaje a datos reales ("grounding"): el LLM no puede inventar cifras.

El problema (riesgo nº 3 de la revisión):
    Si le pides a un modelo "recomienda este vuelo", puede escribir "cuesta
    389 €" cuando cuesta 412 €, o inventarse una fecha. Lo dice con total
    seguridad. Eso es una "alucinación", y con dinero es inaceptable.

La solución, en dos partes:
    1. Los datos salen SIEMPRE de nuestras fuentes (la alerta de Kafka y el
       historial de precios de PostgreSQL). Aquí los convertimos en "hechos"
       con nombre: {precio_actual} = "412,00 EUR".
    2. El modelo NO escribe cifras. Escribe huecos con el nombre del hecho,
       por ejemplo "Ahora cuesta {precio_actual}, frente a {precio_mediano}".
       Nosotros rellenamos los huecos con el valor real.

    Una comprobación automática rechaza cualquier respuesta que contenga un
    dígito escrito a mano o un hueco que no existe. Analogía: el modelo es un
    redactor que escribe la carta, pero los importes los pone contabilidad
    con un sello. El redactor no puede tocar los números.
"""

from __future__ import annotations

import re
from collections.abc import Mapping, Sequence

from ai_orchestrator.domain import AlertType, Cabin, FareAlert, PriceStats

# Un hueco es {nombre_en_minusculas}. Los nombres pueden llevar números
# (precio_minimo_30d no, pero dejamos la puerta abierta), por eso se quitan
# ANTES de buscar dígitos sueltos.
PLACEHOLDER = re.compile(r"\{([a-z][a-z0-9_]*)\}")
_DIGIT = re.compile(r"\d")

_CABIN_ES = {
    Cabin.ECONOMY: "turista",
    Cabin.PREMIUM_ECONOMY: "turista superior",
    Cabin.BUSINESS: "business",
    Cabin.FIRST: "primera",
}
_ALERT_ES = {
    AlertType.PRICE_DROP: "bajada de precio",
    AlertType.ERROR_FARE: "posible tarifa error",
    AlertType.TARGET_REACHED: "precio objetivo alcanzado",
}
_MONTHS_ES = (
    "enero", "febrero", "marzo", "abril", "mayo", "junio",
    "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
)  # fmt: skip


def _percent(basis_points: int) -> str:
    # 2537 puntos básicos -> "25,37 %" (enteros: sin errores de redondeo).
    whole, frac = divmod(basis_points, 100)
    return f"{whole},{frac:02d} %"


def build_facts(alert: FareAlert, stats: PriceStats | None) -> dict[str, str]:
    """Hechos verificados que el texto puede citar, ya formateados para leer."""
    d = alert.departure_date
    facts = {
        "origen": alert.origin,
        "destino": alert.destination,
        "fecha_salida": f"{d.day} de {_MONTHS_ES[d.month - 1]} de {d.year}",
        "cabina": _CABIN_ES[alert.cabin],
        "tipo_alerta": _ALERT_ES[alert.alert_type],
        "precio_actual": alert.current_price.display(),
        "precio_referencia": alert.reference_price.display(),
        "bajada_porcentaje": _percent(alert.drop_basis_points),
    }
    # Solo usamos el historial si está en la MISMA divisa: comparar euros con
    # dólares sin convertir sería otra forma de inventar.
    if stats is not None and stats.median.currency == alert.current_price.currency:
        facts |= {
            "dias_historial": str(stats.window_days),
            "muestras_historial": str(stats.samples),
            "precio_minimo_historial": stats.minimum.display(),
            "precio_maximo_historial": stats.maximum.display(),
            "precio_mediano_historial": stats.median.display(),
        }
    return facts


def grounding_problems(texts: Sequence[str], allowed: Mapping[str, str]) -> list[str]:
    """Lista de motivos por los que un texto NO está bien anclado (vacía = OK)."""
    problems: list[str] = []
    for text in texts:
        unknown = sorted({name for name in PLACEHOLDER.findall(text) if name not in allowed})
        if unknown:
            problems.append(f"usa huecos que no existen: {', '.join('{' + u + '}' for u in unknown)}")
        without_placeholders = PLACEHOLDER.sub("", text)
        if _DIGIT.search(without_placeholders):
            problems.append("contiene cifras escritas a mano; usa solo los huecos {nombre} de la lista")
        if "{" in without_placeholders or "}" in without_placeholders:
            problems.append("tiene llaves sueltas que no forman un hueco válido")
    # Sin duplicados, conservando el orden.
    return list(dict.fromkeys(problems))


def render(text: str, facts: Mapping[str, str]) -> str:
    """Sustituye cada {hueco} por su valor real. Requiere texto ya validado."""
    return PLACEHOLDER.sub(lambda m: facts[m.group(1)], text)
