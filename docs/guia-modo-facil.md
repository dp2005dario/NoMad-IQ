# Guía para principiantes: Modo fácil

El Modo fácil es una pantalla de Inicio pensada para personas mayores o para
quien no se lleva bien con el móvil: **letras grandes, botones enormes y solo
lo importante**. Se activa en **Ajustes → Modo fácil**, y se quita con el botón
**Modo normal** de arriba.

Analogía: es como el mando de la tele "para abuelos", con pocos botones y
grandes.

## Qué enseña

- **Tu vuelo**: la hora, de dónde a dónde, la puerta y **a qué hora salir de
  casa**. Se calcula 3 horas antes: 2 en el aeropuerto y 1 para llegar. Es un
  consejo prudente, no una cuenta del tráfico.
- **Llévame al hotel**: abre Google Maps con la ruta en transporte público hasta
  la dirección del hotel.
- **Llamar a la familia**: usa los contactos del **SOS**. Así no hay que
  apuntarlos dos veces, y si no hay ninguno lleva a añadirlos.
- **Mis papeles** (la Bóveda), **Pregunta a Flyra** y **Emergencia** (el SOS).
- **Ayuda en el aeropuerto**: explica que la asistencia de la aerolínea es
  gratis y que hay que pedirla 48 horas antes.

El vuelo y el hotel se ponen con **"Poner mi viaje"**. Lo puede hacer la propia
persona o alguien de su familia con su móvil. Todo se guarda **solo en este
teléfono**.

## Dónde está el código

| Archivo | Qué hace |
| --- | --- |
| `mobile/lib/features/easy/easy_mode.dart` | el interruptor, el viaje guardado y las cuentas |
| `mobile/lib/features/easy/easy_home_screen.dart` | la pantalla y el formulario del viaje |
| `mobile/test/easy_test.dart` | las pruebas |

Un detalle técnico: Inicio usa `HomeOrEasy`, que "escucha" el interruptor y
cambia de pantalla en cuanto lo tocas, sin reiniciar la app.

Para probarlo en VS Code: `Terminal > Nuevo terminal`, luego `cd mobile` y
`flutter test test/easy_test.dart`.
