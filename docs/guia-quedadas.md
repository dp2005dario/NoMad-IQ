# Guía para principiantes: Quedadas de viajeros

Si viajas **solo**, a veces apetece cenar o pasear con alguien. "Quedadas"
es un tablón de planes abiertos de otros viajeros que están **en tu misma
ciudad**: "Cena de ramen hoy a las 20:00, 4 de 6 plazas". Pulsas
**Unirme** y vas.

Se entra desde la pantalla de **Inicio**, en los atajos ("Quedadas").

## Cómo se usa

1. La app adivina la ciudad: la del destino de tu viaje (Modo fácil) o la
   del aeropuerto más cercano a ti (calculado **en el móvil**). Si no puede,
   te pide el código del aeropuerto ("LIS" para Lisboa). Con "Cambiar
   ciudad" eliges otra.
2. Filtra por tipo: Comer, Paseo, Tomar algo, Cultura u Otro.
3. **Unirme** te apunta. Si cambias de idea, pulsa **Vas** y te borras.
4. **Proponer quedada**: qué plan, dónde (siempre un sitio público), qué día
   y a qué hora, y cuántas plazas (2 a 12).
5. **Visible para otros / Estoy oculto**: si vas oculto, los demás ven
   "Alguien" en vez de tu nombre (tu bandera sí se ve, si tienes tu país
   guardado en Visado).
6. En el menú ⋮ de cada quedada: **Cómo llegar** (Google Maps), **Cancelar**
   (si es tuya) o **Denunciar**.

## Seguridad (y por qué no pedimos el DNI)

La maqueta decía "solo gente con identidad verificada". Verificar documentos
de todo el mundo cuesta dinero por persona (y guardar DNIs ajenos es un
riesgo enorme), así que con 0 € hacemos esto otro, que es lo que se puede
cumplir de verdad:

- Hace falta **cuenta**: un invitado no ve ni propone nada.
- **Sitios públicos**: se recuerda al proponer.
- **Tu posición nunca sale del móvil**: al servidor solo le llega el código
  del aeropuerto de la ciudad.
- **Nunca se envía tu id** a los demás: solo tu nombre (o "Alguien") y tu país.
- **Topes**: como mucho 3 quedadas propuestas y 10 apuntadas a la vez.
  Así nadie puede llenar el tablón de anuncios.
- **Denuncias**: con 3 denuncias de personas distintas, la quedada
  desaparece para todos. La misma persona denunciando 100 veces cuenta 1.
- **Se borra sola**: una semana después de la hora de la quedada.
- **Borrar mis datos** (Ajustes) cancela las tuyas y te saca de las demás.

## Las plazas no se "sobrevenden"

Si dos personas pulsan "Unirme" a la vez por la última plaza, el servidor
bloquea esa quedada un instante (`SELECT ... FOR UPDATE` en PostgreSQL):
la primera entra y la segunda recibe "Ya está completa". Es como el último
asiento de un autobús: solo uno se puede sentar.

## Cuánto cuesta (0 €)

Solo usa PostgreSQL, que ya teníamos. No hay mapas de pago ni mensajes:
para hablar, os veis en el sitio.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/migrations/0013_meetups.sql` | Las tablas |
| `services/ai-orchestrator/src/ai_orchestrator/meetups/` | Reglas, base de datos y `/v1/meetups` |
| `services/ai-orchestrator/src/ai_orchestrator/erasure.py` | "Borrar mis datos" también borra quedadas |
| `mobile/lib/features/meetups/meetups_api.dart` | La app habla con el servidor |
| `mobile/lib/features/meetups/meetups_screen.dart` | La pantalla y el formulario de proponer |
| `infrastructure/edge/dynamic.yml` | La puerta de entrada pide cuenta para `/v1/meetups` |

## Probarlo en VS Code

Abre la carpeta del proyecto (Archivo → Abrir carpeta) y en la terminal
(Ver → Terminal):

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_meetups.py
# Con la base de datos de docker compose encendida (make up):
.venv/bin/pytest -m integration tests/test_meetups_integration.py
cd ../../mobile
flutter test test/meetups_test.dart
```
