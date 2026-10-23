# Guía de las notificaciones push, explicada desde cero

Esta guía es para alguien que **no ha programado nunca** y quiere entender cómo
NomadIQ avisa en el móvil ("Estás en el centro de Madrid: ¿escuchas la
audioguía?") sin tres problemas: llenar el teléfono de avisos al pasear,
construir sin querer una base de datos de "quién estuvo dónde", y quedarse sin
la cuota gratuita de Google cuando 10.000 personas llegan a la vez a la Sagrada
Familia.

- Código del servicio: [`services/notifier/`](../services/notifier/) (Go)
- Dónde nace la orden: [`services/geo-engine/src/stream/notify.rs`](../services/geo-engine/src/stream/notify.rs) (Rust)
- Contrato del evento: [`proto/nomadiq/notify/v1/events.proto`](../proto/nomadiq/notify/v1/events.proto) (`ZoneNotificationRequested`)
- Detalle técnico y configuración: [`services/notifier/README.md`](../services/notifier/README.md)

---

## 0. La idea con una analogía (sin tecnicismos)

Imagina un **hotel** con una conserjería que deja notas en las habitaciones:

- El **recepcionista** (el geo-engine) ve entrar a los huéspedes. Sabe quién es
  cada uno, porque es su trabajo.
- Cuando alguien llega a una sala del hotel, el recepcionista no le dice al
  conserje "Ana García acaba de entrar en el spa". Le pasa una tarjeta que dice
  **"Habitación 4F7A: ha llegado al spa"**. El número de habitación sale de una
  tabla secreta que solo tienen el recepcionista y el conserje.
- El **conserje** (el notifier) mira qué buzones tiene la habitación 4F7A (los
  teléfonos de esa persona) y deja una nota en un **sobre cerrado con un
  candado** que solo abre la llave de esa habitación. El cartero (Google)
  reparte el sobre, pero no puede leerlo.
- El conserje sigue dos normas de cortesía: **no más de una nota cada 45
  minutos** por habitación, y **nunca dos notas sobre la misma sala el mismo
  día**. Una nota de "¡cuidado, zona peligrosa!" sí se salta la primera norma.
- El cartero solo admite 50 sobres por segundo en la ventanilla. Si llegan
  10.000 a la vez, el conserje los pone en una **cola** y los entrega a ese
  ritmo, en vez de presentarse con una montaña que el cartero rechazaría.

Eso es todo el diseño. El resto de la guía explica cada pieza.

---

## 1. Problema 1: el paseo por zonas contiguas (spam)

### El riesgo

En un centro histórico las zonas están pegadas o una dentro de otra: el centro
de Madrid contiene la Puerta del Sol, la Plaza Mayor y el Palacio Real. Si cada
entrada genera un aviso, en 15 minutos de paseo llegan tres o cuatro, y la
persona acaba **desactivando las notificaciones** (y ya no podemos avisarla de
nada, ni siquiera de algo importante).

### La solución, en tres capas

1. **En origen (geo-engine):** si una sola posición GPS te mete en varias zonas
   a la vez (el centro *y* la Puerta del Sol), se pide **un único aviso**, el
   de la zona más concreta. Orden: zona restringida > zona turística >
   aeropuerto > centro de ciudad.
   ([`notify.rs`](../services/geo-engine/src/stream/notify.rs), `notify_priority`).
2. **En el notifier, con Redis**, dos reglas:
   - **Enfriamiento** (`NOTIFY_COOLDOWN`, 45 min): tras un aviso, silencio para
     esa persona. Los avisos de **seguridad** (zona restringida) se lo saltan.
   - **No repetir zona** (`NOTIFY_ZONE_REPEAT_WINDOW`, 24 h): aunque salgas y
     vuelvas a entrar, esa zona no se vuelve a anunciar ese día.
3. **En Google (FCM):** todos los avisos llevan la misma `collapse_key`. Si el
   teléfono estaba sin cobertura y se acumulan varios, Google entrega **solo el
   último**.

Además, la histéresis del geo-engine (ver la [guía de audioguías](guia-audioguias.md))
ya evita los avisos falsos cuando el GPS "baila" en el borde de una zona.

### Por qué un script Lua y no dos consultas

Las dos reglas se comprueban **y** se apuntan en un único script Lua que Redis
ejecuta de forma **atómica** (nadie puede colarse entre medias). Con dos
consultas separadas, dos entradas casi simultáneas podrían leer "no hay
enfriamiento" a la vez y mandar dos avisos. Además, los avisos de una persona
llegan siempre a la misma partición de Kafka (la clave es su seudónimo), así
que se procesan en fila, uno detrás de otro.

### ¿Y lo que no se avisa?

Gemini propuso apuntar en la base de datos la transición silenciada "para la
app". No lo hacemos: guardar "esta persona entró en esta zona a esta hora"
es justo el historial que queremos evitar (problema 2). La app ya sabe dónde
está (es ella quien envía la posición), así que si quiere mostrar "zonas
cercanas" lo calcula en el propio teléfono.

---

## 2. Problema 2: no convertir el notifier en un mapa de quién estuvo dónde

### El riesgo

Para avisar hay que saber **a quién**. Si el servicio de avisos recibe
`user_id` + zona + hora, y además guarda el token del teléfono, se convierte en
la base de datos más sensible del sistema: un historial de movimientos de cada
persona. Es lo primero que mira una auditoría del RGPD y lo más jugoso para un
atacante.

### La solución: el notifier es un intermediario ciego

| Qué podría ver | Qué ve de verdad |
|---|---|
| `user_id` | Un **seudónimo**: `HMAC-SHA256(clave, user_id)`, 43 caracteres. Sin la clave no se puede volver atrás ni comprobar "¿será Ana?" |
| Coordenadas, precisión del GPS | **Nada**. El notifier no lee el topic que las lleva (`geo.geofence-transitions.v1`) |
| Nombre de la zona | Solo su `zone_id` (un UUID) y el tipo |
| Hora exacta | Redondeada al minuto, con un id de evento aleatorio |
| Token de FCM | Guardado **cifrado** (AES-256-GCM) y con un "índice ciego" (HMAC) para detectar duplicados |
| Contenido del aviso | Se cifra **para el teléfono** en cuanto se crea; ni la base de datos ni Google pueden leerlo |
| Historial de avisos | **No existe**: la cola se vacía en minutos y no queda registro |
| Redis | Claves con nombres opacos (HMAC) que caducan solas |
| Logs | Solo "aviso encolado, plantilla X, N teléfonos". Nunca seudónimos ni zonas |

**¿Dónde vive la relación usuario ↔ teléfono?** Gemini proponía un servicio de
perfil aparte. Aquí la tabla `notify.devices` vive en el notifier, pero **sin
user_id**: guarda seudónimo ↔ teléfono. Es la "tabla de taquillas" de la
analogía. El notifier solo ve un user_id real durante un instante: cuando la app
registra el teléfono (la petición llega con el user_id ya verificado por el
auth-gateway). Calcula el seudónimo, lo guarda y se olvida del user_id.

### El sobre con candado: cifrado de extremo a extremo (HPKE)

Al instalarse, la app genera un **par de claves** X25519 y nos da solo la
**pública** (el candado abierto). Cada aviso se cifra con HPKE (RFC 9180, el
mismo estándar que usan los avisos web y la mensajería moderna) para esa
clave. Solo el teléfono tiene la privada (la llave). Consecuencias:

- **Google no puede leer el aviso.** Solo ve un campo `p` con bytes cifrados.
- **Una fuga de la base de datos no revela qué se avisó a quién.**
- Cada aviso usa una clave efímera nueva, que el notifier tira al instante:
  ni el propio notifier puede volver a abrir un aviso que ya envió, y dos
  avisos iguales no se parecen en nada cifrados.
- Lo que HPKE **no** da por sí solo: si alguien robara la llave del teléfono,
  podría abrir los avisos antiguos que hubiera guardado. Por eso la app debe
  crear un par de claves **nuevo cada vez que se registra** (al abrirse) y tirar
  el anterior: así una llave robada solo sirve para unas horas de avisos.
- El `device_id` va "atado" al cifrado: un aviso copiado a otro teléfono no se abre.

Comprobado en los tests: nuestro cifrado coincide byte a byte con el **vector
oficial del RFC 9180** (`TestSealMatchesRFC9180Vector`). Por eso la app podrá
usar otra librería de HPKE (Tink, en Android) y abrirá los avisos igual.

### Dos claves, cada una para lo suyo

- `NOTIFY_PSEUDONYM_KEY`: calcula los seudónimos. La comparten el geo-engine y
  el notifier (si no fuera la misma, los avisos no encontrarían a nadie; hay un
  test en Go y otro en Rust con el mismo resultado exacto).
- `NOTIFY_TOKEN_KEY`: solo del notifier. De ella salen, con HKDF, tres
  subclaves independientes: cifrar tokens, índice ciego y nombres de Redis.

El notifier se niega a arrancar si las dos claves son iguales.

---

## 3. Problema 3: los límites de Firebase ante una avalancha

### El riesgo

FCM es gratis, pero tiene límites de ritmo. Si 10.000 turistas entran a la vez
en un concierto y mandamos 10.000 peticiones en un segundo, Google responde
**429 ("más despacio")**, se pierden avisos, y un consumidor de Kafka atascado
esperando a Google retrasa todo lo que viene detrás.

### La solución: cola + obreros + cubo de fichas

```
Kafka ──► intake (rápido: valida, anti-spam, cifra) ──► PostgreSQL (cola)
                                                            │
                                    sender: despachador ────┘
                                       │   (FOR UPDATE SKIP LOCKED, préstamo)
                                       ▼
                              8 obreros ── cubo de fichas (50/s) ──► FCM
                                              ▲
                                     429 → frenazo para TODOS
```

- **Nunca se llama a Google desde el consumidor de Kafka.** El intake solo deja
  el aviso en la cola y sigue con el siguiente mensaje. Entrar es rápido;
  salir va al ritmo que marque el limitador.
- **Cubo de fichas (token bucket):** se rellena a 50 fichas por segundo y cada
  envío gasta una. Si no hay fichas, el obrero espera. Da igual cuántos
  obreros haya: el ritmo total no se pasa.
- **429 → frenazo global:** si Google pide ir más despacio, se paran todos los
  obreros el tiempo que diga su cabecera `Retry-After`, no solo el que lo recibió.
- **Reintentos con espera creciente** (2 s, 4 s, 8 s...) para los fallos
  temporales (503).
- **Caducidad:** un aviso que no se pudo entregar en 10 minutos se tira
  ("acabas de llegar" con una hora de retraso molesta más que ayuda). La misma
  caducidad se le pasa a Google como `ttl`.
- **App desinstalada:** si Google responde `UNREGISTERED`, se borra el teléfono
  y sus avisos pendientes.

**Medido en local:** 300 personas llegan a la Sagrada Familia en el mismo
instante → el primer aviso llega a los 0,3 s y los 300 están entregados en
8,3 s, sin pasar nunca de 50 por segundo.

**¿Y el "pull" en vez de "push"?** Los avisos ya son mensajes **de datos**
(silenciosos): Google despierta a la app, y es la app quien decide qué mostrar
y en qué idioma. Además, como cada zona tiene su audioguía pregenerada, la app
puede descargar el manifiesto de las zonas cercanas al abrirse y no depender
del aviso para tenerla lista.

---

## 4. El recorrido completo

1. La app manda la posición GPS → Kafka `geo.user-positions.v1`.
2. El geo-engine confirma la entrada (histéresis), elige la zona más concreta y
   publica en `notify.zone-requests.v1`: seudónimo, `zone_id`, tipo, idioma y
   hora al minuto. **Nada más.**
3. El notifier lo lee, descarta lo viejo o mal formado (DLQ), decide la
   plantilla (`zone_audioguide`, `airport_arrival` o `zone_safety`), busca los
   teléfonos del seudónimo, pasa el anti-spam, cifra para cada teléfono y lo
   deja en la cola.
4. El sender lo coge de la cola y lo entrega a FCM a ritmo controlado.
5. Google despierta a la app con el campo `p` cifrado. La app lo descifra con
   su clave privada, ve `{"type":"zone_audioguide","zone_id":"…"}`, pide a la
   API el nombre y la audioguía de la zona y muestra el aviso en su idioma.

### 4 bis. Alertas de precio de vuelos

Cuando vigilas un vuelo en la app (por ejemplo Madrid → Lisboa el 2 de
diciembre) y el price-consumer detecta que ha bajado, publica una alerta en
`flights.fare-alerts.v1`. El notifier también la lee:

1. Llega con tu **user_id real** (así la publica el price-consumer). El
   notifier calcula tu seudónimo en ese instante y se olvida del user_id: no
   lo guarda en la base de datos, ni en Redis, ni en los logs.
2. **No hay enfriamiento:** si pediste que te avisemos de un vuelo, te
   avisamos aunque hace 10 minutos te contáramos lo de la plaza. Y al revés:
   la alerta tampoco "gasta" tu enfriamiento de zonas.
3. **Nunca suena dos veces:** Kafka puede entregar la misma alerta dos veces
   (por ejemplo, tras un reinicio). Redis apunta `fare:<id de la alerta>`
   durante 24 h y el segundo intento se descarta.
4. **Caduca más tarde:** una tarifa error merece la pena aunque enciendas el
   teléfono dentro de unas horas, así que Google la guarda hasta 6 h (los
   avisos de zona, 10 min). Una alerta de hace más de 6 h ya no se avisa: el
   precio probablemente cambió.

Lo que recibe la app (cifrado, Google no lo ve):
`{"type":"fare_alert","alert_type":"error_fare","origin":"MAD","destination":"NRT","departure":"2027-03-15","price":{"amount_minor":31500,"currency":"EUR"},"drop_bp":6500,…}`.
La app escribe "Posible tarifa error · Madrid → Tokio: 315 € (−65 %)" en tu
idioma y, al tocarlo, abre tus alertas de vuelos.

---

## 5. Cómo probarlo en tu ordenador con Visual Studio Code

1. Abre VS Code → **Archivo → Abrir carpeta…** → elige la carpeta `NoMad-IQ`.
2. Extensiones recomendadas: **Go** (de Google), **rust-analyzer**, **Docker**
   y **Buf**. VS Code las ofrece al abrir la carpeta; con la de Go podrás
   pulsar "run test" encima de cada test.
3. Abre la terminal integrada: **Terminal → Nuevo terminal** (o `` Ctrl+ñ `` /
   `` Ctrl+` ``).
4. Crea las dos claves (solo la primera vez; no toca las que ya tengas):

   ```bash
   make keys
   ```

5. Arranca todo (incluye el notifier y un **FCM falso** que hace de Google):

   ```bash
   make up-apps
   ```

6. Haz de "teléfono" con el test de punta a punta: genera sus claves, se
   registra, publica posiciones en la Puerta del Sol y luego en la Sagrada
   Familia, y comprueba que llega **un** aviso que solo él sabe abrir:

   ```bash
   cd services/notifier
   NOTIFIER_E2E=1 go test -tags integration -count=1 -v -run TestPushNotificationEndToEnd ./internal/e2e/
   cd ../..
   ```

   Verás una línea como
   `aviso descifrado por el teléfono: {"v":1,"type":"zone_audioguide",…}`.

   Para la alerta de precio (publica una alerta falsa dos veces y comprueba
   que suena una):

   ```bash
   cd services/notifier
   NOTIFIER_E2E=1 go test -tags integration -count=1 -v -run TestFareAlertPushEndToEnd ./internal/e2e/
   cd ../..
   ```

7. Mira lo que "vio Google" (solo bytes cifrados) y el estado de la cola:

   ```bash
   make push-messages
   make notifier-devices
   ```

8. Prueba tú el descifrado a mano con la herramienta `notifyctl`:

   ```bash
   cd services/notifier
   go run ./cmd/notifyctl keygen     # crea un par de claves de "teléfono"
   ```

9. Tests unitarios (sin Docker) y de integración:

   ```bash
   make test              # incluye services/notifier
   make test-integration  # incluye PostgreSQL y Redis reales del notifier
   ```

---

## 6. Qué falta (próximos pasos)

- **La app móvil:** generar las claves en el Android Keystore, registrar el
  teléfono al abrirse, descifrar con Tink (HPKE) y mostrar el aviso.
- **Preferencias del usuario:** horas de silencio, desactivar por tipo de aviso.
  Lo ideal es que las aplique la propia app (no hace falta mandarlas al servidor).
- **ACL de Kafka:** que el notifier solo pueda leer `notify.zone-requests.v1` y
  `flights.fare-alerts.v1` y escribir en sus DLQ (hoy, en local, no hay ACL).
- **Ritmo global con varias copias:** el cubo de fichas es por copia; con 3
  copias el ritmo total es 3 × 50/s. Si hiciera falta un límite común, el cubo
  se puede mover a Redis.
- **iOS:** APNs a través de FCM, con la misma idea de mensajes de datos cifrados.

---

## 7. Glosario

- **Notificación push:** un aviso que llega al móvil aunque la app esté cerrada.
- **FCM (Firebase Cloud Messaging):** el servicio gratuito de Google que entrega
  los avisos a los teléfonos Android.
- **Token de FCM:** la "dirección" de un teléfono en FCM. Cambia de vez en cuando.
- **Mensaje de datos:** un aviso sin texto visible: despierta a la app y ella
  decide qué mostrar. Lo contrario es un "mensaje de notificación", que muestra
  Google directamente (y por eso tendría que ver el texto).
- **Seudónimo / seudonimización:** sustituir el identificador real por otro que
  sin una clave no se puede relacionar con la persona (RGPD, art. 4.5).
- **HMAC:** una "huella con sello": resumen de un dato mezclado con una clave
  secreta. Mismo dato + misma clave = misma huella; sin la clave no se puede calcular.
- **HKDF:** una "fábrica de claves": de una clave maestra saca varias subclaves
  independientes, una para cada uso.
- **HPKE:** estándar (RFC 9180) para cifrar un mensaje para la clave pública de
  alguien. Aquí: X25519 + HKDF-SHA256 + AES-256-GCM.
- **Clave pública / privada:** el candado abierto (se puede repartir) y su llave
  (nunca sale del teléfono).
- **Clave efímera:** una clave de un solo uso que se crea para un mensaje y se tira.
- **AES-256-GCM:** cifrado simétrico estándar que además detecta si alguien ha
  manipulado el texto cifrado.
- **Índice ciego:** un HMAC de un dato secreto que permite buscarlo o detectar
  duplicados sin guardarlo en claro.
- **Enfriamiento (cooldown):** periodo de silencio obligatorio después de un aviso.
- **Script Lua atómico:** un pequeño programa que Redis ejecuta de una vez, sin
  que nadie pueda intercalar otra operación en medio.
- **Cola / bandeja de salida (outbox):** tabla donde se dejan los avisos
  pendientes para que otro proceso los envíe a su ritmo.
- **FOR UPDATE SKIP LOCKED:** forma de PostgreSQL de que varias copias cojan
  filas distintas de una cola sin esperarse unas a otras.
- **Préstamo (lease):** reserva temporal de una fila; si quien la tenía muere,
  la reserva caduca y otra copia la coge.
- **Worker pool (grupo de obreros):** varias goroutines que trabajan en paralelo
  sacando tareas de un mismo canal.
- **Token bucket (cubo de fichas):** limitador de ritmo: se rellena a velocidad
  fija y cada operación gasta una ficha.
- **429 Too Many Requests / Retry-After:** "vas demasiado rápido, vuelve dentro
  de N segundos".
- **collapse_key:** etiqueta que hace que Google entregue solo el último de
  varios avisos pendientes.
- **DLQ (Dead Letter Queue):** buzón de mensajes imposibles de procesar, para
  revisarlos sin bloquear al resto.
- **FCM falso (fcm-fake):** un pequeño servidor que imita a Google para probar
  todo en local y en la CI, sin cuenta ni teléfono.
