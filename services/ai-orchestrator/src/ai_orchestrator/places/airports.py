"""La lista de aeropuertos (la misma que lleva la app en mobile/assets/geo/).

¿Por qué el servidor pide un código IATA ("MAD") y no un nombre de ciudad?
    Porque así solo existen ~5.500 fichas posibles por idioma. Si aceptáramos
    cualquier texto, alguien podría pedir millones de nombres inventados y
    llenar la caché (y gastar el cupo de Wikimedia) a propósito.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from importlib import resources

IATA_PATTERN = re.compile(r"^[A-Z]{3}$")


@dataclass(frozen=True, slots=True)
class Airport:
    iata: str
    lat: float
    lon: float
    city: str
    country: str


class Airports:
    def __init__(self, by_iata: dict[str, Airport]) -> None:
        self._by_iata = by_iata

    def __len__(self) -> int:
        return len(self._by_iata)

    def get(self, iata: str) -> Airport | None:
        return self._by_iata.get(iata.upper())

    @classmethod
    def parse(cls, text: str) -> Airports:
        """Formato por línea: ``IATA|lat|lon|ciudad|país|zona horaria``."""
        out: dict[str, Airport] = {}
        for line in text.splitlines():
            parts = line.split("|")
            if len(parts) < 5 or not IATA_PATTERN.match(parts[0]):
                continue
            try:
                lat, lon = float(parts[1]), float(parts[2])
            except ValueError:
                continue
            out[parts[0]] = Airport(parts[0], lat, lon, parts[3], parts[4])
        return cls(out)

    @classmethod
    def bundled(cls) -> Airports:
        """La lista que va dentro del paquete (places/airports.txt)."""
        text = resources.files(__package__).joinpath("airports.txt").read_text(encoding="utf-8")
        return cls.parse(text)
