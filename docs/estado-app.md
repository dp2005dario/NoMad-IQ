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
| Wear OS (esfera del reloj) | **No existe** | la maqueta v9 la menciona; es otra app |
| Reclamación de retraso (carta + AESA) | Sin verificar | buscar `claim`/`aesa`: solo aparece "claim" en gastos |
| Traductor de cartas con cámara encima del papel | Sin verificar / probablemente parcial | no hay archivo propio de "carta" |
| SOS: mantener 3 s y compartir ubicación en vivo | Sin verificar | revisar `sos_screen.dart` |
| Notificación en vivo con barra Casa→Hotel | Sin verificar | |

## 5. Lo que depende de algo externo (no se arregla solo con código)

- Servidor (Azure/Oracle) con los servicios en marcha y HTTPS: sin él, nada
  de login, Flyra, cámara, grupo ni audioguías funciona en un móvil real.
- Claves: Travelpayouts, Mapillary, Ticketmaster; Firebase para push.
- IA local (Ollama) para Flyra y el reconocimiento de monumentos.
- Play Console y testers (fuera del alcance acordado).

## 6. Siguientes pasos (un PR pequeño cada uno)

1. Fusionar #24 (nombre e icono ECLIPTA).
2. Mensajes de error claros ("no llego al servidor" frente a "ocupado") y
   aviso si la URL del servidor es la de prueba del emulador.
3. Borrar la pantalla provisional `coming_soon` y las entradas muertas.
4. Comprobar de punta a punta, con `docker compose`, el login, Flyra, cámara,
   grupo y gastos, y arreglar lo que falle.
5. Revisar y completar los puntos "sin verificar" de la tabla (SOS 3 s,
   reclamación de retraso, traductor de cartas, notificación en vivo).
