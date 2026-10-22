# Guía de las audioguías por zona (y de la histéresis del geofencing), explicada desde cero

Esta guía es para alguien que **no ha programado nunca** y quiere entender cómo
NomadIQ consigue que, al llegar a la Plaza Mayor o al Louvre, el viajero tenga
una audioguía lista para escuchar, sin que el sistema se caiga cuando llega un
autobús entero de turistas y sin que la IA sepa quién es nadie.

- Código del geofencing: [`services/geo-engine/src/stream/`](../services/geo-engine/src/stream/)
- Código de las audioguías: [`services/ai-orchestrator/src/ai_orchestrator/audioguides/`](../services/ai-orchestrator/src/ai_orchestrator/audioguides/)
- Contrato del evento: [`proto/nomadiq/geo/v1/events.proto`](../proto/nomadiq/geo/v1/events.proto) (`ZoneEntered`)
- Hechos verificados: [`services/ai-orchestrator/src/ai_orchestrator/migrations/0002_zone_facts.sql`](../services/ai-orchestrator/src/ai_orchestrator/migrations/0002_zone_facts.sql)

---

## 0. La idea con una analogía (sin tecnicismos)

Imagina un **museo enorme** con un portero y una sala de guías:

1. **El portero (geo-engine)** mira por la ventana quién entra. Pero la puerta
   es giratoria y hay gente que se queda justo en el umbral, medio dentro, medio
   fuera. Si el portero gritase "¡ha entrado uno!" y "¡ha salido!" cada vez que
   alguien da medio paso, volvería loco a todo el museo. Por eso tiene dos
   normas: solo cuenta que **has entrado** si sigues dentro **15 segundos**, y
   solo cuenta que **has salido** si te has alejado **más de 30 metros** de la
   puerta. Eso es la **histéresis**.
2. Cuando alguien entra de verdad, el portero manda una **nota anónima** a la
   sala de guías: "ha entrado alguien en la sala de Velázquez, habla español".
   Sin nombre, sin foto, sin decir exactamente dónde estaba. Eso es el evento
   `ZoneEntered`.
3. **La sala de guías (ai-orchestrator)** tiene una **estantería** (Redis) con
   folletos ya escritos, uno por sala e idioma. Si el folleto de "Velázquez en
   español" ya está, no hace nada: el visitante lo cogerá de la estantería.
   Si no está, **un solo guía** lo escribe (aunque lleguen 50 notas a la vez) y
   lo deja en la estantería para todos.
4. El guía no escribe de memoria: tiene una **ficha de datos comprobados**
   (`ai.zone_facts`). Un revisor lee lo que escribe y, si ve una fecha que no
   está en la ficha, se lo devuelve. Si el guía está de baja (Ollama apagado),
   un becario monta el folleto **copiando la ficha tal cual** (plan B por reglas).
5. Quien entrega el folleto al visitante concreto (la **capa de
   notificaciones**, futura) es el único que sabe quién es quién.

---

## 1. Problema 1: la tormenta de avisos en el borde (histéresis)

### Qué pasaba antes

El GPS de un móvil nunca está quieto: aunque no te muevas, la posición "baila"
entre 5 y 30 metros. Si caminas por la acera de enfrente del Prado, justo por el
borde de la zona, el sistema veía: dentro, fuera, dentro, fuera... y publicaba
`ENTER`, `EXIT`, `ENTER`, `EXIT`. Cada `ENTER` despertaría a la IA para nada.

### La solución: dos umbrales distintos

Es la misma idea que un **termostato**: la calefacción se enciende a 19 °C y se
apaga a 21 °C. Si usara la misma temperatura para las dos cosas, se encendería
y apagaría cada minuto. En electrónica se llama **disparador de Schmitt**.

| Regla | Variable | Por defecto | Qué significa |
|---|---|---|---|
| Para **entrar** | `GEOFENCE_ENTER_DWELL` | `15s` | Hay que estar dentro del polígono y **seguir dentro** 15 segundos. Mientras tanto la zona está "pendiente" y no se avisa a nadie. |
| Para **salir** | `GEOFENCE_EXIT_MARGIN_M` | `30` | Hay que alejarse **más de 30 m** del borde. Si el GPS tiene una precisión peor (por ejemplo ±80 m), se usa esa precisión: no damos por buena una salida si el círculo de incertidumbre todavía toca la zona. |

