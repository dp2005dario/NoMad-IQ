"""Cliente de Wikidata y Wikipedia (gratis, sin clave).

Cómo se arma una ficha (5 peticiones por ciudad e idioma, y luego 7 días de caché):
    1. ``wbsearchentities``: candidatos de Wikidata con el nombre de la ciudad
       ("Santiago" da muchas: Chile, Compostela, Cuba...).
    2. SPARQL: de esos candidatos, el que está a menos de 80 km del aeropuerto
       y tiene más artículos en Wikipedia (el más conocido). Así "Santiago"
       desde SCL es la de Chile y desde SCQ la de Compostela.
    3. SPARQL: datos de la ciudad (foto, población, país, capital, moneda...).
    4. SPARQL: sus lugares más conocidos con foto.
    5. Wikipedia: el resumen del artículo en el idioma del usuario.

Seguridad: en las consultas SPARQL solo metemos cosas que hemos validado
nosotros (identificadores "Q123", números y un idioma de una lista cerrada),
nunca texto que venga del usuario. El nombre de la ciudad solo viaja como
parámetro de la API de búsqueda, que lo trata como texto.

Normas de Wikimedia: piden un User-Agent que diga quién eres y cómo
contactarte, y no hacer ráfagas. Por eso el limitador (RateLimiter) y la
cabecera WIKIMEDIA_USER_AGENT.
"""

from __future__ import annotations

import asyncio
import hashlib
import re
import time
from collections.abc import Callable
from typing import Any
from urllib.parse import quote, unquote

import httpx

from ai_orchestrator.places.airports import Airport
from ai_orchestrator.places.domain import Attraction, CountryFacts, Photo

QID_PATTERN = re.compile(r"^Q[1-9][0-9]{0,11}$")

WIKIDATA_API = "https://www.wikidata.org/w/api.php"
SPARQL_URL = "https://query.wikidata.org/sparql"

# Distancia máxima entre el aeropuerto y el centro de "su" ciudad. Muchos
# aeropuertos grandes están lejos (Narita a ~60 km de Tokio).
MAX_CITY_KM = 80
# Un lugar necesita artículos en al menos tantas Wikipedias para salir en
# "lo más visitado": filtra rincones que solo conoce el barrio.
MIN_SITELINKS = 10
MAX_ATTRACTIONS = 8
# El resumen de Wikipedia ya es corto; esto es solo un tope de seguridad.
MAX_SUMMARY_CHARS = 1200

# Lo que NO cuenta como "lugar que visitar": barrios y distritos (entidades
# administrativas), asentamientos y personas.
_NOT_ATTRACTIONS = ("Q56061", "Q486972", "Q123705")


class WikimediaBusyError(Exception):
    """Hemos llegado al límite de peticiones (nuestro o de Wikimedia): probar luego."""


class WikimediaError(Exception):
    """Wikimedia no ha contestado bien (caída, tiempo agotado, respuesta rara)."""


class RateLimiter:
    """Cubo de fichas ("token bucket"): como mucho ``rate`` peticiones por
    segundo, con ráfagas de hasta ``burst``.

    Analogía: un dispensador de turnos que repone ``rate`` papelitos por
    segundo. Si no queda ninguno, esperas un poco; si la espera sería
    demasiado larga, mejor decir "vuelve luego" que hacer cola sin fin.
    """

    def __init__(
        self,
        rate: float,
        burst: int,
        *,
        clock: Any = time.monotonic,
        busy: Callable[[], Exception] = lambda: WikimediaBusyError("límite de peticiones a Wikimedia"),
    ) -> None:
        # ``busy`` es el error que se lanza si toca esperar demasiado: así el
        # mismo dispensador sirve para Wikimedia y para Mapillary.
        self._busy = busy
        self._rate = rate
        self._burst = float(burst)
        self._tokens = float(burst)
        self._clock = clock
        self._last = clock()
        self._lock = asyncio.Lock()

    async def acquire(self, max_wait: float) -> None:
        async with self._lock:
            now = self._clock()
            self._tokens = min(self._burst, self._tokens + (now - self._last) * self._rate)
            self._last = now
            if self._tokens >= 1:
                self._tokens -= 1
                return
            wait = (1 - self._tokens) / self._rate
            if wait > max_wait:
                raise self._busy()
            # Reservamos la ficha ya (puede quedar en negativo) y esperamos.
            self._tokens -= 1
        await asyncio.sleep(wait)


