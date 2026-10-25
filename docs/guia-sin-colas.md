# Guía para principiantes: Sin colas

La pantalla **Sin colas** (en el **Mapa**, atajo "Colas") te ayuda a no
perder la tarde en una fila:

1. **Cuánta cola hay ahora** en los sitios famosos de tu ciudad.
2. **A qué hora suele haber menos**, y un "recuérdamelo" en el móvil.
3. **Mesa para cenar**: restaurantes cercanos que aceptan reserva, con su
   web o su teléfono.

> Analogía: es como preguntar en voz alta "¿cuánta cola hay?" en un grupo
> de viajeros que ya están en la puerta. Solo sabes lo que te dicen ellos,
> y si nadie contesta, no te lo inventas.

## Regla: nada inventado (y qué cambió respecto a la maqueta)

| En la maqueta | En la app | Por qué |
|---|---|---|
| Barras de afluencia por horas | Barras con lo que **avisan los viajeros** (60 días, 3 o más por hora; gris = sin datos) | La afluencia de Google no se puede usar gratis ni legalmente fuera de Google |
| "≈ 30 min de cola" ahora | La espera que avisaron **2 o más personas** en la última hora y media | Igual: solo datos de gente real |
| "Coger turno virtual" | **Recuérdamelo**: un aviso de tu móvil 10 min antes | No existe un sistema de turnos común a todos los sitios. Lo decimos claro: "no es un turno" |
| Reservar mesa desde la app | Lista de restaurantes que **en OpenStreetMap** dicen aceptar reserva, con botón a **su web** o **llamar** | No hay forma gratis y fiable de reservar en todo el mundo desde la app |

Además hay un botón **"Abrir en Google Maps"**: a veces Google enseña allí
la afluencia en directo. Eso lo pone Google, no nosotros.

## Cómo se usa

1. La ciudad sale de tu GPS (el aeropuerto más cercano a menos de 80 km)
   o del destino de tu viaje (Modo fácil).
2. Tocas un sitio (salen los más visitados de la ciudad, de Wikidata).
3. Ves la espera de ahora (si alguien la avisó), las barras por horas y la
   hora más tranquila del resto del día.
4. Si estás allí, tocas cuánta cola hay: así ayudas al siguiente.
5. Abajo, "Mesa para cenar": web o teléfono de cada restaurante.

## Privacidad

- Los avisos van por **sitio** (su código de Wikidata, por ejemplo
  `Q193208` = Torre de Belém), nunca con tu posición.
- Nadie ve quién avisó. Avisar necesita cuenta (cada persona cuenta una
  vez) y como mucho 20 avisos al día.
- Para los restaurantes al servidor solo va una casilla de ~1 km.
- Si borras tu cuenta, se borran tus avisos.

## Para miles de usuarios (0 €)

- Los avisos son filas pequeñas en PostgreSQL y se borran solos a los 60
  días.
- Los restaurantes vienen de la misma consulta a OpenStreetMap que "Cerca
  de ti" (una semana de caché por casilla): no hay ninguna llamada extra.
- El "recuérdamelo" lo programa el propio móvil: sin servidor.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/queues/` | Servidor: avisos de espera |
| `services/ai-orchestrator/src/ai_orchestrator/migrations/0016_queues.sql` | La tabla de avisos |
| `services/ai-orchestrator/src/ai_orchestrator/nearby/overpass.py` | Restaurantes con reserva (OSM) |
| `mobile/lib/features/queues/queues_screen.dart` | La pantalla |
| `mobile/lib/features/queues/reminders.dart` | El "recuérdamelo" del móvil |

## Probarlo en VS Code

Abre la carpeta `NoMad-IQ` (Archivo → Abrir carpeta) y en la terminal
(Ver → Terminal):

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_queues.py tests/test_nearby.py
cd ../../mobile
flutter test test/queues_test.dart
```