Entre los dos umbrales hay una **franja muerta**: moverse por ella no cambia
nada. El test `el_gps_bailando_en_el_borde_no_genera_tormenta` (en
`geofence.rs`) simula exactamente eso: cuatro saltos de GPS en el borde y
**cero** eventos.

### Detalles que conviene saber explicar en una entrevista

- **El reloj es el del GPS**, no el del servidor: el tiempo dentro se mide con la
  marca de tiempo de cada posición. Así funciona igual aunque Kafka vaya con
  retraso.
- **El estado se guarda en Redis** (`geo:presence:v1:<usuario>`). Ahora tiene una
  versión 2 con la lista `pending` (zonas a la espera de confirmar). Los estados
  antiguos (versión 1) se siguen leyendo: `#[serde(default)]` rellena `pending`
  con una lista vacía. Desplegar no "olvida" dónde está nadie.
- **Una entrada fugaz se olvida sin avisar**: si sales antes de los 15 s, la
  zona pendiente se descarta. Si vuelves, el reloj empieza de cero.
- **Distancia al borde**: `ZoneRecord::distance_m` busca el punto del contorno
  más cercano y mide la distancia geodésica real hasta él.

---

## 2. Problema 2: la privacidad (la IA no sabe quién eres)

El geo-engine publica ahora **dos** eventos por cada entrada confirmada:

| Topic | Mensaje | Lleva | Clave Kafka | Quién lo lee |
|---|---|---|---|---|
| `geo.geofence-transitions.v1` | `GeofenceTransitioned` | usuario, zona, posición | `user_id` | capa de notificaciones (futura) |
| `geo.zone-entries.v1` | `ZoneEntered` | **solo** `zone_id`, tipo de zona e idioma | `zone_id` | ai-orchestrator |

Medidas de **minimización de datos** (RGPD) en `ZoneEntered`:

- Sin `user_id`, sin coordenadas, sin precisión del GPS, sin id de la posición.
- El `event_id` es **aleatorio** (UUID v4). Si se calculase a partir de la
  posición (como el de `GeofenceTransitioned`), alguien con acceso a otros
  topics podría recalcularlo y saber de quién es.
- La hora va **redondeada al minuto** y sin `correlation_id`.
- El idioma va **recortado**: `"en-GB"` → `"en"`. La región es un dato más sobre
  la persona que no hace falta para elegir idioma.
- Se guarda solo **24 horas** en Kafka.

Riesgo residual (honestidad ante un comité técnico): quien pudiera leer **a la
vez** los dos topics podría intentar cruzar "misma zona, mismo minuto" en zonas
con muy poca gente. Por eso, en producción, el ai-orchestrator solo tiene
permiso de lectura (ACL de Kafka) sobre `geo.zone-entries.v1`: **mínimo
privilegio**.

El idioma lo envía la app en el campo nuevo `preferred_language` de
`UserPositionReported` (número 5: en protobuf solo se **añaden** campos, así las
apps antiguas siguen funcionando).

---

## 3. Problema 3: el autobús de turistas (thundering herd)

### El riesgo

Llegan 50 personas a la vez a la Plaza Mayor. Si cada una pidiera su guion al
LLM, Ollama recibiría 50 peticiones idénticas, la GPU se saturaría y todos
esperarían minutos (o se caería por falta de memoria).

### La solución, en capas (de la más barata a la más cara)

1. **El guion es genérico**: depende de la zona y del idioma, no de la persona.
   Se guarda en Redis con la clave `ai:audioguide:v2:<zone_id>:<idioma>:<versión>`
   (la versión del contenido se explica en el apartado 4 bis).
2. **Clave de Kafka = `zone_id`**: todas las entradas a una zona van a la misma
   partición y las procesa UN consumidor.
3. **El lote se agrupa**: si en un lote de Kafka hay 30 entradas a la misma zona
   e idioma, se convierten en UN trabajo (`merged_in_batch`).
4. **Single flight en el proceso** (`SingleFlight`): si dos tareas piden la
   misma clave a la vez, la segunda espera el resultado de la primera. Analogía:
   si alguien ya ha ido a por el pan, no vas tú también.
