# Guía para principiantes: publicar ECLIPTA en Google Play

Esta guía es la lista de pasos para subir la app a la Play Store. Casi todo
ya está preparado en el código. Lo que queda son cosas que **solo puedes
hacer tú**: pagar la cuenta, firmar, rellenar formularios de Google y
conseguir probadores.

> Analogía: la app es un libro ya escrito. Ahora hay que registrarlo en la
> biblioteca (Play Console), ponerle tu firma (la llave de subida), escribir
> la contraportada (la ficha) y rellenar la ficha de "qué datos usa" que
> pide la biblioteca.

## Lo que ya está hecho

| Qué | Dónde |
|---|---|
| Firma de la versión "release" con tu llave (si existe `android/key.properties`) | `mobile/android/app/build.gradle.kts` |
| Plantilla de `key.properties` | `mobile/android/key.properties.example` |
| Ficha de la tienda en 10 idiomas (título, descripción corta y larga) | `mobile/android/fastlane/metadata/android/<idioma>/` |
| Política de privacidad (es/en) | `site/privacidad.html`, `site/privacy.html` |
| Página "borrar tu cuenta" (es/en) | `site/borrar-cuenta.html`, `site/delete-account.html` |
| Publicación gratis de esas páginas (GitHub Pages) | `.github/workflows/pages.yml` |
| Borrado de cuentas pedido por correo | `infrastructure/production/erase-user.sh` |
| Android 16 (API 36) como objetivo, que es lo que exige Play | lo pone Flutter (`targetSdk`) |

## Paso 1: cuenta de Play Console (25 $ una vez)

1. <https://play.google.com/console/signup> → cuenta **personal**.
2. Pago único de 25 $ y verificación de identidad (te pedirá tu DNI).

