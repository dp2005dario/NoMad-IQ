# Guía para principiantes: Escala de regalo

Algunas aerolíneas te dejan **quedarte unos días en su ciudad** de camino a
tu destino sin subir el precio del billete, o con el hotel regalado o
rebajado. Por ejemplo: Madrid → **Estambul (2 noches)** → Tokio con Turkish
Airlines. Son dos viajes por el precio de uno.

Se entra desde **Vuelos → Planea tu viaje → Escala de regalo**.

## Cómo se usa

1. Pon de dónde sales y a dónde vas (códigos de 3 letras: MAD, HND...).
2. La app te enseña las ciudades donde puedes parar **de camino** (Estambul,
   Doha, Helsinki...). Toca una.
3. Elige cuántas noches (No, 1, 2 o 3).
4. **Ver precio**: busca ese día el vuelo más barato y el de la aerolínea de
   la escala (con el buscador de siempre).
5. **Sobre Estambul**: la ficha de la ciudad (Wikipedia) para ver qué hacer.
6. **Reservar con 2 noches en Estambul** abre la página oficial del programa
   de la aerolínea: un vuelo con parada de varios días se reserva allí
   ("varios destinos"). Con "No" noches se abre la oferta más barata.

## ¿Cómo sabe qué escalas "pillan de camino"?

Para cada programa (Turkish en Estambul, Qatar en Doha, Icelandair en
Reikiavik, TAP en Lisboa, Finnair en Helsinki, Emirates en Dubái, Etihad en
Abu Dabi, Singapore en Singapur, Copa en Panamá y Cathay en Hong Kong):

- La aerolínea tiene que volar a la **zona** de salida y a la de llegada
  (Icelandair solo une Europa y Norteamérica: no sirve para ir a Tokio).
- Cada tramo tiene que ser **más corto** que el viaje entero (no vale ir
  "hacia atrás", como pasar por Lisboa para ir de Madrid a Tokio).
- Y como mucho un **30 % más de kilómetros** que el vuelo directo.

Todo se calcula en el móvil con la lista de aeropuertos que lleva la app:
no cuesta nada y funciona igual para miles de usuarios.

## Lo que hay que saber

- Las condiciones (noches, hotel gratis, tarifas) **cambian**: la app lo dice
  y manda a la página oficial para comprobarlo.
- Los enlaces de las aerolíneas están en
  `mobile/lib/features/stopover/stopover.dart`. Si alguna aerolínea cambia
  su página, se cambia ahí.

## Arreglo de aeropuertos

Al hacer esta pantalla vimos que la lista de aeropuertos (OpenFlights, que
ya no se actualiza) no tenía el **nuevo aeropuerto de Estambul (IST)**, ni
**Doha (DOH)**, Berlín (BER), Pekín-Daxing (PKX) y otros abiertos después de
2018. Se añaden a mano en `mobile/tool/build_geo_data.py` (`NEW_AIRPORTS`) y
ya están en `airports.txt` (de la app y del servidor).

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `mobile/lib/features/stopover/stopover.dart` | Los programas de escala y la cuenta de "de camino" |
| `mobile/lib/features/stopover/stopover_screen.dart` | La pantalla |
| `mobile/test/stopover_test.dart` | Las pruebas |

## Probarlo en VS Code

```bash
cd mobile
flutter test test/stopover_test.dart
```
