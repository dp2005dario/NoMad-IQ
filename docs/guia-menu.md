# Guía del traductor de cartas (para principiantes)

El atajo **Traductor de cartas** de Inicio resuelve el momento más incómodo
de un viaje: una carta en japonés y el camarero esperando. Haces una foto y
la app te dice **qué es cada plato, qué lleva, si tiene alérgenos frecuentes
y cómo pedirlo** en el idioma del sitio (con voz).

## 1. La idea con una analogía

Es como llevar a un amigo del país sentado a tu lado: lee la carta, te
cuenta qué es cada cosa y, cuando eliges, lo dice en voz alta por ti.

## 2. Qué sale del móvil y qué no

| Cosa | ¿Sale del teléfono? |
|---|---|
| La **foto** de la carta | **No**, nunca. Se lee en el móvil y se borra |
| Las **líneas de texto** que se leyeron | Sí, van al servidor para traducirlas |
| La **traducción** | Vuelve al móvil. El servidor no la guarda |

El texto lo lee **ML Kit** de Google dentro del teléfono (gratis, sin red y
sin cuenta). El alfabeto del lector se elige con el **idioma del sitio** que
eliges arriba: japonés, chino, coreano y devanagari tienen lector propio; el
resto usa el alfabeto latino.

## 3. Glosario

| Palabra | Qué significa |
|---|---|
| **OCR** | Leer el texto de una foto |
| **Idioma del sitio** | Dónde estás comiendo: decide el alfabeto del lector y el idioma del "pídelo así" |
| **Cupo diario** | Cuántas cartas puedes traducir al día gratis (20 por persona). Al día siguiente se renueva |
| **Salida estructurada** | Se le pide al modelo un JSON con un formato fijo, no texto libre: así la app no tiene que adivinar nada |

## 4. Cómo lo hace el servidor (y por qué cuesta 0 €)

`services/ai-orchestrator/src/ai_orchestrator/menu/`:

- `domain.py`: los límites. Como mucho **80 líneas** y **3.000 letras** por
  carta, y 40 platos de respuesta. El modelo corre en nuestra máquina, así
  que lo que se controla es el tiempo de máquina.
- `service.py`: el cupo diario en Redis (`ai:menu:quota:v1`), las
  instrucciones para Flyra y la **validación de lo que contesta**: un plato
  cuyo nombre original **no esté de verdad en la carta se descarta**, los
  repetidos se quitan y los textos se recortan. Si el modelo falla o tarda,
  **no te cuenta** la carta.
- La ruta es `POST /v1/menu/translate` y **necesita sesión**: así cada
  persona tiene su cupo y nadie puede gastar la máquina de forma anónima.
- El texto de la carta **no se escribe en los registros**: solo cuántas
  líneas y cuántos platos.

## 5. Los alérgenos, con honestidad

Flyra avisa solo de los alérgenos frecuentes de los que está segura (gluten,
lácteos, huevo, cacahuete, marisco, pescado, soja, sésamo, frutos secos) y la
pantalla pone siempre debajo: **es una ayuda, no una garantía; pregunta al
personal**. Con una alergia grave, la última palabra la tiene el restaurante.

## 6. Fichero a fichero

| Fichero | Para qué sirve |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/menu/domain.py` | Los límites y los tipos |
| `.../menu/service.py` | Cupo, instrucciones y validación de la respuesta |
| `mobile/lib/features/money/receipt_scanner.dart` | La foto y el OCR en el móvil (compartido con los tickets) |
| `mobile/lib/features/menu/menu_api.dart` | Hablar con el servidor |
| `mobile/lib/features/menu/menu_screen.dart` | La pantalla, la ficha del plato y la voz |

## 7. Probarlo desde Visual Studio Code

1. **Archivo → Abrir carpeta…** → `ECLIPTA`, y **Ver → Terminal**.
2. Servidor:
   ```bash
   cd services/ai-orchestrator
   source .venv/bin/activate      # en Windows: .venv\Scripts\activate
   pytest tests/test_menu.py -q
   ```
3. App:
   ```bash
   cd mobile
   flutter test test/menu_test.dart
   ```
4. En un móvil de verdad: `flutter run`, **Inicio → Traductor de cartas**,
   elige el idioma del sitio y fotografía una carta.

## 8. Límites honestos

- Sin Ollama (el modelo) la pantalla dice "Flyra está ocupada": no hay
  traducción de cartas sin modelo.
- Una carta escrita a mano, con letra muy decorada o muy torcida se lee mal:
  prueba con más luz y la carta plana.
- Flyra puede equivocarse al adivinar qué lleva un plato. Si no lo sabe, la
  app deja la descripción vacía en vez de inventarla.
