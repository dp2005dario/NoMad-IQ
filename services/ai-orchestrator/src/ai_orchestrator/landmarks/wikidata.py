"""Las preguntas a Wikidata para el modo cámara.

Wikidata es una enciclopedia de DATOS (no de textos): cada lugar tiene un
identificador ("Q123") con sus coordenadas, su foto, cuándo se construyó...
Le preguntamos "¿qué lugares conocidos hay a menos de X metros de aquí?".

Seguridad: en las consultas solo metemos números que hemos validado y
formateado nosotros (coordenadas, radio) o identificadores que cumplen un
patrón estricto. Nunca texto que escribe la persona.
"""

from __future__ import annotations

import re
from typing import Any

from ai_orchestrator.landmarks.domain import Candidate
from ai_orchestrator.places.wikimedia import QID_PATTERN, WikimediaClient, commons_photo

# Lo que NO es un monumento aunque esté en Wikidata con coordenadas: barrios,
# pueblos, calles, estaciones de metro, empresas y paradas de autobús.
_NOT_LANDMARKS = ("Q56061", "Q486972", "Q123705", "Q79007", "Q928830", "Q4830453", "Q953806")
# Lugares con al menos esta cantidad de Wikipedias: quita lo muy local.
MIN_SITELINKS = 2
MAX_CANDIDATES = 40
PHOTO_WIDTH = 640

_FIELDS = """?item ?itemLabel ?itemDescription ?loc ?image ?inception ?article ?sl"""


def _filters(lang: str) -> str:
    excluded = " ".join(f"wd:{q}" for q in _NOT_LANDMARKS)
    return f"""  ?item wikibase:sitelinks ?sl .
  FILTER NOT EXISTS {{ ?item wdt:P31 wd:Q5 . }}
  FILTER NOT EXISTS {{ VALUES ?no {{ {excluded} }} ?item wdt:P31/wdt:P279* ?no . }}
  OPTIONAL {{ ?item wdt:P18 ?image . }}
  OPTIONAL {{ ?item wdt:P571 ?inception . }}
  OPTIONAL {{ ?article schema:about ?item ; schema:isPartOf <https://{lang}.wikipedia.org/> . }}
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}"""


def nearby_query(lat: float, lon: float, radius_km: float, lang: str) -> str:
    _check_lang(lang)
    return f"""SELECT {_FIELDS} WHERE {{
  SERVICE wikibase:around {{
    ?item wdt:P625 ?loc .
    bd:serviceParam wikibase:center "Point({lon:.5f} {lat:.5f})"^^geo:wktLiteral .
    bd:serviceParam wikibase:radius "{radius_km:.3f}" .
  }}
{_filters(lang)}
  FILTER(?sl >= {MIN_SITELINKS})
}} ORDER BY DESC(?sl) LIMIT {MAX_CANDIDATES * 3}"""


def item_query(qid: str, lang: str) -> str:
    _check_lang(lang)
    if not QID_PATTERN.match(qid):
        raise ValueError(f"identificador de Wikidata inválido: {qid!r}")
    return f"""SELECT {_FIELDS} WHERE {{
  VALUES ?item {{ wd:{qid} }}
  ?item wdt:P625 ?loc .
{_filters(lang)}
}} LIMIT 20"""


def _check_lang(lang: str) -> None:
    if not re.fullmatch(r"[a-z]{2,3}", lang):
        raise ValueError(f"idioma inválido: {lang!r}")


def _cell(row: dict[str, Any], name: str) -> str | None:
    cell = row.get(name)
    if not isinstance(cell, dict):
        return None
    value = cell.get("value")
    return value if isinstance(value, str) and value else None


_POINT = re.compile(r"^Point\((-?[0-9.]+) (-?[0-9.]+)\)$")
_YEAR = re.compile(r"^(-?)0*([0-9]{1,4})-")


def parse_rows(rows: list[dict[str, Any]]) -> list[Candidate]:
    """Filas de SPARQL -> candidatos (uno por lugar, aunque tenga 3 fotos)."""
    seen: set[str] = set()
    out: list[Candidate] = []
    for row in rows:
        qid = (_cell(row, "item") or "").rsplit("/", 1)[-1]
        name = _cell(row, "itemLabel")
        point = _POINT.match(_cell(row, "loc") or "")
        # Sin nombre en ningún idioma, Wikidata devuelve el propio "Q123".
        if not QID_PATTERN.match(qid) or qid in seen or not name or QID_PATTERN.match(name) or not point:
            continue
        seen.add(qid)
        image = _cell(row, "image")
        year_match = _YEAR.match(_cell(row, "inception") or "")
        year = None
        if year_match:
            year = int(year_match.group(2)) * (-1 if year_match.group(1) else 1)
        try:
            sitelinks = int(_cell(row, "sl") or "0")
        except ValueError:
            sitelinks = 0
        out.append(
            Candidate(
                qid=qid,
                name=name[:120],
                description=(_cell(row, "itemDescription") or None),
                lon=float(point.group(1)),
                lat=float(point.group(2)),
                year=year,
                photo=commons_photo(image, PHOTO_WIDTH) if image else None,
                article_url=_cell(row, "article"),
                sitelinks=sitelinks,
            )
        )
        if len(out) >= MAX_CANDIDATES:
            break
    return out


class LandmarkSource:
    """Busca lugares cerca y la ficha de uno, con el cliente de Wikimedia."""

    def __init__(self, wikimedia: WikimediaClient) -> None:
        self._wm = wikimedia

    async def nearby(self, lat: float, lon: float, radius_m: int, lang: str) -> list[Candidate]:
        return parse_rows(await self._wm.sparql(nearby_query(lat, lon, radius_m / 1000, lang)))

    async def item(self, qid: str, lang: str) -> Candidate | None:
        found = parse_rows(await self._wm.sparql(item_query(qid, lang)))
        return found[0] if found else None

    async def summary(self, article_url: str) -> str | None:
        result = await self._wm.summary(article_url)
        return result[0] if result else None
