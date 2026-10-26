# Guía para principiantes: Moverte (transporte)

Acabas de aterrizar y tienes que llegar al hotel. **Moverte** te dice cómo
salir del aeropuerto, qué bonos de transporte tiene la ciudad y guarda tus
billetes.

Se entra desde el **Mapa** (atajo "Moverte") o tocando el aviso
"Bienvenido" que llega al aterrizar.

## Las tres pestañas

| Pestaña | Qué hace |
|---|---|
| Rutas | Las estaciones de tren, metro, tranvía, bus y taxi del aeropuerto. Con la dirección del hotel, abre Google Maps con la ruta en transporte público o en taxi: horarios, transbordos y precios reales de cada operador. |
| Bonos | La tarjeta recargable y los bonos de la ciudad, con su web oficial. Y una calculadora: apuntas el precio del viaje suelto y del bono que ves en la web oficial, y te dice si te compensa. |
| Mis billetes | Tus bonos (cuántas horas les quedan) y tus tarjetas (el saldo que apuntes). Solo en el móvil. |

## Regla: nada inventado

La app **no enseña precios de bonos**. No hay una fuente gratis y
comprobada con los precios de cada ciudad, y un precio escrito a mano se
queda viejo o está mal. Por eso la tabla (`transport_data.dart`) solo dice
qué bonos existen y su web oficial; el precio lo pones tú desde allí.

Analogía: es como una guía que te dice "en esta ciudad hay un bono de
metro, mira el precio en la taquilla", en vez de imprimir un precio que
quizá ya cambió.

Hoy la tabla tiene Tokio, Londres, Nueva York, París, Roma, Madrid,
Barcelona, Lisboa y Berlín. En las demás ciudades la calculadora funciona
igual (con los precios que apuntes).

## De dónde salen las estaciones (0 €)

De **OpenStreetMap**, en la misma consulta que la guía del aeropuerto:

```
GET /v1/airports/HND/spots
```

El servidor pide lo que hay dentro del aeropuerto y, además, las
estaciones y paradas a menos de 1,2 km del recinto (muchas están justo
fuera). Se guarda **30 días** en Redis: una sola consulta por aeropuerto al
mes, la usen mil o un millón de personas.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/airport_guide/` | Servidor: estaciones y sitios del aeropuerto |
| `mobile/lib/features/transport/transport_data.dart` | Los bonos de cada ciudad (sin precios) y la calculadora |
| `mobile/lib/features/transport/my_tickets.dart` | Tus billetes, guardados en el móvil |
| `mobile/lib/features/transport/transport_screen.dart` | La pantalla |

## Probarlo en VS Code

Abre la carpeta del proyecto y la terminal (Ver → Terminal):

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_airport_guide.py
cd ../../mobile
flutter test test/transport_test.dart
```
