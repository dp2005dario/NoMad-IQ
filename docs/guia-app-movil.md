# Guía para principiantes: la app móvil de NomadIQ (Flutter)

Hasta ahora todo NomadIQ eran servicios que corren en servidores (la "cocina").
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
  Ajustes → Apps → NomadIQ → Idioma.
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

1. **VS Code.** Al abrir la carpeta `NoMad-IQ`, abajo a la derecha te sugiere
   unas extensiones. Pulsa **Instalar todas**. La que importa aquí es
   **Flutter** (`Dart-Code.flutter`).
2. **Flutter SDK.** En VS Code pulsa `Ctrl+Shift+P`, escribe
   `Flutter: New Project` y pulsa Enter. Si no tienes Flutter, VS Code ofrece
   **Download SDK**. Elige una carpeta **sin espacios ni tildes**, por ejemplo
   `C:\src\flutter`. Cuando acabe, pulsa **Add SDK to PATH**.
   - ⚠️ Tu proyecto está en `C:\Users\Darío\OneDrive\...`, y la tilde de
     "Darío" y OneDrive a veces dan problemas a las herramientas de Android.
     Si ves errores raros al compilar, copia el proyecto a `C:\src\NoMad-IQ`.
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
- **Identificador de la app: `com.nomadiq.app`.** Es su "DNI" en Google Play y
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
| Permiso de ubicación | La pregunta del móvil "¿Permitir que NomadIQ acceda a tu ubicación?" |

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

La pestaña **Mapa** ya es de verdad: enseña la ciudad, las zonas de NomadIQ,
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
  servicio en el backend.
- **Rótulos en hindi.** MapLibre aún no dibuja bien la escritura devanagari:
  si falta el nombre en tu idioma, se usa el alfabeto latino.

## 9. Modo viaje y avisos push

Con el **modo viaje** encendido, NomadIQ te avisa aunque cierres la app:
"Audioguía cerca", "¡Bienvenido!" al llegar al aeropuerto o un aviso de
seguridad en una zona restringida.

### Qué ves

| En pantalla | Qué hace |
|---|---|
| Botón **Modo viaje** (abajo a la izquierda en el Mapa) | Aparece con la ubicación activada y con cuenta. Al pulsarlo, Android pide permiso de notificaciones (Android 13+) |
| Notificación fija "NomadIQ · Modo viaje" | Avisa de que la app sigue usando tu ubicación. No se puede quitar deslizando: así nunca te rastreamos sin que lo sepas |
| "Audioguía cerca" | Al tocarla, se abre la audioguía de esa zona |

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
   pulsa **Crear un proyecto**. Llámalo, por ejemplo, `nomadiq`. Google
   Analytics no hace falta.
2. En el proyecto, pulsa el icono de **Android** ("Añadir app").
   - **Nombre del paquete:** `com.nomadiq.app` (exactamente este).
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
   "NomadIQ · Modo viaje" sigue ahí.
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

## 10. Lo siguiente

Cada PR sustituye una pantalla "Muy pronto" por la de verdad, siguiendo las
maquetas, en este orden: Vuelos con alertas de precio, Grupo con la
negociación de Flyra, Cámara, Dinero y Bóveda.
