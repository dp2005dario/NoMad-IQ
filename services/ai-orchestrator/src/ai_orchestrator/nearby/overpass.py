"""La pregunta a Overpass para "Cerca de ti" (agua, baños, wifi, enchufes y
sitios que ver) y cómo se lee la respuesta."""

from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Any

import httpx

from ai_orchestrator.atms.overpass import OverpassBusyError, OverpassError, as_urls, post_query
from ai_orchestrator.nearby.domain import NearbySpot, SpotKind
from ai_orchestrator.places.wikimedia import RateLimiter

# Como mucho estos sitios por consulta (un centro histórico tiene cientos de
# fuentes y bancos: con esto la respuesta nunca pesa demasiado).
MAX_RESULTS = 400
# Tiendas, bares, súper, farmacias, cajeros... (como en Google Maps): van
# aparte y solo en ~1 km alrededor, con su propio tope, para que en una
# ciudad no se coman los demás sitios (agua, baños, monumentos...).
MAX_SHOPS = 250
SHOP_HALF_LAT = 0.009
SHOP_HALF_LON = 0.012
_QID = re.compile(r"^Q[1-9][0-9]{0,11}$")
# Un teléfono: solo dígitos, espacios, +, -, paréntesis y puntos.
_PHONE = re.compile(r"^\+?[0-9 ()./-]{6,24}$")
_RESERVATION = ("yes", "required", "recommended")
# Comer y beber, para la clase "food" de las tiendas.
_FOOD = ("restaurant", "cafe", "fast_food", "bar", "pub", "ice_cream", "food_court", "biergarten")
_MONEY = ("atm", "bank", "bureau_de_change")
_SUB = re.compile(r"^[a-z][a-z_0-9]{0,23}$")
# Tipos de alojamiento que buscamos para "Viajo con mi perro".
_STAYS = ("hotel", "apartment", "guest_house", "hostel", "motel")
# Qué tipo de sitio que ver es (para el icono de la app).
_SIGHT_SUBS = (
    "museum",
    "gallery",
    "viewpoint",
    "attraction",
    "artwork",
    "monument",
    "castle",
    "memorial",
    "ruins",
    "archaeological_site",
)
# Las zonas de OSM tienen el número de su relación + 3 600 000 000.
_AREA_BASE = 3_600_000_000


def build_query(south: float, west: float, north: float, east: float) -> str:
    """La consulta. Los números con formato fijo: nunca entra texto raro."""
    box = f"{south:.5f},{west:.5f},{north:.5f},{east:.5f}"
    return (
        "[out:json][timeout:25];("
        f'nwr["amenity"="drinking_water"]({box});'
        f'nwr["amenity"="toilets"]["access"!~"private|customers|no"]({box});'
        f'nwr["internet_access"="wlan"]["internet_access:fee"="no"]({box});'
        f'nwr["amenity"="device_charging_station"]({box});'
        # Sitios que ver: solo los que tienen Wikidata (los conocidos).
        f'nwr["tourism"~"^(attraction|viewpoint|museum|gallery|artwork)$"]["wikidata"]({box});'
        f'nwr["historic"~"^(monument|castle|memorial|ruins|archaeological_site)$"]["wikidata"]({box});'
        # Parques y templos conocidos (con Wikidata): se visitan gratis.
        f'nwr["leisure"="park"]["name"]["wikidata"]({box});'
        f'nwr["amenity"="place_of_worship"]["name"]["wikidata"]({box});'
        # Restaurantes que aceptan reserva y dicen cómo (web o teléfono).
        f'nwr["amenity"="restaurant"]["reservation"~"^(yes|required|recommended)$"]["name"]'
        f'["website"]({box});'
        f'nwr["amenity"="restaurant"]["reservation"~"^(yes|required|recommended)$"]["name"]'
        f'["phone"]({box});'
        # Para tu perro: veterinarios, parques para perros y alojamientos
        # que en OpenStreetMap ponen "dog=yes" (admiten perros).
        f'nwr["amenity"="veterinary"]({box});'
        f'nwr["leisure"="dog_park"]({box});'
        f'nwr["tourism"~"^(hotel|apartment|guest_house|hostel|motel)$"]["dog"~"^(yes|leashed)$"]["name"]({box});'
        f");out center {MAX_RESULTS};"
        # Lo de "como en Google Maps": todo lo que tiene nombre y se puede
        # visitar (tiendas, bares, súper, farmacias, cajeros), en ~1 km.
        f"({_shop_lines(south, west, north, east)});out center {MAX_SHOPS};"
        # Y en qué ciudad y barrio cae el centro de la zona (para la cabecera
        # "Madrid · Centro"): las zonas administrativas que lo contienen.
        f"is_in({(south + north) / 2:.5f},{(west + east) / 2:.5f})->.z;"
        'area.z["boundary"="administrative"]["admin_level"~"^(8|9|10)$"]["name"];out tags;'
    )