5. **Cerrojo distribuido en Redis** (`SET ... NX EX`): si hay varias copias del
   servicio, solo una genera; las demás ven `BUSY_ELSEWHERE`. El cerrojo caduca
   solo (si quien lo tenía se cae, no queda bloqueado) y se suelta con un script
   Lua que comprueba que sigue siendo nuestro.

El test `test_a_bus_full_of_tourists_triggers_one_generation` lanza 50 entradas
a la vez y comprueba que el LLM se llama **una sola vez**. En la prueba local
con Kafka real se enviaron 50 eventos y el log mostró **una** generación.

### Y la latencia (riesgo 1 del análisis)

Todo esto ocurre en **segundo plano**: un consumidor de Kafka con su propio grupo
(`ai-orchestrator-audioguides`), separado del de las alertas de precio para que
uno no frene al otro. La app nunca espera al LLM: consulta
`GET /v1/audioguides/{zone_id}?lang=es`, que **solo lee la caché**. Si aún no
está, responde 404 ("aún no está lista") y la app vuelve a preguntar en unos
segundos. Además se puede **pregenerar** todo por la noche:

```bash
uv run python -m ai_orchestrator --pregenerate-audioguides es,en
```

---

## 4. Problema 4: que la IA no se invente cosas (grounding)

- Los hechos viven en la tabla `ai.zone_facts` (por slug de zona e idioma),
  escritos y revisados por personas. Hay hechos de ejemplo para las zonas de
  demostración en español e inglés.
- Al LLM se le pasan con etiquetas: `F1`, `F2`... Debe responder un JSON con un
  título y párrafos, y **cada párrafo dice qué hechos usa**.
- `guide_problems` (en `writer.py`) rechaza el borrador si:
  - cita un hecho que no existe;
  - escribe un **número que no aparece en los hechos que ese párrafo cita**
    (la fecha inventada es el error más típico);
  - mete un enlace, se pasa de 260 palabras o usa menos de 2 hechos.
- Si falla, se le explica el motivo y lo intenta otra vez (máximo 3).
- **Plan B (reglas)**: si Ollama no está o no acierta, el guion se monta con una
  plantilla de bienvenida + los hechos **tal cual** + despedida. Ese guion dura
  solo 1 hora en la caché (el del LLM, 24 horas) para reintentar pronto con el LLM.
- Si piden un idioma sin hechos traducidos (por ejemplo francés), el LLM traduce
  los hechos del idioma por defecto; el plan B, en cambio, escribe en el idioma
  de los hechos y lo indica en `content_language`.
- Idiomas admitidos: es, en, fr, de, it, pt. Cualquier otro → `AUDIOGUIDE_DEFAULT_LANGUAGE`
  (así nadie puede llenar Redis inventándose idiomas).
- Aeropuertos y zonas restringidas no tienen audioguía (`NOT_NARRATED`).

---

## 4 bis. Problema 5: si corriges un hecho, ¿cuándo se entera la audioguía?

### El riesgo

El guion se guardaba 7 días en Redis. Si alguien corregía un horario mal puesto
en `ai.zone_facts`, los turistas seguían oyendo el dato viejo **hasta una
semana**. En una audioguía eso es un error visible.

### Las dos ideas que se descartaron (y por qué)

- **Poner la huella (hash) de los hechos en la clave**: para calcularla hay que
  leer todos los hechos de PostgreSQL en **cada** entrada a la zona. Mil turistas
  en la Puerta del Sol = mil consultas: una "tormenta de consultas".
- **Un topic de Kafka para avisar de "borra esta clave"**: funciona, pero añade
  un productor, un consumidor y una DLQ más para un problema pequeño.

### La solución elegida: un número de versión por zona

Analogía: es como la **edición de un libro**. Si corriges una errata no
tachas los libros ya impresos: sacas la "2ª edición" y la librería pide esa.
Los ejemplares viejos se quedan en el almacén hasta que se tiran.

