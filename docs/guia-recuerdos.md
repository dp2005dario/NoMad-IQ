# Guía para principiantes: Recuerdos

**Recuerdos** junta dos pantallas de las maquetas:

- **La cámara de viaje** ("Recuerdo"): haces una foto o un vídeo corto y la
  foto lleva encima la **pegatina del viaje**:
  `NOMADIQ · DÍA 2`, `MADRID`, `22 oct 2026 · atardecer`.
- **La historia automática** ("Recuerdos"): con tus fotos, tu ruta y tus
  sellos, la app monta sola una historia de unos 30 segundos, como las de
  Instagram.

Se entra desde Inicio, con el icono de la galería de fotos.

## Cómo funciona la cámara de viaje

1. En Recuerdos, toca **Cámara de viaje** (el botón de abajo).
2. Elige **Foto** o **Vídeo**. La pegatina se puede quitar con el botón
   "Pegatina del viaje". Los vídeos se guardan **sin** pegatina (pintarla en
   un vídeo necesita un programa de edición pesado dentro de la app).
3. Al hacer la foto ya está **guardada** en tus Recuerdos. Desde ahí puedes
   **Compartir** (abre el menú del móvil: Instagram, WhatsApp...),
   **Repetir** (la borra y vuelves a la cámara) o **Hacer otra**.

Los vídeos duran como mucho **30 segundos** y se paran solos.

### ¿Y la música y los stickers de Instagram?

Se ponen en Instagram. NomadIQ le pasa la foto o el vídeo por el menú de
compartir del móvil, que funciona con **cualquier** app sin pedir permisos ni
cuentas de desarrollador de Meta. Por eso no tienes que hacer nada para que
"compartir a Instagram" funcione.

## La historia automática

- **Portada**: las ciudades del viaje ("Madrid → Lisboa") y las fechas.
- **Hasta 6 fotos**, repartidas por todo el viaje (no las 6 últimas), con el
  pie `DÍA 1 · MADRID`.
- **Las cifras**: días, ciudades, fotos y vídeos, y sellos nuevos del
  Pasaporte.

Hay tres estilos: **Cine** (fundidos, ~30 s), **Viñetas** (marco blanco y
bocadillo amarillo, como un cómic) y **Rápido** (corte seco, más corto).
Toca a la derecha para avanzar, a la izquierda para volver, y mantén pulsado
para pausar.

**El día 1** es el del recuerdo más antiguo del último mes. Si no es el día
en que empezó tu viaje, toca "El viaje empezó el..." y elige otra fecha.

**Compartir historia** manda las fotos de la historia y un texto resumen
("Madrid → Lisboa: 4 días, 12 fotos y vídeos. Hecho con NomadIQ."). No se
fabrica un vídeo en el móvil: hacerlo necesita un codificador de vídeo que
haría la app decenas de MB más grande y gastaría mucha batería.

## Privacidad

- Las fotos y los vídeos se guardan en la **carpeta privada de la app**, en
  tu móvil. **No se suben a ningún servidor**. Solo sale lo que tú compartes.
- No aparecen en la galería del móvil (otras apps no las ven). Si quieres una
  en la galería, compártela y elige "Guardar" o "Galería".
- Como mucho 300 recuerdos, para que el móvil no se llene sin avisar.
- "Borrar mi cuenta" (Ajustes) borra también todos tus recuerdos.
- El micrófono solo se pide la primera vez que pasas a **Vídeo**.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `mobile/lib/features/memories/memories.dart` | La lista de recuerdos, el día del viaje, las cifras y qué fotos salen en la historia |
| `mobile/lib/features/memories/travel_camera.dart` | La cámara (foto y vídeo) y la pegatina pintada sobre la foto |
| `mobile/lib/features/memories/travel_camera_screen.dart` | La pantalla de la cámara de viaje |
| `mobile/lib/features/memories/memories_screen.dart` | Recuerdos y el reproductor de la historia |
| `mobile/test/memories_test.dart` | Las pruebas |

## Probarlo en VS Code

1. Abre la carpeta `NoMad-IQ` (Archivo → Abrir carpeta).
2. Abre una terminal (Terminal → Nueva terminal) y escribe:

   ```bash
   cd mobile
   flutter test test/memories_test.dart
   ```

3. Para verlo en tu móvil Android (con la depuración USB activada):
   `flutter run`. En Inicio toca **Recuerdos**.