> **Importante para cuentas personales nuevas:** antes de poder publicar
> para todo el mundo, Google exige una **prueba cerrada con al menos 12
> personas** que tengan la app instalada (apuntadas) **14 días seguidos**
> ([norma oficial](https://support.google.com/googleplay/android-developer/answer/14151465)).
> Ve buscando ya 12 amigos o familiares con Android y una cuenta de Google.

## Paso 2: crear tu llave de subida

En la terminal de **VS Code** (Terminal → Nueva terminal), en tu ordenador:

```bash
keytool -genkey -v -keystore ~/nomadiq-upload.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias upload
```

(`keytool` viene con Java; si no lo encuentra, instala el JDK 17.) Te pedirá
una contraseña: invéntala larga y **guárdala en tu gestor de contraseñas**.

Copia `mobile/android/key.properties.example` como
`mobile/android/key.properties` y rellénalo:

```properties
storeFile=/home/TU_USUARIO/nomadiq-upload.jks
storePassword=la-contraseña
keyAlias=upload
keyPassword=la-contraseña
```

`key.properties` y los `.jks` están en `.gitignore`: **nunca** se suben a git.
Haz una copia del `.jks` en un USB o en tu nube personal. Si pierdes la
llave de subida, Google puede cambiártela (con "Play App Signing", paso 5),
pero es un trámite lento.

## Paso 3: construir el paquete (.aab)

Con el servidor ya en marcha (ver `docs/guia-produccion.md`):

```bash
cd mobile
flutter build appbundle --release \
  --dart-define=NOMADIQ_API_URL=https://TU_DOMINIO \
  --dart-define=NOMADIQ_SUPPORT_EMAIL=tu-correo-de-soporte \
  --dart-define=NOMADIQ_FIREBASE_API_KEY=... \
  --dart-define=NOMADIQ_FIREBASE_APP_ID=... \
  --dart-define=NOMADIQ_FIREBASE_SENDER_ID=... \
  --dart-define=NOMADIQ_FIREBASE_PROJECT_ID=...
```

El resultado queda en `mobile/build/app/outputs/bundle/release/app-release.aab`.
Si ves el aviso "falta android/key.properties", el paquete se firmó con la
llave de pruebas y Play lo rechazará: revisa el paso 2.

Cada versión nueva: sube el número de después del `+` en `pubspec.yaml`
(`version: 1.0.0+1` → `1.0.1+2`).

## Paso 4: publicar las páginas legales (gratis)

1. En GitHub, tu repositorio → **Settings → Pages** → *Source*: **GitHub Actions**.
2. **Settings → Secrets and variables → Actions → Variables → New repository
   variable**: nombre `NOMADIQ_SUPPORT_EMAIL`, valor tu correo de soporte.
3. Cuando esté en `main`, pestaña **Actions → pages → Run workflow**.

Quedarán en:

- `https://dp2005dario.github.io/NoMad-IQ/privacidad.html` (y `privacy.html`)
- `https://dp2005dario.github.io/NoMad-IQ/borrar-cuenta.html` (y `delete-account.html`)

Léelas antes de darlas por buenas: hablan de ti como responsable. Dicen que
los servidores están en la Unión Europea, así que elige Madrid o Frankfurt
como región de Oracle.

## Paso 5: crear la app en Play Console

**Crear aplicación** → nombre "ECLIPTA", idioma predeterminado español,
"Aplicación", "Gratis". Después, en el panel, Google te va guiando por estas
secciones:

### Contenido de la aplicación

| Sección | Qué poner |
|---|---|
| **Política de privacidad** | la URL de `privacidad.html` |
| **Anuncios** | No contiene anuncios |
| **Acceso a la aplicación** | Algunas funciones necesitan cuenta: crea una cuenta de prueba en tu servidor y pon su correo y contraseña |
| **Clasificación de contenido** | Cuestionario IARC. Di que **sí** hay interacción entre usuarios (chat del viaje y quedadas) y que se puede compartir la ubicación (solo con el modo viaje, y no con otros usuarios) |
| **Público objetivo** | **18 años o más** (hay quedadas y chats con desconocidos) |
| **Seguridad de los datos** | ver la tabla de abajo |
| **Eliminación de la cuenta** | la URL de `borrar-cuenta.html` |
| **Servicios en primer plano** | ver abajo |
| **App de noticias / de salud / financiera** | No |

### Seguridad de los datos (lo que tienes que marcar)

Respuestas generales: **sí** recoge datos; todo va **cifrado en tránsito**;
el usuario **puede pedir que se borren** (en la app y por la web); **no**
se comparten datos con terceros (Firebase y Oracle cuentan como "proveedores
de servicio", que Google no considera "compartir").

| Tipo de dato (nombre en Play) | ¿Se recoge? | ¿Obligatorio? | Para qué | Notas |
|---|---|---|---|---|
| Información personal → Dirección de correo | Sí | Sí (para tener cuenta) | Gestión de la cuenta | |
| Ubicación → Ubicación precisa | Sí | No (opcional) | Funcionalidad de la app | Modo viaje, Cámara, "Cerca de ti" |
| Ubicación → Ubicación aproximada | Sí | No | Funcionalidad de la app | |
| Mensajes → Otros mensajes en la app | Sí | No | Funcionalidad de la app | Chat del viaje |
| Fotos y vídeos → Fotos | Sí | No | Funcionalidad de la app | Marca "se procesa de forma efímera" (la Cámara manda una foto reducida que no se guarda) |
| Información financiera → Otra información financiera | Sí | No | Funcionalidad de la app | Gastos compartidos del grupo |
| Actividad en la app → Otro contenido generado por el usuario | Sí | No | Funcionalidad de la app | Avisos del Radar y colas, quedadas, viajes compartidos, preguntas a Flyra (estas, efímeras) |
| Identificadores del dispositivo u otros | Sí | No | Funcionalidad de la app | Identificador de notificaciones push |

Lo que **no** marcas porque no sale del móvil: documentos de la Bóveda,
fotos de tickets y cartas, Recuerdos, tarjeta médica, contactos, archivos,
audio (el dictado lo hace el reconocimiento de voz de Android; a nosotros
solo nos llega el texto si se lo preguntas a Flyra).

### Servicios en primer plano (permisos especiales)

La app declara dos tipos y Google pide explicarlos con una frase y un vídeo
corto (grábalo con el móvil, súbelo a YouTube como "oculto"):

- **Ubicación** (`FOREGROUND_SERVICE_LOCATION`): "El modo viaje detecta
  cuándo entras en una zona para empezar su audioguía. Mientras está
  activo hay una notificación visible que no se puede ocultar, y se apaga
  desde la app." Vídeo: activar modo viaje, enseñar la notificación, entrar
  en una zona y que suene la guía, y apagarlo.
- **Reproducción multimedia** (`FOREGROUND_SERVICE_MEDIA_PLAYBACK`): "Las
  audioguías siguen sonando con la pantalla bloqueada, con controles en la
  pantalla de bloqueo." Vídeo: poner una audioguía y bloquear el móvil.

## Paso 6: la ficha de la tienda

**Presencia en Google Play → Ficha de Play Store principal**. Los textos
están listos en `mobile/android/fastlane/metadata/android/`: copia
`title.txt`, `short_description.txt` y `full_description.txt` de cada
idioma (en *Gestionar traducciones* añades los otros 9).

Además Play pide:

- **Icono** de 512 × 512 px y **gráfico de funciones** de 1024 × 500 px.
- **Capturas de pantalla** del móvil (mínimo 2). Saca las de la app real
  con el servidor funcionando: la ficha no puede enseñar cosas que la app
  no hace.

## Paso 7: prueba cerrada (12 personas, 14 días)

1. **Pruebas → Prueba cerrada → Crear canal**. Sube el `.aab`.
2. Añade una lista de correos (las cuentas de Google de tus 12+ probadores).
3. Mándales el enlace de "unirse a la prueba". Tienen que **seguir
   apuntados 14 días seguidos**.
4. Pasados los 14 días, en el panel aparece **Solicitar acceso a
   producción**. Google pregunta cómo fue la prueba (qué te dijeron, qué
   cambiaste).

## Paso 8: producción

**Producción → Crear versión** → el mismo `.aab` (o uno nuevo) → países (o
"todos") → **Enviar a revisión**. La primera revisión suele tardar unos días.

## Si una persona pide por correo borrar su cuenta

Comprueba que el correo llega **desde la dirección de la cuenta** y, en el
servidor:

```bash
sudo ~/NoMad-IQ/infrastructure/production/erase-user.sh correo@de-la-persona.com
```

Hace lo mismo que el botón de la app. Respóndele confirmando el borrado
(tienes 30 días según la página publicada).
