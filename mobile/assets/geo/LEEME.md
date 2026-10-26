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

`countries.txt`: nombre del país tal como sale en `airports.txt` y su código
ISO de dos letras (`Spain|ES`). Lo genera `tool/flight3d/build_country_codes.mjs`
con [i18n-iso-countries](https://github.com/michaelwittig/node-i18n-iso-countries)
(licencia MIT). El Vuelo 3D lo usa para la bandera y el nombre del país.

`visas.txt`: qué necesita cada pasaporte para entrar en cada país (199 × 199),
para la pantalla Visado. Sale de [passport-index-data](https://github.com/imorte/passport-index-data)
(datos de passportindex.org, licencia MIT). Formato y cómo se regenera:
`tool/build_visa_data.py`.

`country_names.txt`: el nombre de cada país en los idiomas de la app y su
código de tres letras (el del pasaporte). Lo genera
`tool/flight3d/build_country_names.mjs` con i18n-iso-countries (MIT).
