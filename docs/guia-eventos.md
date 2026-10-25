# Guía para principiantes: Qué pasa en tus fechas (eventos)

Antes de cerrar el viaje conviene saber si en esos días hay un **festivo**
(tiendas y museos que cierran, calles llenas) o un **concierto o partido**
al que te apetecería ir.

Se entra desde **Vuelos**, en los atajos ("Eventos").

## Cómo se usa

1. La ciudad sale del destino de tu viaje (Modo fácil) o la eliges con su
   aeropuerto.
2. Las fechas salen de tu vuelo o las eliges (como mucho un mes).
3. Arriba ves los días del viaje con una barra por día: más alta = más
   cosas ese día; en dorado, los festivos. Tocas un día para ver solo ese.
4. Cada evento tiene su día, hora y sitio; "Entradas" abre la web oficial
   de entradas. La estrella lo guarda (solo en tu móvil).

## Regla: solo datos reales

- **Festivos oficiales** de **Nager.Date** (gratis, sin clave, ~100 países).
- **Conciertos, partidos, teatro...** de **Ticketmaster** (clave gratis). El
  precio que se ve es el que **publica el organizador**; si no lo publica,
  no se pone ninguno.
- Lo que NO está (aunque salía en la maqueta): el precio medio del hotel
  por noche y frases como "hoteles +55 %". No hay datos gratis y
  comprobados para eso, y la app no inventa nada.

Abajo siempre sale de dónde viene cada dato ("Fuentes: ...").

## La clave de Ticketmaster (la pones tú)

1. Crea una cuenta en https://developer.ticketmaster.com y una "app".
2. Copia la **Consumer Key**.
3. Ponla en `infrastructure/.env` como `TICKETMASTER_API_KEY=...` (nunca en
   GitHub ni en el chat).

Sin la clave, la pantalla funciona igual pero solo con festivos (y lo
dice).

## Para miles de usuarios (0 €)

- Festivos: se pregunta **una vez por país y año** y se guarda un mes.
- Eventos: se pregunta **una vez por ciudad y mes** y se guarda 12 horas.
  Da igual cuántas personas miren Lisboa en junio: es una sola pregunta.
- Un tope diario de preguntas a Ticketmaster (por debajo de su cupo
  gratis). Si se llega, la respuesta sale solo con festivos.
- Si una fuente falla, se enseña la otra: nunca una pantalla vacía por un
  error ajeno.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/city_events/` | Servidor: fuentes, caché y `/v1/events` |
| `mobile/lib/features/events/events_api.dart` | La app pide los eventos y los lee |
| `mobile/lib/features/events/events_screen.dart` | La pantalla |
| `infrastructure/edge/dynamic.yml` | La puerta de entrada deja pasar solo `GET /v1/events` |

## Probarlo en VS Code

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_city_events.py
cd ../../mobile
flutter test test/events_test.dart
```
