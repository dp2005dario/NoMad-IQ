#!/usr/bin/env python3
"""Regenera los datos de la Ruta del vuelo: assets/geo/world.bin y airports.txt.

Uso (desde la carpeta mobile/):
    python3 tool/build_geo_data.py countries-50m.json airports.dat

- countries-50m.json: viene en el paquete npm world-atlas 2.0.2
  (https://registry.npmjs.org/world-atlas/-/world-atlas-2.0.2.tgz).
- airports.dat: de OpenFlights
  (https://raw.githubusercontent.com/jpatokal/openflights/master/data/airports.dat).

Solo usa la biblioteca estándar de Python: no hay que instalar nada.
"""
import csv
import json
import struct
import sys

# Guardamos las coordenadas como enteros "×10" (una décima de grado, ~11 km):
# para ver un mapamundi en el móvil sobra y el archivo ocupa la mitad.
SCALE = 10


def rings_from_topojson(path):
    """Convierte el TopoJSON de world-atlas en anillos (contornos) de países.

    TopoJSON guarda cada frontera UNA sola vez ("arcos") y los países dicen
    qué arcos usan. Aquí deshacemos eso para tener cada contorno completo.
    """
    t = json.load(open(path, encoding="utf-8"))
    (sx, sy), (tx, ty) = t["transform"]["scale"], t["transform"]["translate"]
    arcs = []
    for a in t["arcs"]:
        # Los puntos vienen como diferencias con el anterior ("delta"):
        # se van sumando para recuperar la posición real.
        x = y = 0
        pts = []
        for dx, dy in a:
            x += dx
            y += dy
            pts.append((x * sx + tx, y * sy + ty))
        arcs.append(pts)

    def arc(i):
        # Un índice negativo significa "ese arco, pero recorrido al revés".
        return arcs[i] if i >= 0 else arcs[~i][::-1]

    rings = []
    for obj in t["objects"].values():
        for g in obj["geometries"]:
            if g["type"] == "MultiPolygon":
                polys = g["arcs"]
            elif g["type"] == "Polygon":
                polys = [g["arcs"]]
            else:
                continue
            for poly in polys:
                # Solo el contorno exterior: los "agujeros" (lagos) no se ven
                # a este tamaño y así hay menos puntos que dibujar.
                pts = []
                for i in poly[0]:
                    a = arc(i)
                    pts.extend(a if not pts else a[1:])
                q = []
                for lon, lat in pts:
                    v = (round(lon * SCALE), round(lat * SCALE))
                    if not q or q[-1] != v:  # quita puntos repetidos
                        q.append(v)
                if len(q) >= 4:
                    rings.append(q)
    return rings


def write_world(rings, out):
    """Formato NQW1 (ver assets/geo/LEEME.md), todo en little-endian."""
    with open(out, "wb") as f:
        f.write(b"NQW1")
        f.write(struct.pack("<I", len(rings)))
        for r in rings:
            f.write(struct.pack("<I", len(r)))
            flat = [c for xy in r for c in xy]
            f.write(struct.pack("<%dh" % len(flat), *flat))


# OpenFlights ya no se actualiza: le faltan aeropuertos abiertos después de
# 2018 (el nuevo de Estambul, Hamad en Doha, Berlín-Brandeburgo...). Se
# añaden aquí a mano, con la misma forma que una línea de airports.txt.
NEW_AIRPORTS = [
    "BER|52.367|13.503|Berlin|Germany|Europe/Berlin",
    "DOH|25.273|51.608|Doha|Qatar|Asia/Qatar",
    "GOX|15.739|73.861|Goa|India|Asia/Kolkata",
    "IST|41.275|28.752|Istanbul|Turkey|Europe/Istanbul",
    "NLU|19.737|-99.016|Mexico City|Mexico|America/Mexico_City",
    "NQZ|51.022|71.467|Astana|Kazakhstan|Asia/Almaty",
    "PKX|39.509|116.411|Beijing|China|Asia/Shanghai",
    "TFU|30.312|104.441|Chengdu|China|Asia/Shanghai",
]


def write_airports(src, out):
    """Filtra airports.dat: solo aeropuertos con código IATA y zona horaria."""
    rows, seen = [], set()
    for r in csv.reader(open(src, encoding="utf-8")):
        iata = r[4]
        kind = r[12] if len(r) > 12 else ""
        tz = r[11]
        if len(iata) != 3 or not iata.isalpha() or not iata.isupper():
            continue
        if kind != "airport" or iata in seen or tz in ("\\N", ""):
            continue
        seen.add(iata)
        # "|" separa columnas en nuestro archivo: no puede aparecer en nombres.
        city = r[2].replace("|", " ").strip() or r[1]
        country = r[3].replace("|", " ")
        rows.append("|".join([iata, "%.3f" % float(r[6]), "%.3f" % float(r[7]), city, country, tz]))
    for line in NEW_AIRPORTS:
        if line[:3] not in seen:
            seen.add(line[:3])
            rows.append(line)
    rows.sort()
    with open(out, "w", encoding="utf-8") as f:
        f.write("\n".join(rows) + "\n")
    return len(rows)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    rings = rings_from_topojson(sys.argv[1])
    write_world(rings, "assets/geo/world.bin")
    n = write_airports(sys.argv[2], "assets/geo/airports.txt")
    # El ai-orchestrator usa la MISMA lista para las fichas de ciudad (un test
    # comprueba que las dos copias son idénticas).
    server_copy = "../services/ai-orchestrator/src/ai_orchestrator/places/airports.txt"
    with open("assets/geo/airports.txt", "rb") as src, open(server_copy, "wb") as dst:
        dst.write(src.read())
    print("%d contornos, %d puntos, %d aeropuertos" % (len(rings), sum(len(r) for r in rings), n))
