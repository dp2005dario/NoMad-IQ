# Datos geográficos que lleva la app dentro

Van dentro de la app para que la Ruta del vuelo funcione sin conexión y sin
avisar a nadie de qué ruta miras.

| Archivo | Qué es | De dónde sale | Licencia |
|---|---|---|---|
| `world.bin` | Contornos de los países (escala 1:50 millones), en binario | [Natural Earth](https://www.naturalearthdata.com) vía [world-atlas 2.0.2](https://github.com/topojson/world-atlas) | Natural Earth: dominio público · world-atlas: ISC |
| `airports.txt` | ~5.500 aeropuertos con código IATA: `IATA\|lat\|lon\|ciudad\|país\|zona horaria` | [OpenFlights](https://openflights.org/data.html) (`airports.dat`, que a su vez usa OurAirports) | Open Database License (ODbL) |

Formato de `world.bin` (todo en little-endian):

```
"NQW1"            4 bytes: firma
anillos           uint32
por cada anillo:  n uint32, y n parejas (lon×10, lat×10) en int16
```

Cómo se regeneran: `tool/build_geo_data.py` (instrucciones en `docs/guia-ruta-del-vuelo.md`, sección "Datos").
