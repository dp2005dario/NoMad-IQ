# Guía de Papeles y derechos (para principiantes)

Atajo **Papeles y derechos** en Inicio. Dos partes:

## 1. Antes de salir

Escribes el aeropuerto de destino (código de 3 letras, `NRT`) y el día de
vuelta, y tocas **Revisar con la Bóveda** (pide tu huella). La app mira SOLO
las fechas de caducidad de tus documentos guardados (`trip_check.dart`):

- **Pasaporte:** que siga valiendo **6 meses después de volver**. Es lo que
  piden muchos países (Japón, Tailandia...). Si tienes dos (doble
  nacionalidad), vale el que más dura.
- **Seguro de viaje:** que haya uno y no caduque antes de volver.
- **Permiso de entrada electrónico** (ESTA de EE. UU., eTA de Canadá, ETA de
  Reino Unido...): se enseña el enlace a la **web oficial**. Si tu pasaporte lo
  necesita depende de tu nacionalidad, y la web oficial lo dice. Nunca se
  enlazan intermediarios que cobran de más.

Nada sale del móvil.

## 2. Tus derechos como pasajero (EU261)

El **Reglamento (CE) 261/2004** obliga a las aerolíneas a pagar si un vuelo
llega 3 horas tarde o más, se cancela con poco aviso o te dejan en tierra
por overbooking. Cubre los vuelos que **salen de la UE** (cualquier
aerolínea) y los que **llegan a la UE con aerolínea europea**.

| Distancia | Cuánto |
|---|---|
| Hasta 1.500 km | 250 € |
| 1.500–3.500 km (o dentro de la UE, más de 1.500 km) | 400 € |
| Más de 3.500 km | 600 € (300 € si el retraso fue de 3 a 4 horas) |

La distancia se calcula entre los dos aeropuertos con la fórmula de la Tierra
redonda (ortodrómica), igual que la norma.

**Preparar la reclamación** pide tu nombre, el código de reserva, el número
de vuelo y la fecha, y abre tu correo con una carta **en inglés** ya escrita
(`claimLetter` en `eu261.dart`). Solo tienes que poner la dirección de
reclamaciones de la aerolínea (está en su web) y enviar. Sin comisiones.

**Ojo:** si fue por "circunstancias extraordinarias" (tormenta, huelga de
controladores) no hay compensación, pero la aerolínea tiene que demostrarlo.

## 3. Probarlo desde Visual Studio Code

`cd mobile` y `flutter test test/papers_test.dart` (comprueba las cantidades
con vuelos reales: Madrid–Barcelona, Madrid–Nueva York, Helsinki–Tenerife...).
