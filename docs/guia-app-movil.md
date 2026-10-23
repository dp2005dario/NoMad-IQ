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
   `http://10.0.2.2:8083`, que es "tu PC" visto desde el emulador.
3. Si usas tu **móvil por USB**, ejecuta antes:
   ```powershell
   adb reverse tcp:8083 tcp:8083
   ```
   Y arranca la app con:
   ```powershell
   flutter run --dart-define=NOMADIQ_API_URL=http://localhost:8083
   ```
4. Pulsa **Continuar con correo → ¿Eres nuevo? Crea una cuenta**. La
   contraseña necesita **12 caracteres como mínimo**.

## 8. Lo siguiente

Cada PR sustituye una pantalla "Muy pronto" por la de verdad, siguiendo las
maquetas, en este orden: Mapa con geofencing y audioguías, Vuelos con
alertas de precio y Grupo con la negociación de Flyra.
