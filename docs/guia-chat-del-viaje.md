# Guía para principiantes: Chat del viaje (con Flyra dentro)

Un chat para cada viaje en grupo: todos los del viaje y **Flyra**. Se abre
desde el viaje en grupo con el botón de **bocadillos** (arriba a la derecha).
Está abierto desde el primer día, también mientras decidís el destino.

## Cómo se usa

1. La primera vez, Flyra pregunta **"¿Con quién vas?"**:
   - **Solo**: te lleva al chat privado con Flyra.
   - **Amigos**, **Pareja** o **Familia**: Flyra se adapta (en familia busca
     sitios sin cuestas, con bancos y baños; en pareja, planes para dos...).
2. Escribe al grupo como en cualquier chat.
3. Para preguntarle a Flyra, empieza el mensaje por **@Flyra** (o toca el
   botón **@**, o uno de los atajos: "¿dónde cenamos?", "plan si llueve"...).
   Flyra lee los últimos mensajes y contesta **a todos** en el hilo.
4. En el menú (⋮): **Añadir al chat** (el código de invitación del viaje),
   **Tu nombre en el chat** ("Mamá" en vez de "Viajero 2"), cambiar el tipo
   de viaje y **Terminar viaje** (resumen, estrellas y el vídeo de Recuerdos).

## Por qué cuesta 0 € con miles de grupos

| Pieza | Cómo |
|---|---|
| Mensajes nuevos | La app pregunta "¿algo después del nº 1234?" cada 4 s con el chat abierto (cada 15 s si el grupo está callado). Con la app cerrada, no pregunta. |
| Guardarlos | PostgreSQL, con topes: 300 mensajes al día por persona y viaje, 2000 letras por mensaje. |
| Limpieza | Los mensajes de más de 180 días se borran solos. |
| Flyra | Solo trabaja si alguien escribe @Flyra, y gasta el cupo diario de quien pregunta (el mismo que el chat privado). |

Una conexión abierta (WebSocket) por persona serían miles de conexiones
vivas en un servidor gratis. Preguntar cada pocos segundos es una consulta
mínima por índice: el servidor ni se entera.

## Avisos en el móvil (push)

Con la app cerrada, te llega **"Mensajes nuevos en tu viaje"** (y, cuando
los agentes eligen destino, **"¡Ya tenéis destino!"**). Al tocarlo se abre
ese chat o ese viaje.

- Como mucho **un aviso por viaje cada 2 minutos**: si el grupo está
  charlando, no te llena el móvil.
- El aviso va **cifrado** para tu teléfono y no lleva el texto de ningún
  mensaje ni nombres: solo el viaje. El texto lo pone la app en tu idioma.
- Se apagan en **Ajustes → Privacidad → Viajes en grupo**.

Camino: ai-orchestrator (buzón `ai.outbox`) → Kafka
`ai.group-chat-activity.v1` → notifier → Firebase → tu móvil.

## Privacidad

- Solo los miembros del viaje leen el chat. A quien no lo es, el servidor
  le dice que el viaje **no existe**.
- Los mensajes no se escriben en los registros (logs) del servidor.
- Si alguien **borra su cuenta**, sus mensajes se borran; los de los demás se
  quedan, y su asiento sale como anónimo.
- Flyra corre en **nuestro** servidor (Ollama): los mensajes no van a
  ninguna empresa de IA de fuera.

## Glosario

- **Polling (preguntar cada X segundos):** como mirar el buzón cada rato en
  vez de tener al cartero esperando en la puerta.
- **Asiento:** el número de cada persona en el viaje (1, 2, 3...). Los
  mensajes van por asiento, no por cuenta.
- **Cupo diario:** cuántas preguntas a Flyra puede hacer cada persona al día.

## Para tocarlo en VS Code

1. Abre la carpeta `ECLIPTA` (Archivo → Abrir carpeta).
2. App: `mobile/lib/features/group_chat/`. Servidor:
   `services/ai-orchestrator/src/ai_orchestrator/group_chat/` y la tabla en
   `migrations/0014_group_chat.sql`.
3. Pruebas (Terminal → Nuevo terminal):

   ```bash
   cd mobile && flutter test test/group_chat_test.dart
   cd ../services/ai-orchestrator && uv run pytest tests/test_group_chat.py
   ```