def commons_photo(file_url: str, width: int) -> Photo | None:
    """De "…/Special:FilePath/Puerta del Sol.jpg" a la miniatura ya reducida.

    Commons guarda cada archivo en una carpeta que sale del MD5 de su nombre
    ("/a/ab/"). Calcularla nosotros evita una redirección por foto. Formatos
    que no son imagen web (PDF, TIFF…) se descartan.
    """
    name = unquote(file_url.rsplit("/", 1)[-1]).replace(" ", "_")
    ext = name.rsplit(".", 1)[-1].lower() if "." in name else ""
    if not name or ext not in {"jpg", "jpeg", "png", "webp", "gif", "svg"}:
        return None
    digest = hashlib.md5(name.encode("utf-8"), usedforsecurity=False).hexdigest()
    quoted = quote(name, safe="")
    suffix = ".png" if ext == "svg" else ""  # los SVG se sirven convertidos a PNG
    return Photo(
        url=(
            f"https://upload.wikimedia.org/wikipedia/commons/thumb/"
            f"{digest[0]}/{digest[:2]}/{quoted}/{width}px-{quoted}{suffix}"
        ),
        page_url=f"https://commons.wikimedia.org/wiki/File:{quoted}",
    )


def _value(row: dict[str, Any], name: str) -> str | None:
    cell = row.get(name)
    if not isinstance(cell, dict):
        return None
    value = cell.get("value")
    return value if isinstance(value, str) and value else None


def _is_label(value: str | None) -> bool:
    # Si un dato no tiene nombre en ningún idioma, el servicio de etiquetas
    # devuelve su identificador ("Q12345"): eso no se enseña.
    return value is not None and not QID_PATTERN.match(value)