def _shop_lines(south: float, west: float, north: float, east: float) -> str:
    lat, lon = (south + north) / 2, (west + east) / 2
    box = (
        f"{lat - SHOP_HALF_LAT:.5f},{lon - SHOP_HALF_LON:.5f},"
        f"{lat + SHOP_HALF_LAT:.5f},{lon + SHOP_HALF_LON:.5f}"
    )
    return (
        f'nwr["shop"]["name"]({box});'
        f'nwr["amenity"~"^({"|".join(_FOOD)})$"]["name"]({box});'
        f'nwr["amenity"~"^(pharmacy|marketplace|post_office|library|cinema|theatre)$"]["name"]({box});'
        f'nwr["amenity"~"^({"|".join(_MONEY)})$"]({box});'
    )


def _shop_sub(tags: dict[str, Any]) -> str:
    """Qué es exactamente ("supermarket", "cafe", "atm", "clothes"...).

    La app lo agrupa para el icono y lo traduce para la tarjeta. Solo letras
    minúsculas, números y "_" (como mucho 24): nada de texto raro.
    """
    amenity, shop = tags.get("amenity"), tags.get("shop")
    raw = amenity if isinstance(amenity, str) and amenity and shop is None else shop
    if isinstance(raw, str) and _SUB.match(raw):
        return raw
    return "shop"


def _text(tags: dict[str, Any], key: str, limit: int = 80) -> str | None:
    value = tags.get(key)
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value[:limit] or None


def _https(tags: dict[str, Any]) -> str | None:
    """La web, solo si es https (nada de enlaces raros en la app)."""
    for key in ("website", "contact:website"):
        url = _text(tags, key, 300)
        if url is not None and url.startswith("https://") and " " not in url:
            return url
    return None


def _phone(tags: dict[str, Any]) -> str | None:
    for key in ("phone", "contact:phone"):
        # A veces hay varios separados por ";": nos quedamos con el primero.
        raw = _text(tags, key, 120)
        first = raw.split(";")[0].strip() if raw else None
        if first and _PHONE.match(first):
            return first
    return None


def _kind(tags: dict[str, Any]) -> SpotKind | None:
    amenity = tags.get("amenity")
    if amenity == "restaurant" and tags.get("reservation") in _RESERVATION:
        return "table"
    if amenity == "drinking_water":
        return "water"
    if amenity == "toilets":
        return "toilets"
    if amenity == "device_charging_station":
        return "charging"
    if amenity == "veterinary":
        return "vet"
    if tags.get("leisure") == "dog_park":
        return "dog_park"
    # Va antes que "sight": un hotel con perro no es un sitio que ver.
    if tags.get("tourism") in _STAYS and tags.get("dog") in ("yes", "leashed"):
        return "pet_stay"
    if tags.get("internet_access") == "wlan" and tags.get("internet_access:fee") == "no":
        return "wifi"
    if tags.get("tourism") or tags.get("historic"):
        return "sight"
    if tags.get("leisure") == "park" or amenity == "place_of_worship":
        return "sight"
    if (
        tags.get("shop")
        or amenity in _FOOD
        or amenity in _MONEY
        or amenity in ("pharmacy", "marketplace", "post_office", "library", "cinema", "theatre")
    ):
        return "shop"
    return None


def _sight_sub(tags: dict[str, Any]) -> str | None:
    """museum, viewpoint, park, worship...: qué clase de sitio que ver es."""
    for key in ("tourism", "historic"):
        value = tags.get(key)
        if value in _SIGHT_SUBS:
            return str(value)
    if tags.get("leisure") == "park":
        return "park"
    if tags.get("amenity") == "place_of_worship":
        return "worship"
    return None


def parse_place(row: Any, lat: float, lon: float) -> NearbySpot | None:
    """Una zona administrativa (ciudad, distrito, barrio) como "place".

    sub = su admin_level ("8" ciudad, "9" distrito, "10" barrio)."""
    if not isinstance(row, dict) or row.get("type") != "area":
        return None
    oid = row.get("id")
    raw_tags = row.get("tags")
    if not isinstance(oid, int) or oid <= _AREA_BASE or not isinstance(raw_tags, dict):
        return None
    name = _text(raw_tags, "name")
    level = raw_tags.get("admin_level")
    if name is None or level not in ("8", "9", "10"):
        return None
    return NearbySpot(id=f"r{oid - _AREA_BASE}", kind="place", lat=lat, lon=lon, name=name, sub=level)


