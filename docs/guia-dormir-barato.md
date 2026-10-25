# Guía para principiantes: Dormir barato

Dormir junto al sitio que vas a visitar suele ser lo más caro. A veces, unas
paradas de tren más lejos hay muchos más alojamientos y la noche cuesta la
mitad. **Dormir barato** te enseña esas zonas y te ayuda a hacer la cuenta de
verdad: lo que ahorras en el hotel **menos** lo que gastas en trenes.

Se entra desde **Vuelos**, en los atajos ("Dormir barato").

## Cómo se usa

1. **¿Adónde vas?** "Cerca de mí" (el GPS) o "En el mapa" (mueves el mapa
   hasta que la cruz quede encima del sitio).
2. **Fechas y personas**: sirven para abrir Booking ya filtrado y para las
   cuentas.
3. **Radio**: "Solo cerca" (andando), "Hasta 15 km" o "Hasta 35 km".
4. Cada zona dice cuánto se tarda (andando o en tren/metro, **estimado**),
   cuántos alojamientos hay y cuántos son económicos (albergues, pensiones).
5. **Ver precios** abre Booking.com en esa zona, con tus fechas y ordenado
   por precio. Ese es el precio real de ese día.
6. **Calcular el total real**: apunta el precio por noche que viste (y el
   billete de tren). La app suma alojamiento + trenes (ida y vuelta cada día,
   por persona) y te dice cuánto ahorras frente a dormir al lado.

Analogía: es como comparar una gasolinera barata que está lejos. No basta con
mirar el precio del litro: también cuenta lo que gastas en ir.

## Por qué no enseñamos precios dentro de la app

No existe ninguna fuente **gratis y fiable** con precios de hotel de todo el
mundo. Las que hay son de pago o se rompen. Preferimos un número de verdad
en Booking a uno bonito y falso aquí. Por eso el servidor devuelve **zonas**
y no hoteles con precio.

### El enlace de afiliado (opcional)

Si te das de alta en el programa de afiliados de Booking.com, compila la app
con tu identificador y cada reserva que salga de "Ver precios" te da una
comisión (sin que el viajero pague más):

```bash
flutter build appbundle --dart-define=NOMADIQ_BOOKING_AID=TU_ID
```

Sin ese valor, el botón funciona igual pero sin comisión.

## De dónde salen los datos (0 €)

De **OpenStreetMap**, a través de nuestro servidor:

```
GET /v1/stays?lat=48.86&lon=2.30
```

- La app manda solo la **casilla de ~2 km**, no el punto exacto.
- El servidor busca alojamientos a 2 km del sitio y estaciones de tren o
  metro (hasta 35 km) con alojamientos a menos de 600 m.
- Cada casilla se guarda **30 días** en Redis (los hoteles no cambian cada
  día) y comparte con Cajeros, Aeropuerto, Cerca de ti y Coche **un solo
  límite** hacia OpenStreetMap. Si hay mucha cola, contesta "inténtalo luego"
  en vez de gastar más.
- Los minutos son una estimación: 12 min por km andando; en tren, 6 min de
  espera más 1,6 min por km.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/stays/` | Servidor: consulta, zonas, caché y `/v1/stays` |
| `mobile/lib/features/stays/stays_api.dart` | La app pide la casilla y lee las zonas |
| `mobile/lib/features/stays/stays_math.dart` | Total real y enlaces a Booking y Google Maps |
| `mobile/lib/features/stays/stays_screen.dart` | La pantalla |
| `mobile/lib/features/stays/pick_point_screen.dart` | Elegir el sitio en el mapa |
| `infrastructure/edge/dynamic.yml` | La puerta de entrada deja pasar solo `GET /v1/stays` |

## Probarlo en VS Code

Abre la carpeta del proyecto y la terminal (Ver → Terminal):

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_stays.py
cd ../../mobile
flutter test test/stays_test.dart
```
