# Guía para principiantes: "Viajo con…"

Una pantalla con dos pestañas para dos situaciones que cambian las normas del
avión: viajar con tu **mascota** o estando **embarazada**. Entra desde Inicio,
con el icono de la huella.

Todo se calcula **en el móvil** con reglas generales. No se manda nada a ningún
servidor, y las semanas de embarazo ni siquiera se guardan: es un dato de salud
y solo hace falta mientras miras la pantalla.

## Mi mascota

- Escribe el peso de tu mascota y el del transportín. Si juntos pesan **8 kg o
  menos**, puede ir contigo en cabina (lo más habitual en Europa; algunas
  aerolíneas dejan 10 kg y otras ninguno). Si pasa, tendrá que ir en bodega.
- La lista **"Para viajar por la UE"** tiene las tres cosas que pide la norma
  europea: microchip (puesto antes de la vacuna), vacuna de la rabia (al menos
  21 días antes) y pasaporte europeo para animales. Lo que marcas se guarda solo
  en tu móvil.
- Fuera de la UE cada país pide cosas distintas, y la pantalla lo dice en vez de
  inventar.

## Embarazada

- Mueve la barra hasta las semanas que tendrás **el día del vuelo de vuelta**
  (es el que cuenta).
- Hasta la semana 28: se puede volar sin papeles. De la 28 a la 36: certificado
  médico de los últimos 7 días. Desde la 36 (la 32 si son gemelos): casi
  ninguna aerolínea deja embarcar.

## Dónde está el código

| Archivo | Qué hace |
| --- | --- |
| `mobile/lib/features/travel_with/travel_with.dart` | las reglas (cabina, rabia, semanas) y las casillas guardadas |
| `mobile/lib/features/travel_with/travel_with_screen.dart` | la pantalla con sus dos pestañas |
| `mobile/test/travel_with_test.dart` | las pruebas |

Para probarlo en VS Code: `Terminal > Nuevo terminal`, y luego
`cd mobile` y `flutter test test/travel_with_test.dart`.

## Glosario

- **Cabina / bodega**: la cabina es donde vas tú; la bodega es la parte de
  abajo del avión, donde va el equipaje facturado.
- **Transportín**: la bolsa o caja donde viaja la mascota.
