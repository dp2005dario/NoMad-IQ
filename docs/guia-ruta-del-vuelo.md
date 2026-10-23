# Guía de la Ruta del vuelo (para principiantes)

La **Ruta del vuelo** es la pantalla que enseña tu viaje en un mapamundi: la
cámara viaja a tu ciudad de origen, el avión despega, sigue la ruta curva
real que hacen los aviones y aterriza en el destino, donde ves la hora local
y cuántas horas de diferencia hay con tu ciudad.

Se abre desde **Vuelos → Planea tu viaje → Ruta del vuelo**, o con el botón
**"Ver la ruta en el mapa"** de cualquier resultado del buscador o del
detalle de una ruta.

## Cómo funciona (con analogías)

| Pieza | Qué hace | Analogía |
|---|---|---|
| `geo.dart` | Calcula distancias y la ruta curva ("círculo máximo") | Tensar un hilo sobre un globo terráqueo entre dos ciudades: el hilo marca el camino más corto, y en un mapa plano se ve curvo |
| `world_data.dart` | Lee los contornos de países y la lista de aeropuertos que van dentro de la app | Un atlas de papel guardado en la mochila: no hace falta internet |
| `route_painter.dart` | Dibuja océano, países, la ruta, los aeropuertos y el avión | Un pintor que repinta el cuadro 60 veces por segundo |
| `flight_route_screen.dart` | Decide qué se ve en cada momento (mundo → origen → vuelo → llegada) | El director de cine que mueve la cámara |

### Por qué sin servidor de mapas

- **0 €**: los mapas de pago cobran por cada vista; con millones de usuarios
  la factura sería enorme. Aquí todo se dibuja en el propio móvil.
- **Privacidad**: nadie fuera del móvil sabe qué ruta estás mirando.
- **Sin conexión**: funciona en modo avión (¡útil dentro del avión!).

### Por qué la ruta es curva

La Tierra es una esfera. El camino más corto entre Madrid y Tokio pasa cerca
de Rusia, y en un mapa plano eso se ve como un arco. La app usa la misma
fórmula que la navegación aérea ("haversine" para la distancia y "slerp"
para los puntos intermedios).

### La hora del destino

La lista de aeropuertos trae la zona horaria (por ejemplo `Asia/Tokyo`). El
paquete `timezone` sabe los cambios de horario de verano de todo el mundo, así
que "7 h más que Madrid" es correcto cualquier día del año.

## Fichas de ciudad ("Sobre Madrid")

En el origen y al llegar aparece el botón **"Sobre <ciudad>"**. Abre una ficha
con:

- **Por qué es famosa**: el resumen del artículo de Wikipedia en tu idioma
  (si no existe, en inglés, y lo dice).
- **Datos**: población, y del país la capital, la moneda y los idiomas.
- **Lo más visitado**: los lugares de la ciudad con foto, ordenados por en
  cuántas Wikipedias del mundo tienen artículo (una buena medida de "fama").
- **Fotos** de Wikimedia Commons, que solo admite fotos con licencia libre.
  Tocar una foto abre su página con el autor y la licencia.

### De dónde sale (y por qué cuesta 0 €)

| Pieza | Qué hace | Analogía |
|---|---|---|
| App: `places_api.dart` | Pide `GET /v1/places/MAD?lang=es` (también en modo invitado) y lo recuerda mientras la app está abierta | Apuntar en un pósit lo que ya preguntaste |
| Puerta de entrada | Ruta pública `places`, solo GET y con límite por IP | El portero deja pasar a mirar el escaparate |
| `ai-orchestrator/places/` | Busca en Wikidata y Wikipedia y guarda la ficha 7 días en Redis | Un bibliotecario que fotocopia la página una vez y la deja en el mostrador |

Para que millones de usuarios no cuesten nada:

1. Solo se aceptan **códigos de aeropuerto reales** (la misma lista de ~5.500
   que lleva la app). Nadie puede inventarse millones de ciudades para
   llenar la caché.
2. **Caché de 7 días** en Redis y de un día en el móvil (`Cache-Control`).
   Como mucho hay 5.500 × 10 idiomas fichas posibles.
