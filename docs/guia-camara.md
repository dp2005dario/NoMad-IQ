# Guía del modo cámara (para principiantes)

La pestaña **Cámara** (el botón verde del centro) reconoce el monumento al
que apuntas: te dice qué es, cuándo se construyó y su historia, te la lee en
voz alta y te da un **sello** para tu Pasaporte.

## 0. La idea con una analogía

Imagina que preguntas a un guía local: "¿Qué es ese edificio?". El guía no
necesita adivinar entre todos los edificios del mundo: **sabe dónde estáis**
(GPS) y **ve hacia dónde señalas** (brújula). Con eso solo quedan dos o tres
posibles. Si además tiene buena vista (un modelo de visión), mira la foto
para estar seguro.

## 1. Glosario

| Palabra | Qué significa |
|---|---|
| **Wikidata** | Enciclopedia de datos libre: cada lugar tiene coordenadas, año, foto… Le preguntamos "¿qué lugares famosos hay a menos de 350 m?" |
| **Rumbo (heading)** | Hacia dónde mira el móvil: 0° = norte, 90° = este. Lo da la brújula |
| **Modelo de visión** | Un modelo de IA "con ojos" (p. ej. `qwen2.5vl:3b` en Ollama) que mira la foto y elige cuál de los 5 candidatos se ve |
| **Casilla de caché** | La ciudad dividida en cuadrados de ~110 m. Los lugares de cada casilla se guardan 7 días en Redis: mil turistas en la Puerta del Sol = una sola pregunta a Wikidata |
| **Sello** | Recuerdo de cada monumento reconocido, guardado solo en tu móvil (lo verás en el Pasaporte) |

## 2. El viaje de un "Reconocer"

1. Tocas el botón. La app hace una foto pequeña (480p, ~100 KB) y pide tu
   posición al GPS.
2. Manda `POST /v1/landmarks/recognize` con la posición, el rumbo, el idioma
   y la foto.
3. El servidor gasta un uso de tu cupo diario (100 por cuenta).
4. Busca lugares famosos cerca (caché o Wikidata) y los ordena: más cerca,
   más en la dirección a la que miras y más famosos (en cuántas Wikipedias
   salen). Lo que queda a tu espalda se descarta.
5. Si hay modelo de visión, le enseña la foto con los 5 primeros:
   - elige uno → **RECONOCIDO**;
   - dice que no ve ninguno → "¿Es alguno de estos?";
   - no está o tarda más de 25 s → **¿ES ESTE?** con el más probable.
6. La ficha (año, foto, resumen de Wikipedia en tu idioma) se guarda 7 días.

**Privacidad:** la foto solo se usa para esa pregunta; ni se guarda ni se
escribe en los registros, igual que tus coordenadas. La cámara se apaga sola
al cambiar de pestaña o salir de la app, y nunca se pide el micrófono.

## 3. Fichero a fichero

| Fichero | Para qué sirve |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/landmarks/domain.py` | Qué manda la app (comprueba que la foto es un JPEG) y qué recibe |
| `.../landmarks/wikidata.py` | Las consultas a Wikidata (solo con números y códigos validados) |
| `.../landmarks/service.py` | Distancias, rumbos, el orden, el modelo de visión y la caché |
| `.../quota.py` | Los cupos diarios (los comparte con el chat de Flyra) |
| `mobile/lib/features/camera/camera_screen.dart` | La pestaña: visor, escáner, ficha |
| `mobile/lib/features/camera/camera_device.dart` | La cámara y la brújula de verdad |
| `mobile/lib/features/camera/speaker.dart` | La voz del móvil para "Escuchar" |
| `mobile/lib/features/camera/stamps.dart` | Los sellos del Pasaporte |

## 4. Ajustes (variables de entorno del ai-orchestrator)

| Variable | Por defecto | Para qué |
|---|---|---|
| `LANDMARKS_ENABLED` | `true` | Apagar el modo cámara |
| `LANDMARK_DAILY_LIMIT` | `100` | Usos gratis por persona y día |
| `LANDMARK_VISION_MODEL` | vacío | Modelo de visión de Ollama. Para activarlo: `ollama pull qwen2.5vl:3b` y `LANDMARK_VISION_MODEL=qwen2.5vl:3b` |
| `LANDMARK_VISION_TIMEOUT_SECONDS` | `25` | Cuánto esperamos al modelo de visión |

## 5. Probarlo desde Visual Studio Code

1. **Archivo → Abrir carpeta…** → `NoMad-IQ`, y **Ver → Terminal**.
2. Servidor:
   ```bash
   cd services/ai-orchestrator
   source .venv/bin/activate      # en Windows: .venv\Scripts\activate
   pytest tests/test_landmarks.py -q
   ```
3. App:
   ```bash
   cd mobile
   flutter test test/camera_test.dart
   ```
4. En un móvil de verdad (la cámara no funciona en todos los emuladores):
   conecta el Android por USB, `flutter run`, entra con tu cuenta y toca el
   botón verde del centro.

## 6. Límites honestos

- Sin modelo de visión, la app pregunta "¿Es este?" en vez de afirmarlo: el
  GPS en ciudad puede fallar 20-50 m.
- Solo reconoce lugares que están en Wikidata con coordenadas (casi todos
  los monumentos conocidos del mundo lo están).

## Mi pasaporte (los sellos como cromos)

Cada vez que tocas **Mi sello** en la ficha de un monumento, la app guarda
un sello **solo en tu móvil** (nombre, fecha, dónde está, año y una frase).
El atajo **Mi pasaporte** de Inicio los enseña como un librito:

1. **La tapa** azul con letras doradas y tu nombre. Tócala para abrirla.
2. **Una página por país.** El país se adivina sin Internet con el
   aeropuerto más cercano al monumento (los mismos datos que usa el SOS). La
   bandera es un emoji: dos "letras regionales" que el móvil junta y dibuja
   como bandera, sin ninguna imagen. Los sellos guardados antes de esta
   versión no tienen lugar y salen en **Otros lugares**.
3. **Cada sello es un cromo** con rareza según la edad del monumento:
   antes del año 1000 → **Legendaria** (oro), antes de 1600 → **Épica**
   (violeta), antes de 1900 → **Rara** (azul), el resto → **Común**.
4. Al tocar un cromo: su historia, **Escuchar** (la voz del móvil) y **Ver
   en el mapa** (abre OpenStreetMap en el navegador).

Ficheros: `mobile/lib/features/passport/passport.dart` (las cuentas: rareza,
páginas, bandera) y `passport_screen.dart` (la pantalla). Para probarlo en VS
Code: `cd mobile` y `flutter test test/passport_test.dart`.
