# Guía para principiantes: Asistente

Dos ayudas para cuando no entiendes lo que tienes delante.

Se entra desde **Inicio** o desde los atajos del **Mapa** ("Asistente").

## Conversación: un intérprete en la mesa

Pones el móvil en la mesa entre tú y la otra persona:

- La **mitad de abajo** es la tuya, en tu idioma.
- La **mitad de arriba** está **girada** para la otra persona, en su idioma.
- Cada uno pulsa **su** micrófono y habla. El móvil lo pasa a texto, lo
  traduce y lo **lee en alto** en el idioma del otro (el altavoz de arriba lo
  silencia).
- Si hay mucho ruido, el botón del teclado deja **escribirlo**.
- "Su idioma" cambia el idioma de la otra persona (34 idiomas; cada uno sale
  con su nombre en su propio idioma para que lo reconozca).

### Sin internet (y gratis)

Todo pasa **dentro del móvil**:

| Pieza | Qué usa |
|---|---|
| Oír | El reconocimiento de voz de Android (`speech_to_text`) |
| Traducir | ML Kit de Google en el móvil (`google_mlkit_translation`) |
| Hablar | La voz del móvil (`flutter_tts`) |

La primera vez la app te pide **descargar** los idiomas (unos 30 MB cada
uno, solo con wifi). Después funciona **en modo avión**. Nada de lo que dices
pasa por nuestros servidores: 0 € y privado.

> Para oír sin internet, Android también necesita tener el idioma de voz
> instalado (Ajustes → Sistema → Idiomas → Reconocimiento de voz). Si no lo
> tiene, usa el servicio de voz del propio Android.

### Lo que no está

La maqueta decía "con cascos: cada uno oye su idioma". Mandar dos audios
distintos a dos auriculares a la vez no lo permite Android de forma fiable:
el móvil lee en alto cada traducción por turnos.

## Pregunta: ¿qué es esto?

- **Apuntar con la cámara** abre el modo cámara, que reconoce el monumento
  (ya lo teníamos) y te lo cuenta.
- **Pregúntale a Flyra**: preguntas listas ("¿Qué hay dentro?", "¿Dónde está
  la mejor foto?", "Cuéntame más") que abren el chat con Flyra.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `mobile/lib/features/assistant/interpreter.dart` | Oír y traducir en el móvil (y las versiones de mentira para los tests) |
| `mobile/lib/features/assistant/assistant_screen.dart` | La pantalla de las dos pestañas |
| `mobile/android/app/src/main/AndroidManifest.xml` | Permiso para usar el reconocimiento de voz |

## Probarlo en VS Code

```bash
cd mobile
flutter test test/assistant_test.dart
```

En un móvil de verdad: conecta tu Android por USB, en VS Code abajo a la
derecha elige el dispositivo y pulsa F5.