class WikimediaClient:
    def __init__(
        self,
        http: httpx.AsyncClient,
        *,
        limiter: RateLimiter,
        max_wait_seconds: float = 2.0,
        city_photo_width: int = 960,
        attraction_photo_width: int = 500,
    ) -> None:
        # El User-Agent y los tiempos máximos van en el propio cliente http.
        self._http = http
        self._limiter = limiter
        self._max_wait = max_wait_seconds
        self._city_width = city_photo_width
        self._attraction_width = attraction_photo_width

    async def _get(self, url: str, params: dict[str, str], *, accept: str) -> Any:
        await self._limiter.acquire(self._max_wait)
        try:
            resp = await self._http.get(url, params=params, headers={"Accept": accept})
        except httpx.HTTPError as exc:
            raise WikimediaError(f"{type(exc).__name__} al llamar a Wikimedia") from exc
        if resp.status_code in (429, 503):
            raise WikimediaBusyError(f"Wikimedia respondió {resp.status_code}")
        if resp.status_code == 404:
            return None
        if resp.status_code != 200:
            raise WikimediaError(f"Wikimedia respondió {resp.status_code}")
        try:
            return resp.json()
        except ValueError as exc:
            raise WikimediaError("respuesta de Wikimedia que no es JSON") from exc

    async def sparql(self, query: str) -> list[dict[str, Any]]:
        """Una consulta SPARQL ya validada (la usan también los monumentos)."""
        return await self._sparql(query)

    async def _sparql(self, query: str) -> list[dict[str, Any]]:
        data = await self._get(SPARQL_URL, {"query": query}, accept="application/sparql-results+json")
        try:
            rows = data["results"]["bindings"]
        except (KeyError, TypeError) as exc:
            raise WikimediaError("respuesta SPARQL inesperada") from exc
        return [r for r in rows if isinstance(r, dict)]

    async def find_city(self, airport: Airport) -> str | None:
        """El identificador de Wikidata ("Q2807") de la ciudad del aeropuerto."""
        data = await self._get(
            WIKIDATA_API,
            {
                "action": "wbsearchentities",
                "search": airport.city,
                "language": "en",
                "type": "item",
                "limit": "15",
                "format": "json",
            },
            accept="application/json",
        )
        candidates = [
            c["id"]
            for c in (data or {}).get("search", [])
            if isinstance(c, dict) and isinstance(c.get("id"), str) and QID_PATTERN.match(c["id"])
        ]
        if not candidates:
            return None
        values = " ".join(f"wd:{q}" for q in candidates)
        rows = await self._sparql(
            f"""SELECT ?c WHERE {{
  VALUES ?c {{ {values} }}
  ?c wdt:P625 ?loc ; wikibase:sitelinks ?sl .
  BIND(geof:distance(?loc, "Point({airport.lon:.4f} {airport.lat:.4f})"^^geo:wktLiteral) AS ?d)
  FILTER(?d < {MAX_CITY_KM})
}} ORDER BY DESC(?sl) LIMIT 1"""
        )
        for row in rows:
            qid = (_value(row, "c") or "").rsplit("/", 1)[-1]
            if QID_PATTERN.match(qid):
                return qid
        return None

    async def city_details(self, qid: str, lang: str) -> dict[str, Any]:
        """Nombre, foto, población, datos del país y los artículos de Wikipedia."""
        _check_qid(qid)
        rows = await self._sparql(
            f"""SELECT ?cityLabel ?image ?pop ?countryLabel ?capitalLabel ?currencyLabel ?langLabel
       ?article ?enArticle WHERE {{
  VALUES ?city {{ wd:{qid} }}
  OPTIONAL {{ ?city wdt:P18 ?image . }}
  OPTIONAL {{ ?city wdt:P1082 ?pop . }}
  OPTIONAL {{ ?city wdt:P17 ?country .
    OPTIONAL {{ ?country wdt:P36 ?capital . }}
    OPTIONAL {{ ?country wdt:P38 ?currency . }}
    OPTIONAL {{ ?country wdt:P37 ?lang . }} }}
  OPTIONAL {{ ?article schema:about ?city ; schema:isPartOf <https://{lang}.wikipedia.org/> . }}
  OPTIONAL {{ ?enArticle schema:about ?city ; schema:isPartOf <https://en.wikipedia.org/> . }}
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}
}} LIMIT 200"""
        )
        out: dict[str, Any] = {"languages": []}
        populations: list[int] = []
        for row in rows:
            for key, var in (
                ("city", "cityLabel"),
                ("image", "image"),
                ("country", "countryLabel"),
                ("capital", "capitalLabel"),
                ("currency", "currencyLabel"),
                ("article", "article"),
                ("en_article", "enArticle"),
            ):
                value = _value(row, var)
                if (
                    key not in out
                    and value is not None
                    and (key in {"image", "article", "en_article"} or _is_label(value))
                ):
                    out[key] = value
            language = _value(row, "langLabel")
            if _is_label(language) and language not in out["languages"] and len(out["languages"]) < 3:
                out["languages"].append(language)
            pop = _value(row, "pop")
            if pop is not None:
                try:
                    populations.append(int(float(pop)))
                except ValueError:
                    pass
        if populations:
            out["population"] = max(populations)
        return out

    def city_photo(self, file_url: str | None) -> Photo | None:
        return commons_photo(file_url, self._city_width) if file_url else None

    @staticmethod
    def country_facts(details: dict[str, Any]) -> CountryFacts | None:
        if "country" not in details:
            return None
        return CountryFacts(
            name=details["country"],
            capital=details.get("capital"),
            currency=details.get("currency"),
            languages=list(details["languages"]),
        )

    async def attractions(self, qid: str, lang: str) -> list[Attraction]:
        """Los lugares de la ciudad con foto, del más conocido al menos."""
        _check_qid(qid)
        excluded = " ".join(f"wd:{q}" for q in _NOT_ATTRACTIONS)
        rows = await self._sparql(
            f"""SELECT ?item ?itemLabel ?itemDescription ?image ?article ?sl WHERE {{
  ?item (wdt:P131|wdt:P131/wdt:P131) wd:{qid} ;
        wdt:P18 ?image ;
        wdt:P625 ?loc ;
        wikibase:sitelinks ?sl .
  FILTER(?sl >= {MIN_SITELINKS})
  FILTER NOT EXISTS {{ ?item wdt:P31 wd:Q5 . }}
  FILTER NOT EXISTS {{ VALUES ?no {{ {excluded} }} ?item wdt:P31/wdt:P279* ?no . }}
  OPTIONAL {{ ?article schema:about ?item ; schema:isPartOf <https://{lang}.wikipedia.org/> . }}
  SERVICE wikibase:label {{ bd:serviceParam wikibase:language "{lang},en". }}
}} ORDER BY DESC(?sl) LIMIT 40"""
        )
        seen: set[str] = set()
        out: list[Attraction] = []
        for row in rows:
            item, name = _value(row, "item"), _value(row, "itemLabel")
            # Un lugar con varias fotos sale en varias filas: nos quedamos con la primera.
            if item is None or item in seen or not _is_label(name):
                continue
            seen.add(item)
            image = _value(row, "image")
            out.append(
                Attraction(
                    name=name or "",
                    description=_value(row, "itemDescription"),
                    photo=commons_photo(image, self._attraction_width) if image else None,
                    article_url=_value(row, "article"),
                )
            )
            if len(out) >= MAX_ATTRACTIONS:
                break
        return out

    async def summary(self, article_url: str) -> tuple[str, str] | None:
        """(resumen, enlace) del artículo de Wikipedia, o None si no existe."""
        match = re.fullmatch(r"https://([a-z]{2,3})\.wikipedia\.org/wiki/([^/?#]+)", article_url)
        if match is None:
            return None
        lang, title = match.groups()
        data = await self._get(
            f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{title}", {}, accept="application/json"
        )
        if not isinstance(data, dict):
            return None
        extract = data.get("extract")
        if not isinstance(extract, str) or not extract.strip():
            return None
        extract = extract.strip()
        if len(extract) > MAX_SUMMARY_CHARS:
            # Cortamos en el último punto antes del tope: nunca a media frase.
            cut = extract.rfind(". ", 0, MAX_SUMMARY_CHARS)
            extract = extract[: cut + 1] if cut > 0 else extract[:MAX_SUMMARY_CHARS] + "…"
        return extract, article_url


def _check_qid(qid: str) -> None:
    if not QID_PATTERN.match(qid):
        raise ValueError(f"identificador de Wikidata inválido: {qid!r}")
