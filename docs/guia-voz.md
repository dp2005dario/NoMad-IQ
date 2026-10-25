# Guía para principiantes: Habla con Flyra (voz)

Le preguntas a Flyra **en voz alta** y te contesta (también en voz alta) con
un botón para hacerlo. Se entra desde **Inicio** ("Habla con Flyra").

## Cómo se usa

1. Toca el **micro** grande y pregunta: "¿A qué hora sale mi avión?",
   "Llévame al hotel", "¿Cuánto llevamos gastado?"...
2. Flyra contesta en una tarjeta y lo lee en alto.
3. La tarjeta tiene un botón: "Llévame" (abre la ruta en Google Maps),
   "Aeropuerto", "Abrir"...
4. Si no puedes hablar (biblioteca, mucho ruido), **escríbelo** en la caja de
   abajo. Y los **chips** de ejemplo se pueden tocar.

## Cómo entiende lo que dices (y por qué es gratis)

Es como un recepcionista con una chuleta: para las preguntas de siempre ya
tiene la respuesta apuntada; para las raras, llama a la jefa (el chat).

| Paso | Qué pasa | ¿Dónde? |
|---|---|---|
| Oír | El reconocimiento de voz de Android | En el móvil |
| Entender | Palabras clave por idioma (`voice_intents.dart`) | En el móvil |
| Contestar | Tu vuelo y hotel guardados en Modo fácil | En el móvil |
| Lo que no entiende | Botón "Preguntar a Flyra en el chat" | Servidor (con tope diario) |

Así el servidor **solo** trabaja cuando hace falta: con miles de personas
hablando, la mayoría de preguntas no le cuestan nada.

Lo que entiende: vuelo, hotel, gastos, visado, idioma de la app, SOS,
cosas cerca (agua, baños, wifi), traducir, quedadas, coche y maleta o
escala perdida. Si dices "perdí el vuelo", va a **Si algo falla** (no a la
hora del vuelo): el orden de las palabras clave importa.

**Lo que no hace:** reservar restaurantes. No hay ninguna forma gratis y
fiable en todo el mundo; esa pregunta va al chat de Flyra, que te explica
cómo hacerlo.

## Privacidad

Lo que dices **no sale del móvil** salvo que tú toques "Preguntar a Flyra en
el chat". No se guarda ninguna grabación.

## Glosario

- **Intención (intent):** qué quieres hacer ("ir al hotel"), sacado de la
  frase.
- **Palabra clave:** una palabra que delata la intención ("hotel", "visado").
- **TTS:** "texto a voz", la voz del móvil que lee la respuesta.

## Para tocarlo en VS Code

1. Abre la carpeta `NoMad-IQ` (Archivo → Abrir carpeta).
2. El código está en `mobile/lib/features/voice/`.
3. Para añadir una palabra clave, edítala en `voice_intents.dart` (sin
   tildes) y prueba en la terminal (Terminal → Nuevo terminal):

   ```bash
   cd mobile
   flutter test test/voice_test.dart
   ```
