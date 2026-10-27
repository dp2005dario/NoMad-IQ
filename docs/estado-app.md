# Estado de la app ECLIPTA (auditoría del 27-10-2026)

Guía para principiantes: qué hay hecho, qué no, y por qué a veces "no va".
Método: leí el código de `mobile/` (rama del PR #24, que es la que lleva el
nombre ECLIPTA), pasé `flutter analyze` (0 problemas) y `flutter test`
(370 pruebas, todas bien). **No he probado la app en un móvil real ni contra
los servicios en marcha**: lo que sigue es lectura de código, no una prueba
de uso. Lo que no he podido comprobar lo marco como "sin verificar".

## 1. Resumen corto

- La app **no es una maqueta con pantallas vacías**. Hay 60 pantallas con
  código real (mapa, cámara, vuelos, grupo, bóveda, gastos, audioguías, Flyra...).
- Las pantallas "Muy pronto" (`/soon/:feature`) **ya no las usa ningún botón**:
  la lista de `Feature` en `coming_soon_screen.dart` conserva nombres antiguos
  (map, camera, flights, group, vault, expenses, audioguides, flyra, nearby,
  transport, radar...) pero todos los botones apuntan hoy a su pantalla real.
  Es código muerto que se puede borrar.
- Por tanto, lo que "no va" casi seguro no es falta de pantallas, sino
  **(a) que la app instalada es una versión vieja** y **(b) que la app no
  encuentra el servidor**.

## 2. Por qué la app instalada dice NomadIQ y tiene el icono viejo

El renombrado a ECLIPTA y el icono de la golondrina están en el **PR #24**
(`rediseno-bienvenida-eclipta`), que **todavía no está fusionado en `main`**.
En `main` no aparece la palabra "ECLIPTA" en ningún archivo. Un APK hecho
desde `main` (o desde un Codespace en `main`) sale con `android:label="NomadIQ"`
y el icono antiguo. Solución: fusionar el PR #24 y recompilar. Además, el APK
nuevo tiene otro identificador (`com.eclipta.app`): Android lo instala como una
app distinta; hay que desinstalar la vieja.

## 3. Por qué Flyra y la cámara dicen "ocupado" / varias cosas no van

Dato verificado en `mobile/lib/core/config.dart`: la dirección del servidor
por defecto es `http://10.0.2.2:8080`, que **solo existe dentro del emulador
de Android**. Un APK compilado sin `--dart-define=NOMADIQ_API_URL=https://...`
(es lo que hace el CI: `flutter build apk --debug`) no encuentra el servidor
en un móvil real. En `camera_screen.dart` cualquier error que no sea "sin
internet" o "sin escaneos" se enseña como "El modo cámara está muy ocupado"
(`_Problem.busy`), y en Flyra los errores se muestran como "ocupada". Es decir:
**el mensaje "ocupado" tapa el motivo real**. Pendiente de confirmar con
DARIO: ¿con qué URL se compiló su APK y estaba el puerto 8080 público?
Mejora prevista: mensajes distintos para "servidor inalcanzable" y "servidor
ocupado".

Aparte, `camera_device.dart` llama "cámara ocupada o inexistente" a cualquier
fallo de `CameraException` que no sea permiso. Sin verificar en móvil real.

## 4. Inventario por funciones (existe = hay pantalla con código real)

