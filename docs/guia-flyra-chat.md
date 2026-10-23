# Guía del chat con Flyra (para principiantes)

Flyra es la IA de NomadIQ. En el chat le puedes preguntar **lo que quieras**:
qué ver en una ciudad, qué meter en la maleta, cómo ir del aeropuerto al
centro, frases útiles en otro idioma… o cualquier curiosidad.

## 0. La idea con una analogía

Imagina una guía turística muy lista que vive en una oficina (nuestro
servidor) y **no tiene memoria**. Cada vez que le preguntas algo, le llevas
también una hoja con lo último que hablasteis (los mensajes anteriores). Ella
la lee, contesta y se olvida. La hoja la guardas tú (tu móvil), nadie más.

Y para que la oficina no cueste dinero, cada persona tiene un **bono de 50
preguntas gratis al día**. Si la guía está desbordada, te dice "vuelve en un
momento" y no te gasta ninguna pregunta del bono.

## 1. Glosario

| Palabra | Qué significa |
|---|---|
| **LLM** | "Modelo de lenguaje grande": el programa que escribe las respuestas. Usamos Llama con **Ollama** en nuestro propio servidor (0 €, nada sale a empresas externas) |
| **Instrucciones de sistema** | Un texto que Flyra lee antes de cada conversación: quién es, cómo hablar, qué no hacer (no inventar precios, avisar de que confirme visados en webs oficiales…) |
| **Cupo diario** | Un contador en **Redis** por persona y día. `INCR` suma 1 de forma atómica: aunque mandes dos preguntas a la vez desde dos móviles, no te cuelas del límite |
| **429** | Respuesta HTTP "demasiadas peticiones": ya gastaste las preguntas de hoy. Lleva `Retry-After` con los segundos hasta medianoche (UTC) |
| **503** | "No disponible": Flyra está ocupada o tardó más de 45 s. Lleva `Retry-After: 30` |

## 2. El viaje de una pregunta

1. Escribes en la app y pulsas Enviar.
2. La app manda `POST /v1/flyra/chat` con los últimos mensajes (máx. 20 y
   12 000 letras), el idioma de la app y, opcionalmente, dónde estás.
3. La puerta de entrada (Traefik) comprueba tu sesión: **solo con cuenta**.
4. El ai-orchestrator gasta una pregunta de tu cupo (Redis).
5. Prepara las instrucciones de sistema + tu conversación y se lo pasa a
   Llama con un tiempo máximo.
6. Si Llama falla o tarda: te devuelve la pregunta al cupo y responde 503.
7. Si contesta: corta la respuesta a 2 000 letras y la devuelve con cuántas
   preguntas te quedan.

**Qué NO se guarda:** la conversación, en ningún sitio del servidor. Los
registros (logs) solo apuntan números: cuántos mensajes y cuántas letras.

## 3. Fichero a fichero

| Fichero | Para qué sirve |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/flyra/domain.py` | Qué forma tiene una pregunta (mensajes, idioma, lugar) y sus límites |
| `services/ai-orchestrator/src/ai_orchestrator/flyra/service.py` | Las instrucciones de Flyra, el cupo en Redis y la llamada al modelo |
| `services/ai-orchestrator/src/ai_orchestrator/api.py` | La ruta `POST /v1/flyra/chat` y los errores 429/503 |
| `infrastructure/edge/dynamic.yml` | La puerta de entrada deja pasar `/v1/flyra/chat` solo con sesión |
| `mobile/lib/features/flyra/flyra_api.dart` | La app: qué mensajes se envían y cómo se guarda el historial |
| `mobile/lib/features/flyra/flyra_chat_screen.dart` | La pantalla del chat |

## 4. Ajustes (variables de entorno del ai-orchestrator)

| Variable | Por defecto | Para qué |
|---|---|---|
| `FLYRA_ENABLED` | `true` | Apagar el chat (la ruta deja de existir) |
| `FLYRA_DAILY_LIMIT` | `50` | Preguntas gratis por persona y día |
| `FLYRA_TIMEOUT_SECONDS` | `45` | Cuánto esperamos a Llama antes de decir "ocupada" |

Necesita `LLM_ENABLED=true` (Ollama) y Redis (`REDIS_HOST`, `REDIS_PASSWORD`).

## 5. Probarlo desde Visual Studio Code

1. Abre la carpeta del proyecto: **Archivo → Abrir carpeta…** → `NoMad-IQ`.
2. Abre el terminal: **Ver → Terminal** (o `` Ctrl+` ``).
3. Pruebas del servidor:
   ```bash
   cd services/ai-orchestrator
   source .venv/bin/activate      # en Windows: .venv\Scripts\activate
   pytest tests/test_flyra.py -q
   ```
4. Pruebas de la app:
   ```bash
   cd mobile
   flutter test test/flyra_test.dart
   ```
5. Con todo levantado en Docker (`infrastructure/`), entra en la app con tu
   cuenta, toca la caja de Flyra en Inicio y pregunta algo.

Extensiones útiles: **Python** y **Pylance** (Microsoft) para el servidor,
**Flutter** y **Dart** para la app.

## 6. Límites honestos

- Flyra **no tiene internet**: no sabe el tiempo de hoy ni precios en
  directo. Para precios reales te manda a la pestaña Vuelos.
- Un modelo pequeño (Llama 3.1 8B) puede equivocarse: por eso la app lo
  avisa debajo del chat.