1. **Tabla `ai.zone_content`** (migración `0003`): cada zona tiene un número
   `content_version`. Un **trigger** de PostgreSQL lo sube solo cada vez que
   alguien añade, cambia o borra un hecho de esa zona. Da igual quién lo haga
   (una migración, un `psql` a mano, un futuro panel): las personas se olvidan
   de "acuérdate de subir la versión"; la base de datos no.
2. **La versión va en la clave**: `ai:audioguide:v2:<zona>:<idioma>:<versión>`.
   Al subir la versión, la clave nueva está vacía → se genera un guion nuevo.
   El viejo no hay que borrarlo: nadie lo vuelve a pedir y caduca solo.
3. **La versión se recuerda en memoria 60 segundos** (`ZoneVersionCache`, en
   `versions.py`): cada réplica pregunta a PostgreSQL como mucho **una vez por
   zona y minuto**, entre o no entre gente. Leer un entero por clave primaria
   cuesta microsegundos. Si dos tareas preguntan a la vez, solo una consulta
   (*single flight*), y también se recuerda "esta zona no existe" para que un
   `zone_id` inventado no pueda martillear la base de datos.
4. **TTL del guion del LLM: de 7 días a 24 horas**, como red de seguridad.
5. **Hechos y versión se leen en la misma foto** de la base de datos (una
   transacción `REPEATABLE READ` de solo lectura) y el guion se guarda con la
   versión **de la que salió**. Si alguien corrige un hecho justo mientras se
   escribe el guion, nunca acabará un texto viejo guardado con la versión nueva.

Resultado: tras corregir un hecho, el guion nuevo se usa en **60 segundos como
mucho** (antes, hasta 7 días). Es *consistencia eventual* con una ventana corta y
conocida. Se ajusta con `AUDIOGUIDE_VERSION_CACHE_SECONDS`.

Pruébalo: en VS Code abre una terminal (**Terminal → Nueva terminal**) y ejecuta

```bash
make audioguides   # verás claves que acaban en :1
cd infrastructure && docker compose exec postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "UPDATE ai.zone_facts SET fact = fact WHERE zone_slug = '"'"'madrid-centro'"'"' AND language = '"'"'es'"'"' AND position = 1"'
```

y, al minuto, la siguiente entrada a `madrid-centro` deja una clave nueva acabada
en `:2`. (El trigger suma uno **por cada fila** tocada: si un `UPDATE` cambia
tres hechos, la versión salta de golpe tres números. No pasa nada: lo único que
importa es que el número nunca baja ni se repite.) Los tests `test_fixing_a_fact_produces_a_new_script_without_waiting_for_the_ttl`
y `test_editing_facts_bumps_the_zone_content_version` comprueban justo esto.

---

## 5. El recorrido completo

```text
móvil ── posición + idioma ──► geo.user-positions.v1
                                   │
                          geo-engine (Rust)
                     histéresis: 15 s dentro / 30 m fuera
                         │                         │
       geo.geofence-transitions.v1        geo.zone-entries.v1  (ANÓNIMO)
        (user_id: notificaciones)          clave = zone_id
                                                   │
                                  ai-orchestrator: ZoneEntryConsumer
                                   agrupa el lote → caché → single flight → cerrojo
                                                   │
                         hechos (ai.zone_facts) → LLM anclado o reglas
                                                   │
                               Redis  ai:audioguide:v2:<zona>:<idioma>:<versión>
                                                   ▲
                  app / notificaciones ── GET /v1/audioguides/<zona>?lang=es
```

La CI comprueba este recorrido entero con los contenedores reales: el test e2e
del geo-engine mete a un usuario en la Puerta del Sol y, después, la CI pide la
audioguía de `madrid-centro` a la API (sin Ollama: sale por reglas).

---

## 6. Cómo probarlo en tu ordenador con Visual Studio Code

1. Abre VS Code → **Archivo → Abrir carpeta…** → elige la carpeta `NoMad-IQ`.
2. Extensiones recomendadas (VS Code te las ofrece al abrir la carpeta):
   **rust-analyzer** (Rust), **Python** y **Pylance**, **Docker**, **Buf** (protobuf).
