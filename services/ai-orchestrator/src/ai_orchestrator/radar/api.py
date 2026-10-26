"""API HTTP del radar local (se monta dentro de api.create_api).

    GET    /v1/radar/{city}              avisos y precios de una ciudad
    POST   /v1/radar/{city}/scams        avisar de un timo (uno por tipo)
    DELETE /v1/radar/{city}/scams/{cat}  quitar mi aviso
    POST   /v1/radar/{city}/prices       apuntar lo que he pagado

Todo con sesión iniciada (así cada aviso es de una persona distinta). La
ciudad va por código de aeropuerto: el servidor nunca sabe dónde estás, y
nunca se devuelve quién avisó.
"""

from __future__ import annotations

from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path
from pydantic import BaseModel, ConfigDict, Field

from ai_orchestrator.identity import Principal, current_principal
from ai_orchestrator.places.airports import Airports
from ai_orchestrator.radar.domain import CityRadar, PriceItem, RadarLimitError, ScamCategory
from ai_orchestrator.radar.store import RadarStore

PREFIX = "/v1/radar"
City = Annotated[str, Path(pattern=r"^[A-Z]{3}$")]


class ScamBody(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    category: ScamCategory


class PriceBody(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    item: PriceItem
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    amount: Decimal = Field(gt=0, lt=10_000_000, max_digits=12, decimal_places=2)


def radar_router(store: RadarStore, airports: Airports) -> APIRouter:
    router = APIRouter(prefix=PREFIX)

    def known_city(city: str) -> str:
        # Solo ciudades con aeropuerto: nadie llena la tabla de "ciudades".
        if airports.get(city) is None:
            raise HTTPException(status_code=404, detail="ciudad desconocida")
        return city

    @router.get("/{city}", response_model=CityRadar)
    async def city_radar(
        principal: Annotated[Principal, Depends(current_principal)], city: City
    ) -> CityRadar:
        return await store.city(known_city(city), principal.user_id)

    @router.post("/{city}/scams", status_code=204)
    async def report(
        principal: Annotated[Principal, Depends(current_principal)], city: City, body: ScamBody
    ) -> None:
        try:
            await store.report_scam(known_city(city), principal.user_id, body.category)
        except RadarLimitError as exc:
            raise HTTPException(status_code=429, detail="demasiados avisos hoy") from exc

    @router.delete("/{city}/scams/{category}", status_code=204)
    async def withdraw(
        principal: Annotated[Principal, Depends(current_principal)], city: City, category: ScamCategory
    ) -> None:
        await store.withdraw_scam(known_city(city), principal.user_id, category)

    @router.post("/{city}/prices", status_code=204)
    async def price(
        principal: Annotated[Principal, Depends(current_principal)], city: City, body: PriceBody
    ) -> None:
        try:
            await store.add_price(known_city(city), principal.user_id, body.item, body.currency, body.amount)
        except RadarLimitError as exc:
            raise HTTPException(status_code=429, detail="demasiados precios hoy") from exc

    return router
