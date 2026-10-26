# Guía para principiantes: "Antes de salir"

Esta pantalla es la lista de "lo que tengo que resolver antes del viaje".
Está pensada para abrirla una vez, dejarla marcada y olvidarte.

Analogía: es el amigo pesado (pero útil) que te pregunta en la puerta
"¿llevas el adaptador? ¿te caduca el pasaporte? ¿vas a tener datos allí?".

## Qué te dice, y de dónde sale cada dato

| Bloque | Qué contesta | De dónde sale |
| --- | --- | --- |
| Datos móviles allí | si tu tarifa funciona igual o te va a cobrar | tabla fija de países con "roaming como en casa" (UE/EEE), dentro de la app |
| Huella del vuelo | cuántos kilos de CO₂ son, comparado con un coche en un año | se calcula **en el móvil** con la distancia y factores públicos (DEFRA) |
| Para la maleta | adaptador, transformador, paraguas, abrigo, crema, eSIM... | el enchufe del país (tabla fija) + el clima medio de ese mes (NASA POWER) |
| Papeles | si el pasaporte o el seguro se quedan cortos | la **Bóveda de tu móvil** (solo se leen las fechas, nunca el documento) |

Nada de esto se manda a ningún sitio. Lo único que sale del móvil es un par de
coordenadas redondeadas para pedir el clima medio del destino, y lo que marcas
de la maleta se guarda **solo en tu teléfono**.

## Cómo se usa

1. En Inicio, toca el icono de la maleta.
2. Escribe los tres códigos del aeropuerto de salida y de llegada (MAD, NRT...).
3. Toca el botón de la fecha y elige el día de salida.
4. El móvil te pedirá la huella para abrir la Bóveda: es para mirar las fechas
   del pasaporte y del seguro. Si no quieres, puedes cancelar y el resto de la
   pantalla sigue funcionando.
5. Ve marcando las casillas. El círculo de arriba sube hasta el 100 %.

## Cosas que conviene entender

- **La huella de CO₂ es una estimación, no una medida.** No existe una API
  gratuita que diga lo que contamina tu vuelo exacto, así que se calcula con
  los gramos por kilómetro y pasajero que publica el gobierno británico
  (DEFRA), por 1,9 (lo que contamina de más por volar a 10 km de altura). Un
  vuelo corto contamina más por kilómetro porque despegar es lo que más gasta.
  La comparación con los árboles es solo para entender el número: plantar
  árboles no "borra" el vuelo.
- **El clima es una media de 30 años, no una previsión.** Si vas en marzo, te
  dice cómo suele ser marzo allí, no cómo estará ese día.
- **Los enchufes son una tabla fija.** Si un país no está en la tabla, la app
  no inventa nada: simplemente no te dice que lleves adaptador.
- **El roaming.** La app sabe si sales de la UE/EEE y si vas dentro. No conoce
  tu tarifa concreta, así que cuando dice "puede cobrar mucho" te está
  recomendando comprobarlo, no afirmando el precio.

## Dónde está el código

| Archivo | Qué hace |
| --- | --- |
| `mobile/lib/features/trip/before_screen.dart` | la pantalla |
| `mobile/lib/features/trip/before_trip.dart` | roaming, lista de la maleta, lo marcado, el porcentaje |
| `mobile/lib/features/trip/co2.dart` | las cuentas de la huella de carbono |
| `mobile/lib/features/trip/plugs.dart` | enchufe y tensión por país, y la zona de roaming libre |
| `mobile/lib/features/papers/trip_check.dart` | revisión del pasaporte y del seguro |
| `mobile/lib/features/flights/climate_api.dart` | el clima medio del mes |
| `mobile/test/trip_test.dart` | las pruebas de todo lo anterior |

## Cómo verlo en Visual Studio Code

1. Abre la carpeta `NoMad-IQ` (menú `Archivo > Abrir carpeta...`).
2. Si es la primera vez, instala la extensión **Flutter** (icono de los
   cuadrados en la barra izquierda, busca "Flutter" y pulsa *Install*).
3. Abre un terminal dentro de VS Code: menú `Terminal > Nuevo terminal`.
4. Escribe:

   ```bash
   cd mobile
   flutter test test/trip_test.dart
   ```

   Si sale `All tests passed!`, todo esta parte funciona.

5. Para verlo en el móvil: conecta el teléfono por cable, con la depuración
   USB activada, y escribe `flutter run`. Dentro de la app, el icono de la
   maleta en Inicio.

## Glosario

- **Roaming**: usar tu tarifa de móvil en otro país.
- **eSIM**: una tarjeta SIM que no es de plástico, se instala desde una app.
  Sirve para tener datos en el destino sin cambiar tu número.
- **Adaptador** vs **transformador**: el adaptador solo cambia la *forma* de
  la clavija; el transformador cambia la *tensión* (los voltios). Los
  cargadores de móvil y portátil casi siempre aceptan las dos tensiones (mira
  la letra pequeña: "100-240 V"), pero un secador o una plancha de pelo, no.
- **CO₂e**: "dióxido de carbono equivalente". Mete en un solo número todos los
  gases que calientan el planeta, no solo el CO₂.
- **DEFRA**: el ministerio británico de medio ambiente. Publica cada año los
  factores de emisión que usa casi todo el mundo para estas cuentas.
- **NASA POWER**: un servicio gratuito de la NASA con medias de temperatura y
  lluvia de todo el planeta, calculadas con satélites.

## Enchufes

La sección **Enchufes** dibuja los enchufes del país al que vas (tipo A, C,
G...) para reconocer el adaptador en la tienda, y dice:

- "Compra un adaptador para enchufes tipo G" o "no necesitas adaptador",
  comparando con los de tu país.
- El voltaje de allí y, si es distinto del tuyo, que mires la etiqueta del
  cargador (100-240 V = vale; si no, transformador).

Los dibujos están en `mobile/lib/features/trip/plug_painter.dart` (son
sencillos, para reconocer la forma, no planos a escala). Los datos por
país, en `plugs.dart`.
