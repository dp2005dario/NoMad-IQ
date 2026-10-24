# Guía de Explorar (para principiantes)

**Vuelos → Explorar** responde a la pregunta con la que empieza casi todo
viaje: *"¿a dónde vuelo barato y con buen tiempo?"*. Eliges dos aeropuertos
y sale el **precio de ida y vuelta de cada mes del próximo año** junto al
**clima medio** de ese mes.

## 1. La idea con una analogía

Imagina un calendario de pared con doce casillas. En cada casilla alguien ha
apuntado dos cosas: lo que costó el billete y qué tiempo hacía. Mirándolo de
un vistazo ya sabes cuándo ir. Esa es la pantalla.

## 2. Glosario

| Palabra | Qué significa |
|---|---|
| **IATA** | El código de tres letras de un aeropuerto: MAD (Madrid), NRT (Tokio-Narita) |
| **Precio por meses** | El billete más barato que **otros viajeros** encontraron para salir ese mes. No es una reserva: es el precio que se vio |
| **Medias de 30 años** | El clima "normal" de ese sitio en ese mes, no la previsión de un día concreto |
| **Rareza del dato** | Si nadie ha buscado esa ruta últimamente, no hay precios: la pantalla lo dice en vez de inventarlos |

## 3. De dónde salen los datos (y por qué cuestan 0 €)

**Los precios**: de la Data API de **Travelpayouts** (gratis), con una sola
petición para el año entero (`/v1/prices/monthly`).

- El `flight-ingestor` lo pide en `internal/provider/travelpayouts_monthly.go`
  y lo sirve por gRPC con `MonthlyFares` (`internal/grpcserver/search.go`).
- Esa llamada pasa por la **misma caché y el mismo "singleflight"** que el
  buscador: si 500 personas preguntan por Madrid-Tokio a la vez, sale **una**
  petición; y durante `SEARCH_CACHE_TTL` (10 min) ninguna más.
- El `price-consumer` lo publica como **`GET /v1/fares/months`**, pública
  (también para invitados), con el límite de peticiones del buscador.

**El clima**: de **NASA POWER**, medias de 30 años de satélite. Es de dominio
público, gratis y sin clave.

- El `ai-orchestrator` lo pide en `src/ai_orchestrator/climate/` y lo sirve
  como **`GET /v1/climate?lat&lon`**, también pública.
- El mundo se parte en casillas de **0,5° (~50 km)**: se pregunta por la
  casilla, nunca por el punto exacto de nadie, y se guarda **30 días** en
  Redis (una media de 30 años no cambia mañana). Las coordenadas no se
  escriben en los registros.
- La NASA da la lluvia en mm al día; la app los convierte a **días de lluvia**
  (cada ~5 mm, un día) porque "8 días de lluvia" se entiende mejor que
  "40 mm".

## 4. El veredicto

Un mes es de **buen tiempo** si la media pasa de 12°, las máximas no llegan a
32° y llueve 10 días o menos (`niceWeather` en `explore_screen.dart`). Con
eso:

- barato **y** buen tiempo → "es el punto justo";
- barato pero duro → "el tiempo es peor, llévate chaqueta";
- sin datos de clima → solo "es el mes más barato que hemos visto".

Al tocar **Ver vuelos a…** se abre el buscador con la ruta y los días de ese
mes ya puestos, y ahí se reserva como siempre (con nuestro enlace de
afiliado: es lo que paga la app).

## 5. Fichero a fichero

| Fichero | Para qué sirve |
|---|---|
| `proto/nomadiq/flights/v1/fare_search_service.proto` | El contrato `MonthlyFares` |
| `services/flight-ingestor/internal/provider/travelpayouts_monthly.go` | Pedir el año a Travelpayouts |
| `services/flight-ingestor/internal/provider/simulated.go` | Precios inventados para desarrollo (verano más caro) |
| `services/price-consumer/internal/api/api.go` | `GET /v1/fares/months` |
| `services/ai-orchestrator/src/ai_orchestrator/climate/` | El clima de la NASA con caché |
| `mobile/lib/features/flights/climate_api.dart` | El clima en la app |
| `mobile/lib/features/flights/explore_screen.dart` | La pantalla con las barras y el veredicto |

## 6. Probarlo desde Visual Studio Code

1. **Archivo → Abrir carpeta…** → `NoMad-IQ`, y **Ver → Terminal**.
2. Servidores:
   ```bash
   cd services/flight-ingestor && go test ./...
   cd ../price-consumer && go test ./...
   cd ../ai-orchestrator && source .venv/bin/activate && pytest tests/test_climate.py -q
   ```
3. App:
   ```bash
   cd mobile
   flutter test test/explore_test.dart
   ```
4. En un móvil: `flutter run`, **Vuelos → Explorar**, escribe MAD y NRT y
   toca **Ver el año**.

## 7. Límites honestos

- Sin `TRAVELPAYOUTS_TOKEN` el servidor usa el proveedor simulado: los meses
  salen, pero son inventados (vale para ver la pantalla, no para decidir).
- Una ruta que nadie busca no tiene precios por meses, y la pantalla lo dice.
- El clima es una **media**, no una previsión: en abril puede llover aunque
  abril sea "seco".