def parse_spot(row: Any) -> NearbySpot | None:
    """Un sitio de la respuesta, o None si le falta algo."""
    if not isinstance(row, dict):
        return None
    kind_raw, oid = row.get("type"), row.get("id")
    if kind_raw not in ("node", "way", "relation") or not isinstance(oid, int) or oid <= 0:
        return None
    where = row if kind_raw == "node" else row.get("center")
    if not isinstance(where, dict):
        return None
    lat, lon = where.get("lat"), where.get("lon")
    if not (
        isinstance(lat, int | float)
        and isinstance(lon, int | float)
        and -90 <= lat <= 90
        and -180 <= lon <= 180
    ):
        return None
    raw_tags = row.get("tags")
    tags: dict[str, Any] = raw_tags if isinstance(raw_tags, dict) else {}
    kind = _kind(tags)
    if kind is None:
        return None
    qid = tags.get("wikidata")
    name = _text(tags, "name")
    if kind == "sight" and (name is None or not isinstance(qid, str) or not _QID.match(qid)):
        return None  # un "sitio que ver" sin nombre ni Wikidata no sirve
    if kind == "pet_stay" and name is None:
        return None  # un hotel sin nombre no se puede buscar ni reservar
    if kind in ("vet", "pet_stay"):
        # Veterinarios y hoteles: su web y teléfono, para llamar o reservar.
        return NearbySpot(
            id=f"{kind_raw[0]}{oid}",
            kind=kind,
            lat=float(lat),
            lon=float(lon),
            name=name,
            opening_hours=_text(tags, "opening_hours"),
            website=_https(tags),
            phone=_phone(tags),
        )
    if kind == "shop":
        if name is None and tags.get("amenity") not in _MONEY:
            return None  # una tienda sin nombre no se puede buscar
        return NearbySpot(
            id=f"{kind_raw[0]}{oid}",
            kind=kind,
            lat=float(lat),
            lon=float(lon),
            name=name or _text(tags, "operator") or _text(tags, "brand"),
            opening_hours=_text(tags, "opening_hours"),
            website=_https(tags),
            phone=_phone(tags),
            cuisine=_text(tags, "cuisine", 40),
            sub=_shop_sub(tags),
        )
    if kind == "table":
        website, phone = _https(tags), _phone(tags)
        if name is None or (website is None and phone is None):
            return None  # sin nombre o sin forma de reservar, no sirve
        return NearbySpot(
            id=f"{kind_raw[0]}{oid}",
            kind=kind,
            lat=float(lat),
            lon=float(lon),
            name=name,
            opening_hours=_text(tags, "opening_hours"),
            website=website,
            phone=phone,
            cuisine=_text(tags, "cuisine", 40),
            reservation=tags.get("reservation"),
        )
    fee = tags.get("fee")
    return NearbySpot(
        id=f"{kind_raw[0]}{oid}",
        kind=kind,
        lat=float(lat),
        lon=float(lon),
        name=name,
        opening_hours=_text(tags, "opening_hours"),
        fee=True if fee == "yes" else False if fee == "no" else None,
        wikidata_id=qid if kind == "sight" else None,
        sub=_sight_sub(tags) if kind == "sight" else None,
    )


class NearbyOverpass:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        limiter: RateLimiter,
        url: str | Sequence[str],
        max_wait_seconds: float = 2.0,
    ) -> None:
        self._http = http
        self._limiter = limiter
        self._urls = as_urls(url)
        self._max_wait = max_wait_seconds

    async def spots_in(self, south: float, west: float, north: float, east: float) -> list[NearbySpot]:
        await self._limiter.acquire(self._max_wait)
        resp = await post_query(self._http, self._urls, build_query(south, west, north, east))
        if resp.status_code in (429, 503, 504):
            raise OverpassBusyError(f"Overpass respondió {resp.status_code}")
        if resp.status_code != 200:
            raise OverpassError(f"Overpass respondió {resp.status_code}")
        try:
            data = resp.json()
        except ValueError as exc:
            raise OverpassError("respuesta de Overpass que no es JSON") from exc
        rows = data.get("elements") if isinstance(data, dict) else None
        if not isinstance(rows, list):
            raise OverpassError("respuesta de Overpass sin lista de elementos")
        seen: set[str] = set()
        out: list[NearbySpot] = []
        mid_lat, mid_lon = round((south + north) / 2, 5), round((west + east) / 2, 5)
        places = [p for p in (parse_place(r, mid_lat, mid_lon) for r in rows) if p is not None]
        for spot in [*(parse_spot(r) for r in rows), *places]:
            if spot is not None and spot.id not in seen:
                seen.add(spot.id)
                out.append(spot)
        return out[: MAX_RESULTS + MAX_SHOPS]
