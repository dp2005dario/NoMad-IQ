# Guía para principiantes: Widgets (ECLIPTA fuera de la app)

Un **widget** es un recuadro de una app que pones en el escritorio del móvil
(la pantalla donde están los iconos) y que enseña información sin abrir la
app. ECLIPTA tiene tres, y además un **aviso "en directo"** el día del vuelo
que también sale en el **reloj**.

Se entra desde Inicio, con el icono de los cuadraditos (Widgets).

## Los tres widgets

| Widget | Qué enseña | De dónde sale |
|---|---|---|
| **Tu vuelo** | "Sales en 5 h" → "Hora de ir al aeropuerto" → "Embarque en 40 min" → "En vuelo · 46 %" (con barra) → "Has llegado a Tokio" | "Tu próximo vuelo" (el mismo del Modo fácil), guardado solo en el móvil |
| **Chollo de hoy** | El vuelo que más ha bajado hoy desde tu aeropuerto | La misma lista de chollos de Vuelos |
| **Presupuesto** | Cuánto te queda **hoy**: lo que queda del presupuesto ÷ los días que faltan | El presupuesto que pones en Dinero → "Tu dinero fuera" |

### ¿Cómo cambia el widget del vuelo si la app está cerrada?

Un widget de Android no puede ejecutar el código de la app. Por eso, cada vez
que abres ECLIPTA, la app prepara **todas** las "fotos fijas" que el widget
va a enseñar (ya traducidas) con la hora a partir de la que vale cada una:
una por hora el día antes, cada media hora antes de embarcar y cada 15
minutos durante el vuelo. Android despierta al widget justo a esas horas y
el widget (código en Kotlin) solo elige la que toca.

Ventajas: funciona **sin Internet** (también en modo avión), no hace falta
ningún servidor y casi no gasta batería (una alarma cada vez).

La hora de llegada es una **estimación**: la distancia en línea recta entre
los dos aeropuertos a velocidad de avión, más 30 minutos. No hay un servicio
gratis y fiable de horarios de vuelos en directo para miles de usuarios.

### Añadir un widget al escritorio

- En la pantalla Widgets toca **Añadir al escritorio** debajo del que
  quieras (si tu móvil lo permite).
- O a mano: mantén pulsado un hueco del escritorio → **Widgets** → busca
  **ECLIPTA** y arrástralo.

## El aviso "en directo"

El día del vuelo te sale un aviso fijo que se va cambiando solo:

1. 3 horas antes: "Hora de ir al aeropuerto".
2. 40 minutos antes: "Embarcando · puerta K42".
3. Al despegar: "En vuelo · Madrid → Tokio" (sin sonido).
4. Al llegar: "¡Bienvenido a Tokio!" (se quita solo a las 3 horas).

Se programa **en tu móvil** con las alarmas de Android, así que llega aunque
estés en modo avión. Se puede apagar en la pantalla Widgets.

## El reloj

Si llevas un reloj **Wear OS**, Android le pasa los avisos del móvil solo:
el aviso "en directo" sale también en la muñeca y vibra cuando cambia. Por
eso no hace falta una app aparte para el reloj (ni el gasto de hacerla).

## Privacidad y coste

- El vuelo y el presupuesto se quedan **en el móvil**; el widget solo enseña
  lo que ya tienes en la app.
- "Borrar mi cuenta" vacía los widgets y quita los avisos programados.
- El chollo es la misma petición que ya hace Vuelos, y el servidor la tiene
  en caché. La app pone los widgets al día como mucho **cada 10 minutos**,
  aunque abras y cierres la app muchas veces: así miles de usuarios no
  cuestan nada extra.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `mobile/lib/features/widgets/widget_snapshots.dart` | Las cuentas: fotos fijas del vuelo, del chollo y del presupuesto |
| `mobile/lib/features/widgets/widget_sync.dart` | Lo pone todo al día y los pasos del aviso "en directo" |
| `mobile/lib/features/widgets/home_widgets.dart` | Habla con Android (paquete `home_widget`) y programa los avisos |
| `mobile/lib/features/widgets/widgets_screen.dart` | La pantalla Widgets con la vista previa |
| `mobile/android/app/src/main/kotlin/com/nomadiq/app/NomadWidgets.kt` | Los widgets en Android: eligen la foto fija y la pintan |
| `mobile/android/app/src/main/res/layout/nomad_widget.xml` | El diseño del widget |
| `mobile/test/widgets_test.dart` | Las pruebas |

## Probarlo en VS Code

1. Abre la carpeta `ECLIPTA` (Archivo → Abrir carpeta).
2. Terminal → Nueva terminal:

   ```bash
   cd mobile
   flutter test test/widgets_test.dart
   ```

3. En un Android de verdad: `flutter run`, entra en Widgets, añade tu vuelo
   y toca "Añadir al escritorio". Para ver el aviso, pon un vuelo que salga
   dentro de 3 horas y unos minutos y espera.
