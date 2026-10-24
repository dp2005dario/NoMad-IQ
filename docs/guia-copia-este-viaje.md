# Guía para principiantes: Copia este viaje

Una pantalla para **copiar el viaje de otra persona** y que Flyra lo adapte a
tu dinero. Entra desde Inicio, con el icono de copiar.

## Cómo se usa

1. Alguien te pasa un código de 8 letras y números (por ejemplo `7K2M-9QXD`).
   Escríbelo como quieras: en minúsculas, con guion o sin él.
2. Ves su viaje: cada cosa que pagó (vuelo, hotel, transporte...) con su
   precio, y cuánta gente lo ha copiado.
3. Elige tu presupuesto: el del original, 3/4 o la mitad. Flyra cambia lo
   caro por opciones más baratas ("Vuelo con escala en Estambul" en vez de
   "Vuelo directo") y te enseña lo que tenía el original tachado.
4. **Copiar a mis viajes** lo guarda en tu móvil.

Para **compartir el tuyo**: botón "Compartir mi viaje". Escribe el título, el
nombre que verán los demás, el destino, los días y lo que pagaste, o pulsa
"Rellenar desde un bote de Gastos" para empezar con tus gastos. Te damos el
código para pasarlo.

## Reglas para que no haya trampas

- Flyra **nunca sube un precio** ni se inventa líneas nuevas: si propone algo
  más caro, el servidor lo descarta.
- Si ni con los cambios cabe en tu presupuesto, la app lo dice en naranja en
  vez de esconderlo.
- Los precios son los que pagó quien lo compartió, y los de Flyra son
  estimaciones: mira el precio real antes de reservar.

## Coste 0 € con miles de personas

- Cada cuenta tiene **10 adaptaciones al día**.
- Las adaptaciones se guardan una semana en Redis: si mil personas copian el
  mismo viaje con el mismo presupuesto, Flyra trabaja **una sola vez** y a las
  demás no les gasta cupo.
- Si el viaje ya cabe en tu presupuesto, ni siquiera se le pregunta a Flyra.
- Como mucho 20 viajes compartidos por persona y 30 líneas por viaje.

## Privacidad

- Solo se comparte lo que escribes en esa pantalla: ni fechas, ni con quién
  fuiste, ni tu cuenta. Los demás ven el nombre que elijas.
- Lo que copias (y cómo lo adaptaste) se guarda **solo en tu móvil**. El
  servidor solo cuenta que lo copiaste, una vez por persona.
- Puedes dejar de compartir cuando quieras, y si borras tu cuenta se borran
  tus viajes compartidos.

## Dónde está el código

| Archivo | Qué hace |
| --- | --- |
| `services/ai-orchestrator/src/ai_orchestrator/shared_trips/` | el servidor: reglas, base de datos, Flyra y la API |
| `services/ai-orchestrator/src/ai_orchestrator/migrations/0010_shared_trips.sql` | las tablas |
| `mobile/lib/features/copy_trip/` | la app: pantallas, API y los viajes copiados en el móvil |
| `services/ai-orchestrator/tests/test_shared_trips.py`, `mobile/test/copy_trip_test.dart` | las pruebas |

Para probarlo en VS Code: `Terminal > Nuevo terminal`, y luego
`cd mobile` y `flutter test test/copy_trip_test.dart`.

## Glosario

- **Caché**: una copia guardada de una respuesta para no tener que calcularla
  otra vez.
- **Cupo**: cuántas veces al día puedes usar algo gratis.