3. **Single flight**: si mil personas abren Tokio a la vez, sale UNA
   consulta a Wikimedia.
4. **Límite de ritmo** hacia Wikimedia (`WIKIMEDIA_RATE_PER_SECOND`, 5 por
   segundo): si se supera, la app recibe "ocupado" (503) y simplemente dice
   que lo intentes luego. Nunca hay factura.

Wikimedia pide un `User-Agent` que diga quién llama
(`WIKIMEDIA_USER_AGENT`); lo ponen tanto el servidor como la app al
descargar fotos. Las fotos se descargan directamente de Wikimedia (no pasan
por nuestro servidor, así no gastamos ancho de banda).

### Variables del ai-orchestrator

| Variable | Por defecto | Para qué |
|---|---|---|
| `PLACES_ENABLED` | `true` | Encender o apagar las fichas (necesitan Redis) |
| `WIKIMEDIA_USER_AGENT` | `NomadIQ/0.1 (https://github.com/dp2005dario/NoMad-IQ)` | Quién llama a Wikimedia |
| `WIKIMEDIA_RATE_PER_SECOND` / `WIKIMEDIA_BURST` | `5` / `10` | Ritmo máximo hacia Wikimedia |
| `WIKIMEDIA_TIMEOUT_SECONDS` | `15` | Espera máxima por petición |
| `PLACE_TTL_SECONDS` | `604800` (7 días) | Cuánto vive una ficha en Redis |

Para probarlo en local con todo arrancado (Docker):

```bash
curl "http://127.0.0.1:8080/v1/places/MAD?lang=es"
```

## Datos

Están en `mobile/assets/geo/` (licencias en `LEEME.md` de esa carpeta y en
**Ajustes → Licencias** dentro de la app):

- `world.bin` (~500 KB): contornos de los países de Natural Earth.
- `airports.txt`: ~5.500 aeropuertos de OpenFlights.

Para regenerarlos (casi nunca hace falta):

1. Descarga `https://registry.npmjs.org/world-atlas/-/world-atlas-2.0.2.tgz`
   y descomprímelo; dentro está `package/countries-50m.json`.
2. Descarga `airports.dat` de
   `https://raw.githubusercontent.com/jpatokal/openflights/master/data/airports.dat`.
3. Desde la carpeta `mobile/`:

   ```bash
   python3 tool/build_geo_data.py ruta/a/countries-50m.json ruta/a/airports.dat
   ```

   Escribe "2917 contornos, 125612 puntos, 5515 aeropuertos" y reemplaza los
   dos archivos (y la copia de `airports.txt` que usa el ai-orchestrator).

## Probarlo en VS Code

1. **Archivo → Abrir carpeta…** y elige `NoMad-IQ/mobile`.
2. Ten instaladas las extensiones **Flutter** y **Dart**.
3. Abre la terminal (**Ver → Terminal** o `Ctrl+ñ`) y ejecuta:

   ```bash
   flutter test test/route_test.dart
   ```

   Son 15 pruebas: cálculos (Madrid-Tokio ≈ 10.770 km, cruzar el Pacífico),
   lectura de los datos reales, la pantalla completa de origen a llegada y las
   fichas de ciudad. Las del servidor: en la carpeta `services/ai-orchestrator`,
   `uv run pytest tests/test_places.py`.
4. Para verlo en el móvil: `flutter run`, entra como invitado y ve a
   **Vuelos → Ruta del vuelo**.

## Glosario

- **Círculo máximo**: el camino más corto entre dos puntos de una esfera.
- **CustomPainter**: la forma de Flutter de dibujar "a mano" con líneas y formas.
- **Proyección equirrectangular**: mapa donde la longitud es la X y la latitud la Y.
- **Wikidata**: la "base de datos" de Wikipedia: cada cosa tiene un número (Madrid es Q2807) y datos ordenados.
- **SPARQL**: el idioma para hacer preguntas a Wikidata ("lugares de Madrid con foto, de más a menos famosos").
- **Zona horaria IANA**: nombre estándar como `Europe/Madrid` que identifica las reglas de hora de un lugar.
