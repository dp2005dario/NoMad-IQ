"""Las fiestas y festivales famosos de una ciudad (San Fermín, las Fallas,
el Carnaval de Río, la Oktoberfest...), de Wikidata: gratis, sin clave y de
todo el mundo.

Dos tipos:

- Los que se repiten cada año en un MES (Wikidata "month of the year"):
  se enseñan si tus fechas tocan ese mes, con ``month_only`` (la app dice
  "en julio", no un día que no sabemos).
- Los que tienen fecha (un partido, una edición concreta): con su día.

Solo los conocidos: con artículo en al menos 3 Wikipedias. Se guarda 30 días
por aeropuerto e idioma (las fiestas de una ciudad casi no cambian).
"""

from __future__ import annotations

import re
from datetime import date
from typing import Any

import httpx

from ai_orchestrator.city_events.domain import CityEvent
from ai_orchestrator.city_events.sources import SourceBusyError, SourceError

WDQS_URL = "https://query.wikidata.org/sparql"
USER_AGENT = "ECLIPTA/1.0 (travel app; city festivals) python-httpx"
RADIUS_KM = 20
# Con artículo en tantas Wikipedias = "famoso"; con muchas más, de los top.
MIN_SITELINKS = 3
TOP_SITELINKS = 25
# Los meses en Wikidata (enero = Q108 ... diciembre = Q126).
MONTHS = {
    "Q108": 1, "Q109": 2, "Q110": 3, "Q118": 4, "Q119": 5, "Q120": 6,
    "Q121": 7, "Q122": 8, "Q123": 9, "Q124": 10, "Q125": 11, "Q126": 12,
}  # fmt: skip
# Fiesta, festival de música, de cine, carnaval, evento que se repite,
# evento deportivo y evento en general.
CLASSES = ("Q132241", "Q868557", "Q220505", "Q4618", "Q15275719", "Q16510064", "Q1656682")
_QID = re.compile(r"/entity/(Q[1-9][0-9]{0,11})$")
_LANG = re.compile(r"^[a-z]{2,3}$")


def build_query(lat: float, lon: float, lang: str) -> str:
    """La consulta SPARQL. Números con formato fijo e idioma validado."""
    if not _LANG.match(lang):
        raise ValueError("idioma no válido")
    values = " ".join(f"wd:{c}" for c in CLASSES)
    point = f'"Point({lon:.4f} {lat:.4f})"^^geo:wktLiteral'
    return f"""SELECT ?item ?itemLabel ?month ?start ?when ?links ?article WHERE {{
  {{ SERVICE wikibase:around {{ ?item wdt:P625 ?loc. bd:serviceParam wikibase:center {point};
       wikibase:radius "{RADIUS_KM}". }} }}
  UNION
  {{ SERVICE wikibase:around {{ ?place wdt:P625 ?ploc. bd:serviceParam wikibase:center {point};
       wikibase:radius "{RADIUS_KM}". }}
     ?item wdt:P276|wdt:P131 ?place. }}
  VALUES ?cls {{ {values} }}
  ?item wdt:P31/wdt:P279? ?cls.
  ?item wikibase:sitelinks ?links. FILTER(?links >= {MIN_SITELINKS})
  OPTIONAL {{ ?item wdt:P2922 ?month. }}
  OPTIONAL {{ ?item wdt:P580 ?start. }}
  OPTIONAL {{ ?item wdt:P585 ?when. }}
  FILTER(BOUND(?month) || COALESCE(?start, ?when) > "2025-01-01T00:00:00Z"^^xsd:dateTime)
  OPTIONAL {{ ?article schema:about ?item; schema:isPartOf <https://{lang}.wikipedia.org/>. }}
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}
}} LIMIT 400"""


def _value(row: dict[str, Any], key: str) -> str | None:
    cell = row.get(key)
    v = cell.get("value") if isinstance(cell, dict) else None
    return v if isinstance(v, str) else None


def parse_festivals(data: Any) -> list[CityEvent]:
    """Las filas de Wikidata → eventos. Un evento por mes o por fecha.

    Los de un mes llevan como fecha el día 1 de ese mes del año 2000 (solo
    cuenta el mes): el servicio la cambia por la del año de tus fechas.
    """
    rows = data.get("results", {}).get("bindings") if isinstance(data, dict) else None
    if not isinstance(rows, list):
        raise SourceError("respuesta de Wikidata sin resultados")
    out: dict[str, CityEvent] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        qid = _QID.search(_value(row, "item") or "")
        name = (_value(row, "itemLabel") or "").strip()
        if qid is None or not name or name == qid.group(1) or len(name) > 120:
            continue  # sin nombre en ningún idioma: no sirve
        try:
            links = int(_value(row, "links") or "0")
        except ValueError:
            links = 0
        article = _value(row, "article")
        url = article if article and article.startswith("https://") and len(article) < 500 else None
        month_qid = _QID.search(_value(row, "month") or "")
        common = {"kind": "festival", "name": name, "url": url, "top": links >= TOP_SITELINKS}
        if month_qid is not None and month_qid.group(1) in MONTHS:
            month = MONTHS[month_qid.group(1)]
            key = f"w-{qid.group(1)}-m{month}"
            out[key] = CityEvent(id=key, date=date(2000, month, 1), month_only=True, **common)
            continue
        raw = _value(row, "start") or _value(row, "when") or ""
        try:
            day = date.fromisoformat(raw[:10])
        except ValueError:
            continue
        key = f"w-{qid.group(1)}-{day.isoformat()}"
        out[key] = CityEvent(id=key, date=day, **common)
    return list(out.values())


class WikidataFestivals:
    def __init__(self, http: httpx.AsyncClient) -> None:
        self._http = http

    async def festivals(self, lat: float, lon: float, lang: str) -> list[CityEvent]:
        try:
            resp = await self._http.get(
                WDQS_URL,
                params={"query": build_query(lat, lon, lang), "format": "json"},
                headers={"User-Agent": USER_AGENT, "Accept": "application/sparql-results+json"},
            )
        except httpx.HTTPError as exc:
            raise SourceError(f"{type(exc).__name__} al llamar a Wikidata") from exc
        if resp.status_code in (429, 503, 504):
            raise SourceBusyError(f"Wikidata respondió {resp.status_code}")
        if resp.status_code != 200:
            raise SourceError(f"Wikidata respondió {resp.status_code}")
        try:
            return parse_festivals(resp.json())
        except ValueError as exc:
            raise SourceError("respuesta de Wikidata que no es JSON") from exc
