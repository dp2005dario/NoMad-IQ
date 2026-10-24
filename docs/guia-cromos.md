# Guía para principiantes: Cromos con amigos

Los sellos de tu **Pasaporte** (los monumentos que reconoce la cámara) son
también **cromos**. En esta pantalla haces una **liga** con tus amigos y
competís, os cambiáis cromos y, si queréis, os decís en qué ciudad estáis.
Entra desde Inicio, con el icono de las cartas.

## Las tres pestañas

- **Cambiar**: eliges a un amigo, uno de sus cromos que te falta y uno tuyo
  que él no tiene. Si acepta, **los dos recibís una copia**. Tus cromos de
  verdad siguen siendo tuyos, y las copias no dan puntos de liga (así nadie
  gana a base de cambiar).
- **Liga**: la clasificación del mes. Cuentan los cromos nuevos de este mes:
  común 10 puntos, rara 40, épica 80 y legendaria 150. La rareza es la edad
  del monumento (el Coliseo es legendario; un edificio moderno, común).
- **Amigos**: en qué ciudad está cada uno, **solo si lo activa**. Es la ciudad
  del aeropuerto más cercano, nunca el sitio exacto. Si lo apagas, desaparece.

## Crear o entrar en una liga

"Crear una liga" te da un código de 8 letras (como en Grupo y Gastos). Tus
amigos entran con "Unirme con un código". Hasta 30 personas por liga.

## Privacidad

- Antes de crear o entrar, la app dice lo que se comparte: tu nombre, tus
  cromos (monumento, año y **mes**, nunca el día ni dónde estabas) y cuántos
  países llevas.
- Tus sellos siguen guardados en tu móvil; a la liga solo va esa lista.
- Si sales de la liga (o borras tu cuenta), se borran tus cromos, tu ciudad y
  tus cambios de esa liga.

## Coste 0 €

Solo usa la base de datos (PostgreSQL), con topes: 30 personas por liga,
1.000 cromos por persona y 20 cambios pendientes por persona.

## Dónde está el código

| Archivo | Qué hace |
| --- | --- |
| `services/ai-orchestrator/src/ai_orchestrator/leagues/` | el servidor: reglas, base de datos y la API `/v1/leagues` |
| `services/ai-orchestrator/src/ai_orchestrator/migrations/0011_leagues.sql` | las tablas |
| `mobile/lib/features/cards/` | la app: pantalla y API |
| `services/ai-orchestrator/tests/test_leagues.py`, `mobile/test/cards_test.dart` | las pruebas |

Para probarlo en VS Code: `Terminal > Nuevo terminal`, y luego
`cd mobile` y `flutter test test/cards_test.dart`.

## Glosario

- **Rareza**: lo difícil que es conseguir un cromo.
- **Copia**: el cromo que te dan en un cambio; se ve en "Copias que te han
  dado", pero no cuenta para la liga.