3. Abre la terminal integrada: **Terminal → Nuevo terminal** (o `` Ctrl+ñ `` /
   `` Ctrl+` ``).
4. Arranca todo:

   ```bash
   make up-apps          # Kafka, PostgreSQL, Redis y los microservicios
   ```

5. Simula un viajero en la Puerta del Sol con el test e2e del geo-engine:

   ```bash
   cd services/geo-engine
   GEO_ENGINE_GRPC=http://127.0.0.1:50052 cargo test --test integration e2e_geofencing -- --ignored
   cd ../..
   ```

6. Mira las audioguías que se han guardado en Redis:

   ```bash
   make audioguides
   ```

7. Pide una a la API (en local no hace falta mTLS). Cambia `<zone_id>` por el
   que veas en el paso anterior:

   ```bash
   curl -s "http://127.0.0.1:8085/v1/audioguides/<zone_id>?lang=es" \
     -H 'X-User-ID: yo' -H 'X-User-Roles: USER' | jq .
   ```

8. ¿Quieres que redacte el LLM de verdad? `make ollama` (descarga el modelo, varios
   GB) y vuelve a pedirla cuando caduque la versión de reglas (1 hora), o borra
   la clave de Redis para forzarlo.

Para cambiar la histéresis, en `infrastructure/.env` añade por ejemplo
`GEOFENCE_ENTER_DWELL=30s` o `GEOFENCE_EXIT_MARGIN_M=50` y vuelve a `make up-apps`.

---

## 7. Qué falta (próximos pasos)

- **Síntesis de voz** (texto → audio): un motor TTS local y gratuito (por ejemplo
  Piper) que convierta el guion en un MP3/Opus por zona e idioma, guardado en un
  almacén de objetos y servido por CDN. El guion ya está partido en párrafos de
  20-30 segundos, que es justo lo que se necesita para empezar a reproducir el
  primero mientras se descargan los siguientes (*streaming*).
- **Capa de notificaciones**: leer `geo.geofence-transitions.v1` (que sí trae el
  usuario), comprobar que la audioguía está lista y mandar el push al móvil.
- **Panel de hechos**: una API de administración para dar de alta y revisar
  hechos por zona (hoy van en migraciones SQL).
- **ACLs de Kafka** por servicio en producción (mínimo privilegio real).

---

## 8. Glosario

| Término | Explicación sencilla |
|---|---|
| **Geofencing** | "Valla virtual": detectar cuándo alguien entra o sale de una zona del mapa. |
| **Histéresis** | Usar umbrales distintos para encender y para apagar, para que el ruido no provoque cambios continuos (como un termostato). |
| **Dwell time** | Tiempo mínimo que hay que permanecer dentro para que la entrada cuente. |
| **Franja muerta** | La zona entre los dos umbrales, donde moverse no cambia el estado. |
| **Thundering herd** (estampida) | Muchas peticiones idénticas a la vez que saturan un recurso caro. |
| **Single flight** | Técnica para que muchas peticiones iguales simultáneas se resuelvan con una sola ejecución. |
| **Cerrojo distribuido** | Una "llave" en Redis que solo puede tener una copia del servicio a la vez. |
| **TTL** | *Time to live*: cuánto tiempo vive un dato en la caché antes de borrarse solo. |
| **Versión de contenido** | Un número por zona que sube cada vez que cambian sus hechos; va en la clave de caché para que un cambio cree una clave nueva. |
| **Trigger** | Código que la base de datos ejecuta sola cuando pasa algo en una tabla (aquí: al tocar un hecho, sube la versión). |
| **Consistencia eventual** | El sistema acaba mostrando el dato nuevo, pero no al instante: aquí, en 60 s como mucho. |
| **Invalidación de caché** | Hacer que la caché deje de servir un dato que ya no es correcto. |
| **Grounding** (anclaje) | Obligar a la IA a basarse solo en datos verificados que le damos. |
| **Alucinación** | Cuando un modelo de IA se inventa algo y lo dice con seguridad. |
| **Minimización de datos** | Principio del RGPD: tratar solo los datos personales imprescindibles. |
| **Clave de partición (Kafka)** | El valor que decide a qué partición va un mensaje; misma clave = misma partición = mismo consumidor. |
| **DLQ** | *Dead letter queue*: buzón donde van los mensajes que no se pueden procesar, para revisarlos sin bloquear al resto. |
| **TTS** | *Text to speech*: convertir texto en voz. |