| Zona | Estado | Notas |
|---|---|---|
| Bienvenida, login Google/correo/invitado, idioma | Existe (video en PR #24) | Google necesita configuración en el servidor |
| Inicio, menú, perfil con avatares y foto | Existe | foto de Google depende de `photo_url` del servidor |
| Mapa (MapLibre, zonas, calles, calle real) | Existe | "Ver la calle" necesita token Mapillary; mapa 3D con clima de la maqueta v7: sin verificar |
| Cámara de monumentos | Existe | necesita servidor; permiso de cámara |
| Botón central cámara + historia Instagram | Existe (`travel_camera_screen`, `memories`) | Instagram pide App ID de Meta |
| Audioguías | Existe | necesita servidor y zonas |
| Vuelos: alertas, búsqueda, mapa de tarifas, ruta 3D | Existe | precios reales necesitan token Travelpayouts |
| Explorar, dormir barato, escala, eventos, copiar viaje | Existe | eventos: clave Ticketmaster |
| Grupo, chat del viaje, planes y votación | Existe | necesita servidor |
| Gastos: salas, bote, reparto, escaneo de ticket (OCR local) | Existe | OCR es ML Kit en el móvil |
| Divisas, billetes, cajeros, tarjetas, seguro | Existe | tipos de cambio vía servidor |
| Bóveda cifrada (huella, PDF, imagen) | Existe | cifrado local; sin verificar en móvil |
| Flyra chat | Existe | necesita servidor `ai-orchestrator` + Ollama (IA local) |
| Voz, asistente, traductor (ML Kit) | Existe | modelos de idioma se bajan la primera vez |
| Papeles, visado, antes de salir (eSIM, CO2, maleta) | Existe | datos de eSIM de ejemplo, ver `before_trip.dart` |
| SOS, ayuda, problemas, coche, aeropuerto, colas, radar, transporte | Existe | |
| Widgets Android, avisos push | Existe | push necesita Firebase (`com.eclipta.app`) |
| Pasaporte y cromos, recuerdos | Existe | |
| Cambiar foto de perfil (cámara, galería, 6 avatares, quitar) | Hecho en este PR (solo en el móvil) | ver `docs/guia-ajustes.md`; sin probar en móvil real. Borrar cuenta existe; cambiar contraseña: no encontrado |
| Wear OS (esfera del reloj) | **No existe** | otra app (ver C1) |
| Reclamación de retraso (carta + AESA) | Sin verificar | buscar `claim`/`aesa`: solo aparece "claim" en gastos |
| Traductor de cartas con cámara encima del papel | Sin verificar / probablemente parcial | no hay archivo propio de "carta" |
| SOS: mantener 3 s y compartir ubicación en vivo | Sin verificar | revisar `sos_screen.dart` |
| Notificación en vivo con barra Casa→Hotel | Sin verificar | |

## 5. Lista completa de lo que queda (27-10-2026)

Búsqueda hecha en `mobile/lib`, `services/` e `infrastructure/` de: "pronto",
TODO/FIXME, stubs, mocks, "Fake", flags apagados y funciones simuladas.
Resultado: **no hay TODO/FIXME ni clases Fake en el código de producción**
(los Fake solo viven en `test/`). Quedan estos puntos, clasificados:

### A. Lo hago yo en el PR #26
Hecho:
1. Auditoría, mensajes claros de "servicio no activado" (404), foto de perfil
   y quitar la pantalla provisional `coming_soon`.
2. **Entrar con Google**: código completo en app y `auth-gateway`
   (`POST /v1/auth/google`, migración V2 con `photo_url`), listo para activar
   con `GOOGLE_CLIENT_ID` (servidor) y `NOMADIQ_GOOGLE_CLIENT_ID` (app). Ver
   `docs/guia-google-login.md`. Sin el ID, avisa con claridad (503 / "no disponible").
3. **Cambiar contraseña** (app + `POST /v1/auth/password`).
4. Aviso en la Bienvenida si el APK apunta al servidor del emulador.
5. Borrados los textos muertos (`comingSoon*`, `moneySoon`, `googleSoon`).
6. Comprobado leyendo el código: SOS (pulsación de 3 s + SMS con tu ubicación),
   carta de reclamación EU261 (`eu261.dart`), traductor de cartas
   (`menu_screen.dart` + `/v1/menu/translate`), aviso "en directo" (`LiveFlight`).

Siguen pendientes en este PR: paso a AESA en la reclamación y el selector de
clima del mapa (Sol/Nubes/Lluvia), que NO existe hoy (lo había dado por
"sin verificar": ya lo verifiqué, falta).

### B. Depende de algo externo (7 puntos)
1. **Client ID de Google** (Google Cloud Console / Firebase) para el login con
   Google, y configurar el servidor para que llegue `photo_url`.
2. **Servidor con HTTPS** (Azure/Oracle): en versión publicada la app exige
   https (`config.dart`). Sin servidor, nada de login, Flyra, cámara, grupo ni
   audioguías en un móvil real.
3. **IA local (Ollama)**: con `LLM_ENABLED=false` Flyra no existe (404) y la
   cámara no usa el modelo de visión. Hace falta máquina con memoria para el
   modelo (`make ollama`).
4. **Claves**: Travelpayouts (precios y comisión), Mapillary (calle real),
   Ticketmaster (eventos), identificador de afiliado de Booking.
5. **Firebase** con `com.eclipta.app` y su `google-services.json` para los
   avisos push; App ID de Meta para "Crear historia" en Instagram.
6. **Correo saliente** (SMTP o servicio de correo) para "recuperar contraseña":
   sin él no hay forma de enviar el enlace. No está hecho.
7. **Revisión nativa** de las traducciones y comprobar a mano los enlaces
   oficiales de visados (ver `lo-que-tienes-que-hacer.md`).

### C. Imposible desde aquí o es otra app (3 puntos)
1. **Wear OS** (esfera del reloj): es otra app, con su propio proyecto.
2. **Probar de extremo a extremo con `docker compose`**: este entorno no tiene
   demonio de Docker (`docker ps` falla), así que no he podido levantar los
   servicios. Hay que hacerlo en el Codespace de DARIO o en el servidor.
3. **Probar en un móvil real** (cámara, sonido del vídeo, biometría de la
   bóveda, widgets): solo tengo `flutter analyze` y los tests.

Total aproximado: A con 2 puntos pendientes, B con 7, C con 3. Play Console y testers quedan fuera del alcance acordado.
quedan fuera del alcance acordado.

## 6. Qué se probó y qué no
- Probado: `flutter analyze` (0 problemas), `dart format` y `flutter test`
  (373 pruebas, todas bien) en esta rama.
- No probado: nada contra servidores reales ni en móvil (ver C2 y C3).
