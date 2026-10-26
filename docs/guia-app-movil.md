# Guía para principiantes: la app móvil de ECLIPTA (Flutter)

Hasta ahora todo ECLIPTA eran servicios que corren en servidores (la "cocina").
La app móvil es el "comedor": lo que el viajero ve y toca. Esta guía explica
cómo está hecha la primera versión y cómo abrirla en tu PC con VS Code.

## 1. ¿Qué es Flutter?

Flutter es una herramienta de Google para hacer apps. Escribes el código **una
vez**, en el lenguaje **Dart**, y sale una app para Android y otra para iPhone.

- **Analogía:** es como escribir una receta en un idioma que entienden dos
  cocinas distintas. No hace falta una receta para cada cocina.
- En Flutter **todo es un widget**, es decir, una pieza de pantalla: un botón,
  un texto, una columna o la pantalla entera. Las pantallas se montan
  encajando widgets como si fueran piezas de LEGO.

## 2. Qué trae esta primera versión

| Pantalla | Qué hace |
|---|---|
| Bienvenida | Presenta a **Flyra** y ofrece Google, correo o invitado (el inicio de sesión real llega en otro PR) |
| Inicio | Saludo, caja "Pregúntale a Flyra" y atajos (Bóveda, Gastos, Audioguías, Idioma) |
| Barra de abajo | Inicio · Mapa · **Cámara** (botón grande en el centro) · Vuelos · Grupo |
| Idioma | Lista de idiomas, cada uno escrito en su propio idioma, con buscador |
| Mapa y Audioguía | La ciudad con sus zonas, tu posición y la audioguía de cada zona (sección 8) |
| "Muy pronto" | Ocupa el sitio de las pantallas que llegan en los próximos PRs |

Los colores y las letras son los de las maquetas: fondo `#0B1217`, verde menta
`#3DDC97`, y las fuentes Bricolage Grotesque para los títulos y Manrope para el
texto. Flyra aparece con su golondrina sobre un degradado de menta a violeta.

## 3. Todos los idiomas desde el día 1 (i18n)

**i18n** es una abreviatura de "internationalization": la i, 18 letras y la n.
Significa preparar la app para cualquier idioma.

**La regla de oro: ningún texto visible se escribe en el código.** Todos los
textos están en `mobile/lib/l10n/`, en un archivo por idioma:

```
app_en.arb   ← plantilla (inglés): cada texto nuevo se añade AQUÍ primero
app_es.arb   app_fr.arb   app_de.arb   app_it.arb   app_pt.arb
app_ar.arb   app_zh.arb   app_ja.arb   app_hi.arb
```

Un `.arb` es una lista de pares "nombre → texto" en formato JSON:

```json
"continueAsGuest": "Entrar como invitado",
"comingSoonBody": "{feature} está en camino. Flyra lo está preparando."
```

`{feature}` es un **hueco**: la app lo rellena con un nombre, por ejemplo
"Vuelos". Al ejecutar `flutter pub get`, Flutter genera código a partir de
estos archivos. En las pantallas se usa así: `t.continueAsGuest`.

Cosas que la app ya hace sola:

- **Elige el idioma del móvil.** Si el móvil está en `es-MX`, usa `es`. Si
  está en un idioma que aún no tenemos, usa el inglés.
- **Puedes cambiar el idioma** dentro de la app, en Idioma, y lo recuerda la
  próxima vez. En Android 13 o posterior también aparece en
  Ajustes → Apps → ECLIPTA → Idioma.
- **Escribe de derecha a izquierda (RTL)** en árabe, hebreo, persa…: la pantalla
  entera se da la vuelta como en un espejo. Por eso el código usa
  `EdgeInsetsDirectional` y `AlignmentDirectional`, que significan "al
  principio" y "al final" en lugar de "izquierda" y "derecha".
- **Los diseños no tienen altura fija.** Así no se cortan con idiomas largos
  (el alemán), con escrituras altas (el hindi) ni con letra grande de
  accesibilidad.

**Para añadir un idioma nuevo** (por ejemplo el catalán):

1. Copia `app_en.arb` a `app_ca.arb`, cambia `"@@locale": "en"` por `"ca"`
   y traduce los textos.
2. Añade `'ca': 'Català'` en `lib/core/languages.dart`.
3. Añade `<locale android:name="ca" />` en
   `android/app/src/main/res/xml/locales_config.xml`.
4. Ejecuta `flutter test`. El test `l10n_test.dart` comprueba que no falta
   ningún texto ni ningún hueco, y que Android y la app conocen los mismos
   idiomas.

## 4. Abrir la app en tu PC (Windows + VS Code)

