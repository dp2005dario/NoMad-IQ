""" "Spain" → "ES": los nombres de país de airports.txt con su código ISO.

Es la misma tabla que lleva la app (mobile/assets/geo/countries.txt). Hace
falta para preguntar los festivos de un país (Nager.Date usa el código).
"""

from __future__ import annotations

import re
from importlib import resources

_CODE = re.compile(r"^[A-Z]{2}$")


def parse_countries(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in text.splitlines():
        parts = line.split("|")
        if len(parts) == 2 and _CODE.match(parts[1]):
            out[parts[0]] = parts[1]
    return out


def bundled_countries() -> dict[str, str]:
    text = resources.files(__package__).joinpath("countries.txt").read_text(encoding="utf-8")
    return parse_countries(text)
