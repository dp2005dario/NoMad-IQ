# Guía para principiantes: Aeropuerto

Dentro de una terminal grande es fácil perderse. La pantalla **Aeropuerto**
te enseña una **flecha** que apunta a tu puerta, al baño más cercano, a un
café, al agua, a la farmacia, a un cajero, a los enchufes, a información o a
la sala VIP, con los **metros** y los **minutos andando**. Si tu vuelo sale
de ese aeropuerto, también te dice si **te da tiempo** a llegar al embarque.

Se entra desde Inicio, con el icono del avión (Aeropuerto).

## Cómo sabe en qué aeropuerto estás

1. Si tu próximo vuelo (el de Widgets / Modo fácil) sale en las próximas 24
   horas, usa su aeropuerto y su puerta.
2. Si no, mira el GPS: el aeropuerto más cercano (a menos de 15 km).
3. Si no, te pregunta el código (MAD, LHR...).

## Cómo funciona por dentro

Es como una **brújula**:

- El **GPS** dice dónde estás.
- La **brújula** del móvil dice hacia dónde miras.
- La **guía del aeropuerto** dice dónde está cada sitio.

Con eso se calcula el ángulo y la app dice "Sigue recto 120 m", "Gira a la
izquierda" o "Date la vuelta". No es navegación por pasillos (para eso haría
falta un mapa de interiores que no existe gratis para todos los
aeropuertos), y dentro de los edificios el GPS puede fallar unas decenas de
metros: la pantalla te recuerda que sigas **también los carteles**.

### De dónde salen los sitios

De **OpenStreetMap** (el mapa libre que hacen voluntarios), a través de
nuestro servidor:

```
GET /v1/airports/MAD/spots
```

- El servidor busca el **recinto** del aeropuerto en OpenStreetMap (por su
  código IATA) y dentro: puertas con número, baños, cafés, restaurantes,
  farmacias, cajeros, fuentes de agua, enchufes, información y salas VIP.
- Lo guarda **un mes** en Redis (7 días si el aeropuerto aún no tiene nada
  dibujado). Un aeropuerto casi no cambia: miles de viajeros en Barajas son
  **una sola** pregunta a OpenStreetMap al mes. Coste: 0 €.
- Solo acepta códigos de nuestra lista de aeropuertos: nadie puede llenar la
  caché con códigos inventados.
- El servidor **no sabe dónde estás**: la app pide el aeropuerto entero y
  calcula las distancias en el móvil.

Si un aeropuerto no tiene el interior dibujado en OpenStreetMap, la app lo
dice. Cualquiera puede añadirlo en openstreetmap.org y en una semana aparece
en NomadIQ.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/airport_guide/` | Servidor: consulta a Overpass, caché y la ruta `/v1/airports/{IATA}/spots` |
| `mobile/lib/features/airport/airport_guide.dart` | Leer la guía, rumbo, giros y minutos andando |
| `mobile/lib/features/airport/airport_screen.dart` | La pantalla con la flecha |
| `mobile/lib/features/airport/compass.dart` | La brújula del móvil |
| `infrastructure/edge/dynamic.yml` | La puerta de entrada deja pasar solo `GET /v1/airports/<código>/spots` |

## Probarlo en VS Code

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_airport_guide.py
cd ../../mobile
flutter test test/airport_test.dart
```