### 4.1 Instalar lo necesario (una sola vez)

1. **VS Code.** Al abrir la carpeta `ECLIPTA`, abajo a la derecha te sugiere
   unas extensiones. Pulsa **Instalar todas**. La que importa aquí es
   **Flutter** (`Dart-Code.flutter`).
2. **Flutter SDK.** En VS Code pulsa `Ctrl+Shift+P`, escribe
   `Flutter: New Project` y pulsa Enter. Si no tienes Flutter, VS Code ofrece
   **Download SDK**. Elige una carpeta **sin espacios ni tildes**, por ejemplo
   `C:\src\flutter`. Cuando acabe, pulsa **Add SDK to PATH**.
   - ⚠️ Tu proyecto está en `C:\Users\Darío\OneDrive\...`, y la tilde de
     "Darío" y OneDrive a veces dan problemas a las herramientas de Android.
     Si ves errores raros al compilar, copia el proyecto a `C:\src\ECLIPTA`.
3. **Android Studio** (https://developer.android.com/studio). Solo hace falta
   para que te dé el **Android SDK** (las herramientas de Android) y un
   **emulador**, que es un móvil virtual dentro del PC. Ábrelo una vez y deja
   que descargue todo.
4. Abre la terminal de VS Code (**Terminal → Nueva terminal**, o `Ctrl+ñ`) y
   ejecuta:
   ```powershell
   flutter doctor
   flutter doctor --android-licenses   # acepta todo con "y"
   ```
   `flutter doctor` es el "chequeo médico". Revisa la lista: lo que salga con
   ✓ está bien, y lo que salga con ✗ trae una pista para arreglarlo.

### 4.2 Ejecutarla

1. En la terminal:
   ```powershell
   git pull
   cd mobile
   flutter pub get
   ```
2. Elige dónde se ejecutará la app:
   - **En el emulador:** abajo a la derecha de VS Code pone "No Device".
     Púlsalo y elige el emulador.
   - **En tu móvil Android:** ve a Ajustes → Información del teléfono y pulsa 7
     veces en "Número de compilación" (se activan las Opciones de
     desarrollador). Después entra en Opciones de desarrollador, activa
     **Depuración USB** y conecta el móvil por cable.
3. Abre `mobile/lib/main.dart` y pulsa **F5** (o **Ejecutar → Iniciar
   depuración**). La primera vez tarda unos minutos.
4. **Recarga en caliente:** cambia un texto en un `.arb` o un color en
   `theme.dart` y guarda con `Ctrl+S`. La app se actualiza al instante, sin
   reiniciarse.

### 4.3 Tests y revisión (lo mismo que hace la CI)

```powershell
cd mobile
dart format lib test     # ordena el código
flutter analyze          # busca errores sin ejecutar nada
flutter test             # tests: pantallas, idiomas, RTL, navegación, sesión...
```

En VS Code también puedes abrir el panel **Testing** (el icono del matraz)
y pulsar ▶ junto a cada test.

## 5. Cómo está organizado el código

```
mobile/lib/
  main.dart                 arranque: carga los ajustes y abre la app
  app.dart                  une el tema, los idiomas y las rutas
  core/theme.dart           colores y letras (si cambia el verde, se cambia aquí)
  core/router.dart          mapa de direcciones: /welcome, /home, /map...
  core/settings.dart        ajustes guardados (idioma) que avisan al cambiar
  core/languages.dart       "Deutsch", "日本語"... (nombre de cada idioma en su idioma)
  features/<pantalla>/      una carpeta por pantalla
  widgets/flyra_avatar.dart Flyra dibujada con código (nítida a cualquier tamaño)
```

Algunas decisiones y su porqué:

- **go_router (las rutas):** cada pantalla tiene una dirección, como en una web.
  Así un aviso push podrá abrir directamente `/flights` el día de mañana.
- **Las pestañas mantienen su estado:** si te vas al Mapa y vuelves a Inicio,
  Inicio sigue como lo dejaste.
- **Las fuentes van dentro de la app:** no se descargan de Internet. Así
  funciona sin conexión y no avisa a terceros de quién usa la app.
- **Identificador de la app: `com.eclipta.app`.** Es su "DNI" en Google Play y
  **no se puede cambiar** después de publicarla.

## 6. Glosario

| Palabra | Qué significa |
|---|---|
| Widget | Cualquier pieza de pantalla en Flutter |
| Dart | El lenguaje en el que se escribe Flutter |
| `.arb` | Archivo con los textos de un idioma |
| i18n / l10n | Preparar la app para varios idiomas / traducirla a uno concreto |
| RTL | *Right-to-left*: idiomas que se leen de derecha a izquierda |
| Locale | Idioma y región, por ejemplo `es`, `pt-BR` o `ar` |
| Emulador | Un móvil virtual que funciona dentro del PC |
| Recarga en caliente | Ver los cambios al guardar, sin reiniciar la app |
| APK | El archivo instalable de una app Android |
| Tesela | Un "azulejo" de mapa: el mapa del mundo se corta en cuadraditos que se descargan según los necesitas |
| OpenStreetMap | El mapa libre del mundo, hecho por voluntarios (como la Wikipedia) |
| MapLibre | La librería que dibuja el mapa en el móvil |
| Histéresis | Esperar un poco antes de cambiar de estado, para no "parpadear" en el borde |
| Permiso de ubicación | La pregunta del móvil "¿Permitir que ECLIPTA acceda a tu ubicación?" |

## 7. Iniciar sesión (conectada al auth-gateway)

La app ya crea cuentas y entra con **correo y contraseña** usando el
[auth-gateway](guia-auth-gateway.md). El botón de Google todavía avisa de
que llega pronto, porque el servidor aún no sabe comprobar cuentas de Google.

### Cómo funciona (con analogías)

- **Dos pases, como en un hotel:**
  - El **pase corto** (*access token*) es como la tarjeta de la habitación:
    caduca a los 15 minutos y solo se guarda en la memoria de la app.
  - El **pase largo** (*refresh token*) es como el resguardo de la reserva:
    sirve para pedir una tarjeta nueva. Se guarda **cifrado** con
    `flutter_secure_storage`, que usa el chip de seguridad del móvil
    (Android Keystore o el Llavero de iOS).
- **El pase largo solo vale una vez.** Cada renovación da uno nuevo. Si dos
  pantallas piden renovar a la vez, la app hace **una sola** renovación. Si
  hiciera dos, el servidor pensaría que alguien ha robado el pase y cerraría la
  sesión.
- **El portero** (`sessionRedirect` en `core/router.dart`) decide a qué
  pantalla vas:
  - **Sin sesión:** solo puedes ver Bienvenida, Iniciar sesión e Idioma.
  - **Con sesión:** vas directo a Inicio.
  - **Invitado:** puede crear su cuenta desde el círculo de su inicial, arriba
    a la derecha.
- **Sin cobertura** la app abre igual con la sesión guardada y renueva el pase
  cuando vuelve la red. Si la sesión caducó, vuelves a la Bienvenida.
- **Errores en tu idioma.** El servidor responde con un código (401, 409,
  429…) y la app muestra el texto traducido que corresponde. Nunca muestra el
  mensaje original del servidor.
- **Seguridad extra:**
  - La versión publicada **solo** acepta `https://`; si no, no arranca.
  - Android bloquea HTTP sin cifrar, salvo hacia tu PC en la versión de
    desarrollo.
  - `allowBackup="false"` evita que la sesión se copie a otro móvil.

### Probarlo en tu PC

1. Arranca el backend:
   ```powershell
   make up
   ```
   O `docker compose up` dentro de `infrastructure/`.
2. Ejecuta la app en el **emulador** con F5. Por defecto habla con
   `http://10.0.2.2:8080`, que es la puerta de entrada (`edge`) de tu PC vista desde el emulador.
3. Si usas tu **móvil por USB**, ejecuta antes:
   ```powershell
   adb reverse tcp:8080 tcp:8080
   ```
   Y arranca la app con:
   ```powershell
   flutter run --dart-define=NOMADIQ_API_URL=http://localhost:8080
   ```
4. Pulsa **Continuar con correo → ¿Eres nuevo? Crea una cuenta**. La
   contraseña necesita **12 caracteres como mínimo**.

## 8. El mapa y las audioguías

La pestaña **Mapa** ya es de verdad: enseña la ciudad, las zonas de ECLIPTA,
tu posición y la audioguía de cada zona.

### Qué ves

| En pantalla | Qué hace |
|---|---|
| Buscador "Buscar zona" | Busca entre las zonas cargadas y lleva el mapa hasta la elegida |
| Auto · Día · Tarde · Noche | Cambia los colores del mapa. "Auto" los elige según la hora |
| Botón 3D / 2D | Inclina el mapa: en 3D los edificios se levantan |
| Zonas de colores | Menta = tiene audioguía; azul = aeropuerto; naranja = zona restringida |
| Tarjeta de la zona | Al tocar una zona: su nombre y el botón **Escuchar la audioguía** |
| "Has entrado en…" | Aviso con vibración suave cuando llevas 15 s dentro de una zona |
| Atajos de abajo | Cerca de ti, Moverte, Radar, Sin colas y Asistente ("Muy pronto" de momento) |

### Cómo funciona (con analogías)

- **El mapa es MapLibre**, una librería gratis y de código abierto que dibuja
  con la tarjeta gráfica del móvil.
  - Los datos (calles, agua, edificios) son de **OpenStreetMap**, la
    "Wikipedia de los mapas". Los sirve **OpenFreeMap** gratis y sin
    rastrear a nadie.
  - Los colores están en `lib/features/map/map_style.dart`.
  - **De cerca (zoom 16 o más) la ciudad se ve "de verdad"**:
    - Las calles se pintan en tres pasadas, como capas de pintura: bordillo, acera y asfalto. Lo que asoma por los lados es la acera.
    - Las avenidas llevan la línea discontinua del centro.
    - Plazas y calles peatonales tienen textura de adoquín.
    - Los edificios en 3D llevan fachada con ventanas. De noche, parte de ellas se encienden.
    - Una "tapa" fina de color encima de cada edificio evita que salgan ventanas en el tejado.
  - Esas texturas no son fotos: se pintan con código en `map_patterns.dart` (unos cuadraditos de 64 píxeles). No pesan nada y cambian con la hora: de día, al atardecer y de noche.
  - Todo sigue costando 0 €: son los mismos datos gratuitos; solo cambia cómo se dibujan.
  - Los nombres de calles y ciudades salen en tu idioma si OpenStreetMap
    los tiene traducidos. Si no, en alfabeto latino.
- **Las zonas se piden por trozos.** La app solo pide las zonas del
  rectángulo que ves, y un poco más alrededor.
  - Al mover un poco el mapa no vuelve a preguntar.
  - Lo descargado vale 5 minutos.
  - Con millones de usuarios, esto ahorra muchísimas peticiones al servidor.
- **La ubicación solo se pide cuando pulsas "Activar ubicación".** Nunca nada
  más abrir la app, y siempre explicando para qué es. Si dices que no,
  el mapa funciona igual, pero sin tu punto.
- **El "cartero" de posiciones** (`position_reporter.dart`) junta tus
  posiciones y las manda de 10 en 10, o cada minuto como mucho.
  - Encender la radio del móvil gasta mucha batería. Mandar 10 posiciones
    cuesta casi lo mismo que mandar 1.
  - Sin cobertura las guarda y reintenta cada vez más espaciado: 15 s,
    30 s, 1 min… Así, si el servidor se cae, millones de móviles no le
    golpean todos a la vez cuando vuelve.
- **El aviso de "Has entrado"** usa la misma idea que el geo-engine,
  llamada **histéresis**: hay que estar 15 s dentro para entrar y 15 s
  fuera para salir. Sin ella, el GPS que tiembla en el borde haría saltar
  el aviso diez veces seguidas.
- **La audioguía** pide al ai-orchestrator el guion y la lista de audios
  (`.opus`).
  - **El guion aún no está:** Flyra lo prepara en cuanto alguien entra en
    la zona, y la app vuelve a preguntar sola cada 5 s.
  - **El audio aún no está:** puedes leer el texto mientras tanto.
  - **Reproducir:** el círculo verde se toca para reproducir o pausar, y se
    desliza a los lados para avanzar o retroceder.
  - **Accesibilidad:** con lector de pantalla, se sube o se baja para
    saltar 10 s.
- **Solo con cuenta.** Las zonas y las audioguías se piden con tu pase
  (token). Un invitado ve el mapa y una invitación a crear su cuenta.

### "Ver la calle de verdad" (fotos reales de Mapillary)

El mapa 3D es un dibujo hecho con datos de OpenStreetMap. Para ver cómo es
la calle **de verdad**, el botón **Ver la calle de verdad** (abajo, junto a
"mi ubicación") abre fotos reales a pie de calle del centro de lo que ves.

- **De dónde salen:** de [Mapillary](https://www.mapillary.com), millones de
  fotos que hace gente de todo el mundo. Son gratis y con licencia libre
  (CC BY-SA 4.0): por eso la app dice quién hizo cada foto y deja abrirla en
  Mapillary. Analogía: es como Street View, pero hecho por la comunidad.
- **Privacidad:** la app solo manda el centro del mapa **redondeado a unos
  100 m** (tres decimales). El servidor tampoco lo apunta en sus registros.
- **0 € con millones de usuarios:** el servidor guarda la respuesta de cada
  "casilla" de ~100 m durante 6 horas en Redis. Mil personas mirando la
  Puerta del Sol = **una** petición a Mapillary. Si se pasa del límite de
  peticiones por segundo, la app dice "prueba más tarde" (nunca hay factura).
- **Panorámicas de 360°:** se ven arrastrando el dedo a los lados.

**Activarlo (una vez, gratis):**

1. Entra en <https://www.mapillary.com/dashboard/developers> con una cuenta
   de Mapillary (o de Facebook) y pulsa **Register application**.
2. Pon un nombre (por ejemplo, `ECLIPTA`), una web (la del repositorio) y
   marca solo el permiso de **lectura** ("Read").
3. Copia la **Client Token** (empieza por `MLY|`).
4. En VS Code, abre `infrastructure/.env` (no el `.env.example`) y añade:
   ```
   MAPILLARY_TOKEN=MLY|...tu token...
   ```
   Es **secreta**: `.env` no se sube a GitHub. Nunca la pegues en el código.
5. Reinicia el ai-orchestrator:
   `docker compose --profile apps up -d ai-orchestrator`.

Sin token, el botón sale igual pero dice que las fotos no están disponibles.

### Probarlo en tu PC

1. Arranca el backend con las apps:
   ```powershell
   cd infrastructure
   docker compose --profile apps up -d --build
   ```
2. Ejecuta la app en el emulador (F5), entra con tu cuenta y ve a **Mapa**.
3. **Simular que caminas:** en el emulador, pulsa los tres puntos `⋮` →
   **Location**. Escribe `40.41694, -3.70361` (la Puerta del Sol) y pulsa
   **Set location**. A los 15 s verás "Has entrado en Puerta del Sol".
4. Los mapas necesitan Internet en el emulador (vienen de OpenFreeMap). Si
   el mapa sale vacío, mira la conexión del emulador.

### Lo que falta y por qué

- **Ubicación con la app cerrada:** ya está, con el **modo viaje** (ver la
  sección 9).
- **Audioguías en iPhone.** El iPhone no reproduce `.opus` dentro de `.ogg`:
  el servidor tendrá que grabar también otro formato.
- **Fotos reales de cada zona** (Wikimedia Commons, con sus créditos) y el
  **tiempo** (sol, nubes, lluvia) de la maqueta. Necesitan su propio
  servicio en el backend. (Las fotos de **la calle** ya están: ver arriba.)
- **Rótulos en hindi.** MapLibre aún no dibuja bien la escritura devanagari:
  si falta el nombre en tu idioma, se usa el alfabeto latino.

## 9. Modo viaje y avisos push

Con el **modo viaje** encendido, ECLIPTA te avisa aunque cierres la app:
"Audioguía cerca", "¡Bienvenido!" al llegar al aeropuerto o un aviso de
seguridad en una zona restringida.

### Qué ves

| En pantalla | Qué hace |
|---|---|
| Botón **Modo viaje** (abajo a la izquierda en el Mapa) | Aparece con la ubicación activada y con cuenta. Al pulsarlo, Android pide permiso de notificaciones (Android 13+) |
| Notificación fija "ECLIPTA · Modo viaje" | Avisa de que la app sigue usando tu ubicación. No se puede quitar deslizando: así nunca te rastreamos sin que lo sepas |
| "Audioguía cerca" | Al tocarla, se abre la audioguía de esa zona |
| "Posible tarifa error · MAD → NRT · 15 mar: 315 € (−65 %)" | Alerta de precio de un vuelo que vigilas (canal propio "Alertas de precio", que puedes silenciar aparte). El precio y la fecha salen en el formato de tu idioma (`lib/core/money.dart`). De momento abre la ficha de Vuelos; con las pantallas de Vuelos abrirá tus alertas |

### Cómo funciona (con analogías)

- **El rastreador** (`lib/features/map/location_tracker.dart`) es ahora el
  único que enciende el GPS, para toda la app (antes lo hacía el mapa).
  - **Sin modo viaje:** GPS solo con la app en pantalla, como antes.
  - **Con modo viaje:** sigue con la app cerrada gracias a un *servicio en
    primer plano*: un "trabajo" que Android deja vivo porque enseña una
    notificación fija.
  - Pide algo menos de precisión (cada 50 m en vez de 20 m): basta para
    saber en qué barrio estás, y la batería dura todo el día.
  - Se recuerda entre aperturas: si lo dejaste encendido, sigue al abrir.
- **Sin el permiso "todo el tiempo".** Como el modo viaje se enciende con la
  app abierta, a Android le basta el permiso "mientras se usa la app". Así
  nos ahorramos el formulario especial de Google Play.
- **Cómo llega un aviso.** El servidor ve que entraste en una zona (con las
  posiciones que manda el rastreador) y el **notifier** te manda el aviso
  por **Firebase Cloud Messaging** (FCM, gratis), el "cartero" de Google.
- **El aviso va cifrado SOLO para tu móvil** (`lib/features/push/`).
  - Analogía: el móvil reparte **candados abiertos** (clave pública) y se
    queda la **única llave** (clave privada). El notifier mete el aviso en
    una caja, la cierra con tu candado y Google solo transporta la caja.
  - La técnica se llama **HPKE** (un estándar, RFC 9180). El móvil la
    implementa en `hpke.dart` y un test comprueba que abre exactamente lo
    que cifra el notifier en Go.
  - El aviso no lleva texto, solo el tipo ("zone_audioguide"). El móvil
    escribe el texto en tu idioma. Google no sabe ni de qué trata.
- **Registro del móvil** (`push_registrar.dart`). Al entrar en tu cuenta,
  la app le dice al notifier: "este móvil (un número al azar) tiene este
  token de Firebase y este candado".
  - Solo repite el registro si algo cambia, o una vez por semana. Con
    millones de usuarios, ahorra muchísimas peticiones.
  - Cambia de llave cada 30 días y guarda la anterior un tiempo: un aviso
    que ya venía de camino se sigue abriendo.
  - Al **cerrar sesión**: baja en el servidor, se borran las llaves y
    Firebase olvida el token. Un aviso que llegue después ya no se abre.
- **Con la app cerrada**, Android arranca un "mini motor" solo para abrir
  el aviso y enseñarlo. A propósito no renueva ningún pase desde ahí: el
  pase largo es de un solo uso y dos motores renovando a la vez cerrarían
  tu sesión.

### Crear tu proyecto de Firebase (gratis, una vez)

Sin estos datos la app funciona igual, pero sin avisos push.

1. Entra en <https://console.firebase.google.com> con tu cuenta de Google y
   pulsa **Crear un proyecto**. Llámalo, por ejemplo, `eclipta`. Google
   Analytics no hace falta.
2. En el proyecto, pulsa el icono de **Android** ("Añadir app").
   - **Nombre del paquete:** `com.eclipta.app` (exactamente este).
   - Pulsa **Registrar app**. El archivo `google-services.json` que te
     ofrece **no hace falta**: sáltalo con **Siguiente** hasta terminar.
3. Ve a ⚙️ **Configuración del proyecto** → pestaña **General**. En "Tus
   apps" verás los datos. Copia `mobile/firebase.example.json` como
   `mobile/firebase.json` (este no se sube a GitHub) y rellénalo:
   - `NOMADIQ_FIREBASE_API_KEY` = "Clave de API web" (empieza por `AIza`).
   - `NOMADIQ_FIREBASE_APP_ID` = "ID de la app" (empieza por `1:`).
   - `NOMADIQ_FIREBASE_SENDER_ID` = "Número del proyecto".
   - `NOMADIQ_FIREBASE_PROJECT_ID` = "ID del proyecto".
4. Para el **notifier** (el servidor que manda los avisos): pestaña
   **Cuentas de servicio** → **Generar nueva clave privada**. Ese archivo SÍ
   es secreto: guárdalo fuera del repositorio y sigue
   [la guía del notifier](../services/notifier/README.md)
   (`FCM_PROJECT_ID` y `FCM_CREDENTIALS_FILE`).
5. En VS Code, ejecuta la app con tus datos:
   ```powershell
   cd mobile
   flutter run --dart-define-from-file=firebase.json
   ```
   O añade `"args": ["--dart-define-from-file=firebase.json"]` a tu
   configuración de `.vscode/launch.json` para que F5 lo haga solo.

### Probarlo en tu PC

1. Entra con tu cuenta, ve a **Mapa**, pulsa **Activar ubicación** y luego
   **Modo viaje**. Acepta el permiso de notificaciones.
2. Sal de la app (botón de inicio del emulador). La notificación fija
   "ECLIPTA · Modo viaje" sigue ahí.
3. Con `⋮` → **Location**, pon la Puerta del Sol (`40.41694, -3.70361`).
   Si el notifier usa tu Firebase de verdad (paso 4 de arriba), en unos
   segundos llega
   "Audioguía cerca". Tócala y se abre la audioguía.
4. Sin Firebase propio puedes ver los avisos que "se habrían mandado" en el
   FCM falso del docker compose: <http://127.0.0.1:8099/messages> (ver la
   guía del notifier).

### Lo que falta y por qué

- **Avisos push en iPhone.** El notifier aún no habla con Apple (APNs). El
  modo viaje ya funciona en iPhone (con la "píldora" azul de ubicación).
- **Geovallas nativas** (Android/iOS vigilando zonas sin GPS continuo): una
  mejora de batería para más adelante. El modo viaje ya cubre la función.
- **Icono propio de notificación** (una silueta blanca): de momento se usa
  el de la app.

## 9 bis. Vuelos: el cazador de chollos

La pestaña **Vuelos** (maqueta "Cazador de vuelos") ya funciona con el
price-consumer:

| En pantalla | Qué hace |
|---|---|
| "Desde MAD" | El aeropuerto de salida. Tócalo para escribir otro código (BCN, LHR…). Se recuerda |
| Tarjeta "¡VUELO CAZADO!" | El chollo que más ha bajado frente a lo habitual. Si baja más de un 50 %, pone "ERROR DE TARIFA" y avisa de esperar 48 h antes de reservar hotel |
| "Reservar ya" | Abre la web de reserva en el navegador, con tu enlace de afiliado (ver `docs/guia-travelpayouts.md`) |
| "Avisar si baja" | Vigila esa ruta. Puedes poner un precio objetivo ("avísame si baja de 300 €") o dejarlo vacío |
| "Chollos de hoy" y "Mis alertas" | El resto de chollos y las rutas que vigilas, con su último precio |
| Campana (arriba) | Tus últimos avisos de precio. Tocar la notificación del móvil también abre esta lista |
| "Buscar vuelos" | El buscador normal: origen, destino, ida y vuelta (o solo ida), fechas y de 1 a 9 viajeros. Da las opciones de la más barata a la más cara, con precio por persona, total, horarios (hora local del aeropuerto), escalas y duración. "Reservar ya" abre la web con el número de viajeros ya puesto |
| Modo invitado | Ve los mismos chollos y gráficas con precios reales. Solo "Avisar si baja" y "Mis alertas" piden crear una cuenta gratis (los avisos se guardan a tu nombre) |
| Detalle de una ruta | Gráfica del precio más bajo de cada día, el mínimo, reservar y "Dejar de vigilar" |
| "Ruta del vuelo" | Mapamundi sin conexión: la cámara va a tu ciudad, el avión despega y sigue la ruta curva real hasta el destino, con distancia, duración aproximada y hora local al llegar. "Sobre <ciudad>" abre su ficha: por qué es famosa, datos del país y lo más visitado con fotos libres (ver `docs/guia-ruta-del-vuelo.md`). También desde "Ver la ruta en el mapa" en el buscador y en el detalle de una ruta |
| "Planea tu viaje" | Vuelo en 3D, Explorar, Dormir barato, Escala gratis, Qué pasa y Copiar viaje: llegan en los siguientes PR |

### Cómo funciona (con analogías)

- **`lib/features/flights/fares_api.dart`** es el "traductor": pide los datos
  al servidor y comprueba cada campo (códigos de aeropuerto, fechas,
  importes). Si algo llega raro, la pantalla enseña un error en vez de romperse.
- **El dinero viaja en céntimos** (31500 = 315,00 €) y se escribe en el formato
  de cada idioma con `lib/core/money.dart`: "315 €" en España, "€315" en inglés,
  "¥31,500" para yenes, que no tienen céntimos.
- **La gráfica** (`price_chart.dart`) se dibuja "a mano" con un `CustomPainter`:
  unas pocas líneas de código en vez de una librería entera. Para TalkBack lleva
  una descripción: "Gráfica de precios de 3 días. Mínimo…".
- **Solo se abren enlaces https**, y además fuera de la app (en el navegador):
  ECLIPTA nunca ve tus datos de pago.

### Probarlo en tu PC

```bash
cd mobile
flutter test test/flights_test.dart
```

## 9 ter. Grupo: viajes en grupo con Flyra

La pestaña **Grupo** (maqueta "Grupo") conecta con la negociación de agentes
del ai-orchestrator (ver `docs/guia-negociacion-grupo.md`).

| En pantalla | Qué hace |
|---|---|
| "Nuevo viaje en grupo" | Nombre del viaje, tu nombre para el grupo, la divisa y de 2 a 10 opciones (una ciudad, un piso, un hotel…) con precio por persona y lo que ofrece cada una ("Playa", "Historia"…). Al crearlo recibes un **código de invitación** |
| El código ("7K2M-9QXD") | Cópialo y mándalo por WhatsApp. Quien lo escriba en "Unirme con un código" entra en el viaje (hasta 8 personas) |
| "Tus preferencias" | Lo máximo que pagarías por persona (una línea roja que ningún agente cruza), lo que te gusta, lo que prefieres evitar y una nota. **Solo lo ve tu agente**; el servidor lo borra al terminar |
| "Empezar la negociación" | Solo quien organiza, con al menos dos personas listas. Si nadie lo pulsa, empieza sola al acabar el plazo |
| "Los agentes están negociando" | Tarda unos minutos. La pantalla pregunta cada 4 segundos cómo va (cada 20 mientras se espera a la gente) y deja de preguntar sola a los 30 minutos para no gastar batería |
| El resultado | La opción elegida y por qué (acuerdo, árbitro o "ninguna cabe en el presupuesto de todos"), cuántas opciones se cayeron por presupuesto (sin decir de quién) y lo que dijo el agente de cada uno |
| Modo invitado | Grupo pide crear una cuenta gratis: tus amigos tienen que poder encontrarte |

### Cómo funciona (con analogías)

- **`lib/features/group/group_api.dart`** es el "traductor": revisa cada campo
  que llega del servidor (estado, divisa, opciones, resultado). Si algo llega
  raro, error claro en vez de pantalla rota.
- **Los gustos son palabras fijas** (`beach`, `museums`…) y cada idioma tiene
  su traducción en los `.arb`. Así nadie puede colar instrucciones para la IA
  dentro de una etiqueta.
- **Los precios se escriben en números enteros** (70, no 70,50) y se pasan a
  céntimos según la divisa (`wholeToMinor` en `lib/core/money.dart`: el yen
  no tiene céntimos).
- **La explicación del resultado la escribe la app** con sus textos
  traducidos, a partir de los datos (acuerdo, rondas, descartes). La frase de
  cada agente sí llega del servidor, en el idioma de la negociación.

### Probarlo en tu PC

```bash
cd mobile
flutter test test/group_test.dart
```

## 9 quater. Chat con Flyra

La caja "Pregúntale a Flyra lo que quieras" de **Inicio** abre el chat con
Flyra. Le puedes preguntar de todo (qué ver, qué comer, qué llevar, frases
útiles… o cualquier curiosidad). Detalles del servidor en
`docs/guia-flyra-chat.md`.

| En pantalla | Qué hace |
|---|---|
| Bocadillos | Los tuyos en verde menta; los de Flyra en violeta, con su golondrina. El texto se puede seleccionar y copiar |
| Sugerencias | Cuatro preguntas de ejemplo al empezar: se envían al tocarlas |
| "Flyra está pensando…" | Mientras llega la respuesta (unos segundos) |
| "Te quedan N preguntas hoy" | El cupo gratis de cada cuenta (50 al día). Al gastarlo, la caja se bloquea hasta mañana |
| Papelera (arriba) | Borra la conversación del móvil |
| Modo invitado | Pide iniciar sesión: el cupo diario va por cuenta |

### Cómo funciona (con analogías)

- **Flyra no tiene memoria**: es como llamar a una persona que no te recuerda.
  Por eso la app le "recuerda" la conversación enviando los últimos mensajes
  (hasta 20) con cada pregunta (`turnsToSend` en
  `lib/features/flyra/flyra_api.dart`).
- **La conversación vive solo en tu móvil** (`SettingsStore.readFlyraChat`):
  el servidor no la guarda ni la escribe en los registros.
- **Si Flyra está ocupada**, tu pregunta vuelve a la caja para reenviarla, y
  no te gasta ninguna pregunta del día.

### Probarlo en tu PC

```bash
cd mobile
flutter test test/flyra_test.dart
```

## 9 quinquies. Cámara: reconocer monumentos

El botón verde del centro abre el **modo cámara** (maqueta "Modo cámara").
Apuntas a un monumento, tocas el botón y sale su ficha: nombre, año,
distancia, historia de Wikipedia en tu idioma, **Escuchar** (la voz del
móvil la lee) y **Mi sello** (para el Pasaporte). Si no era ese, "¿No es
este?" enseña los de alrededor. Todo en `docs/guia-camara.md`.

```bash
cd mobile
flutter test test/camera_test.dart
```

## 9 sexies. Dinero: gastos compartidos

El atajo **Gastos** de Inicio abre **Dinero** (maqueta "Gastos"). En **Tu
dinero** creas un bote para un viaje o un piso, invitas con un código y
apuntáis lo que paga cada uno. Puedes **escanear el ticket**: el móvil lo lee
sin mandar la foto a nadie y cada amigo marca lo que se pidió. Arriba ves
"Le debes a Álex 21,50 €" y el botón **Saldar**. Todo en
`docs/guia-gastos.md`.

```bash
cd mobile
flutter test test/money_test.dart
```

## 10. Lo siguiente

Cada PR sustituye una pantalla "Muy pronto" por la de verdad, siguiendo las
maquetas, en este orden: (Vuelos, Ruta del vuelo, Vuelo 3D, Grupo, el chat
con Flyra, la Cámara y los Gastos ya están) el resto de Dinero y la Bóveda.
