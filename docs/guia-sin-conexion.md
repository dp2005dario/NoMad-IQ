# Guía para principiantes: "Sin conexión"

Analogía: es como bajarte una serie antes de un viaje en avión. Descargas la
ciudad mientras tienes wifi y luego, en el avión o en el extranjero sin datos,
sigue funcionando.

## Qué se descarga de una ciudad

| Cosa | Para qué | De dónde sale |
| --- | --- | --- |
| El mapa (las "teselas") | ver el mapa y moverte sin datos | OpenFreeMap, guardado por MapLibre en el móvil |
| Los barrios (zonas) | que te avise al entrar en una zona | geo-engine (`GET /v1/zones`) |
| El guion de cada audioguía | poder leerla aunque no haya audio | ai-orchestrator (`GET /v1/audioguides/{zona}`) |
| Los audios `.opus` | escucharla sin red | el mismo servidor, archivo a archivo |

Todo se guarda en la **carpeta privada de la app**: no se ve en la galería, no
lo comparte nadie, y desaparece al desinstalar o al pulsar "Borrar".

## Cómo se usa

1. Entra en **Ajustes** (el avatar de Inicio) y toca **Ciudades sin conexión**.
2. Escribe el código de tres letras del aeropuerto de la ciudad (MAD, NRT, CDG).
   Debajo del campo aparece el nombre de la ciudad para comprobar que es esa.
3. Toca **Descargar**. Verás la barra con los cuatro pasos: barrios, guiones,
   audio y mapa.
4. Cuando termine, la ciudad aparece como una tarjeta con cuántas audioguías
   tiene, lo que ocupa y el día en que se guardó.

Abajo hay dos cosas más:

- **Descargar solo con wifi** (activado de serie): con datos del móvil, la
  descarga espera. Así nadie se gasta la tarifa en el extranjero sin querer.
- **NomadIQ ocupa …**: lo que suman todas las ciudades descargadas.

## Cosas que conviene entender

- **Como mucho 10 ciudades.** Si llegas al límite, la pantalla te pide borrar
  una antes de añadir otra; así el móvil no se llena por sorpresa.
- **Si el mapa no cabe, las audioguías se guardan igual.** La tarjeta lo dice
  ("El mapa no se pudo guardar; las audioguías sí") en vez de hacerte creer
  que está todo listo.
- **El idioma cuenta.** La ciudad se descarga en el idioma que tenías puesto.
  Si luego cambias de idioma, la tarjeta avisa y basta con pulsar
  **Actualizar**.
- **Si una zona todavía no tiene audioguía, se salta.** El servidor las escribe
  cuando alguien entra en la zona por primera vez, así que una ciudad muy nueva
  puede dar "De esa ciudad todavía no hay audioguías".
- **En la audioguía sale una etiqueta "Guardada en el móvil"** cuando lo que
  estás oyendo es la copia descargada y no el servidor.

## Dónde está el código

| Archivo | Qué hace |
| --- | --- |
| `mobile/lib/features/offline/city_pack.dart` | qué lleva el paquete, lo guardado y las cuentas (tamaños, barra, wifi) |
| `mobile/lib/features/offline/city_downloader.dart` | la descarga paso a paso, y "Borrar" |
| `mobile/lib/features/offline/offline_platform.dart` | las piezas reales: archivos, MapLibre y saber si hay wifi |
| `mobile/lib/features/offline/saved_guides.dart` | buscar una audioguía descargada por su zona |
| `mobile/lib/features/offline/offline_screen.dart` | la pantalla |
| `mobile/test/offline_test.dart` | 15 pruebas de todo lo anterior |

El truco del mapa: el estilo del mapa se genera en código (`map_style.dart`),
pero MapLibre pide el estilo por una dirección, así que antes de descargar se
escribe en un archivo `estilo.json` dentro de la carpeta de la ciudad y se le
pasa como `file://…`.

## Cómo probarlo en Visual Studio Code

1. Abre la carpeta `NoMad-IQ` (`Archivo > Abrir carpeta...`).
2. Terminal (`Terminal > Nuevo terminal`) y escribe:

   ```bash
   cd mobile
   flutter test test/offline_test.dart
   ```

3. En un móvil de verdad: `flutter run`, y luego Inicio → avatar → **Ciudades
   sin conexión**. Para comprobar que funciona de verdad, descarga una ciudad,
   pon el móvil en **modo avión** y abre el mapa y una audioguía de esa ciudad.

## Glosario

- **Tesela** (*tile*): un cuadradito del mapa. El mapa entero son miles de
  cuadraditos que se piden según te mueves; al descargar una ciudad se guardan
  todos los de esa zona.
- **Nivel de zoom**: lo cerca que está el mapa. Se guardan del 11 (la ciudad
  entera) al 16 (la calle); cada nivel extra multiplicaría el tamaño por
  cuatro.
- **`.opus`**: el formato del audio de las audioguías. Suena bien ocupando muy
  poco, y Android lo lee de serie.
- **Modo avión**: el móvil apaga todas las antenas. Es la prueba de fuego de
  esta pantalla.
