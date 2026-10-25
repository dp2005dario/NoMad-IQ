#!/usr/bin/env python3
"""Regenera assets/geo/visas.txt: qué necesita cada pasaporte para entrar en
cada país (sin visado, visado a la llegada, autorización electrónica...).

Uso (desde la carpeta mobile/):
    python3 tool/build_visa_data.py passport-index.json

- passport-index.json: de https://github.com/imorte/passport-index-data
  (licencia MIT; datos de passportindex.org). Descárgalo de
  https://raw.githubusercontent.com/imorte/passport-index-data/main/passport-index.json

¿Por qué dentro de la app y no en el servidor? Son ~120 KB, cambian pocas
veces al año y así la pantalla Visado funciona sin conexión y nadie sabe a
qué país piensas viajar. Coste: 0 €.

Formato de salida (texto, una línea por pasaporte):
    # comentario con la fecha y la fuente
    AD AE AF ...                 <- los destinos, en este orden
    ES|F90,F,T90,E,R,...         <- un código por destino
Códigos: F = sin visado, A = visado a la llegada, T = autorización
electrónica (ESTA, eTA, ETA...), E = visado electrónico, R = visado en la
embajada, N = no dejan entrar, - = sin dato (o el mismo país). Si hay número,
son los días que te dejan quedarte.

Solo usa la biblioteca estándar de Python: no hay que instalar nada.
"""
import json
import re
import sys

LETTER = {
    "visa free": "F",
    "visa on arrival": "A",
    "eta": "T",
    "e-visa": "E",
    "visa required": "R",
    "no admission": "N",
}


def cell(entry):
    """Un destino → "F90", "R", "-"... (lo más corto posible)."""
    if not isinstance(entry, dict):
        return "-"
    letter = LETTER.get(entry.get("status"))
    if letter is None:
        return "-"
    days = entry.get("days")
    if isinstance(days, int) and 0 < days <= 999:
        return f"{letter}{days}"
    return letter


def main(path, out="assets/geo/visas.txt", updated="2026-02-17"):
    data = json.load(open(path, encoding="utf-8"))
    iso = re.compile(r"^[A-Z]{2}$")
    # Solo códigos de dos letras: si el archivo trae algo raro, se ignora.
    passports = sorted(p for p in data if iso.match(p))
    dests = sorted({d for p in passports for d in data[p] if iso.match(d)} | set(passports))
    lines = [
        f"# NomadIQ visas · passportindex.org via imorte/passport-index-data (MIT) · {updated}",
        " ".join(dests),
    ]
    for p in passports:
        row = data[p]
        lines.append(p + "|" + ",".join("-" if d == p else cell(row.get(d)) for d in dests))
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    print(f"{out}: {len(passports)} pasaportes × {len(dests)} destinos")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(*sys.argv[1:])
