# Guía para principiantes: Visado

Antes de un viaje, la pregunta de siempre: **¿me piden algo para entrar?**
La pantalla **Visado** lo responde con tu pasaporte y tu destino, y si hay
que pedir algo por Internet (el ESTA de EE. UU., la eTA de Canadá, la ETA
del Reino Unido...) te ayuda a rellenarlo con los datos de tu pasaporte.

Se entra desde Inicio (icono del escudo, "Visado") o desde **Papeles** →
"¿Qué me piden para entrar?".

## Qué te dice

| Respuesta | Qué significa |
|---|---|
| No necesitas visado (hasta N días) | Solo el pasaporte en vigor |
| Visado a la llegada | Te lo dan en el aeropuerto (a veces pagando) |
| Necesitas el ESTA / una autorización electrónica | Se pide por Internet en minutos |
| Necesitas un visado electrónico | Por Internet, con más papeles y días |
| Necesitas visado de la embajada | Cita en la embajada o el consulado |
| Ahora no dejan entrar | Prohibición o conflicto: consulta antes |

## De dónde salen los datos (0 €)

Es como llevar un **libro de consulta** dentro de la app: una tabla de 199
pasaportes × 199 países (`mobile/assets/geo/visas.txt`, unos 120 KB) sacada
de passportindex.org (licencia MIT). Ventajas:

- Funciona **sin conexión** y responde al instante.
- **No hay servidor**: da igual que la usen mil o un millón de personas.
- Nadie sabe a qué país piensas viajar.

Las normas cambian: la pantalla siempre dice la fecha de los datos y te
manda a la **web oficial**. Para actualizarla, se vuelve a generar el archivo
(ver más abajo) y sale con la siguiente versión de la app.

## Rellenar el ESTA con tu pasaporte

En la página de la foto del pasaporte hay dos líneas raras con `<<<<`: es la
**zona MRZ** (Machine Readable Zone, "zona que lee una máquina"). Llevan tu
nombre, número, nacionalidad, nacimiento y caducidad, y unos **dígitos de
control**: cuentas que dicen si la lectura salió bien (como la letra del
DNI).

1. Pulsas **Leer mi pasaporte**: se abre la Bóveda con tu huella.
2. La app busca la MRZ en el texto que el móvil leyó de la foto del
   pasaporte al guardarla (sin Internet). Si los dígitos de control no
   cuadran, **no rellena nada**: mejor eso que un dato mal.
3. Te enseña cada dato con un botón **Copiar**. Lo pegas en la web oficial.
   Al minuto se borra del portapapeles, para que otras apps no lo vean.
4. **Abrir la web oficial**: siempre la del Gobierno (nunca webs que cobran
   el doble). Allí pagas la tasa y la envías.
5. Cuando te llegue la aprobación, guárdala en la Bóveda como "Visado".

Tus datos del pasaporte **no se guardan** en ningún sitio nuevo ni se mandan
a nuestro servidor: viven en la memoria del móvil mientras la pantalla está
abierta. Solo se recuerda el **país** de tu pasaporte, para la próxima vez.

¿Por qué no se rellena sola la web oficial? Ninguna web oficial lo permite
sin meter tus datos en un servidor ajeno. Copiar y pegar es más seguro.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `mobile/lib/features/visa/visa_data.dart` | Lee la tabla de visados y los nombres de países |
| `mobile/lib/features/visa/mrz.dart` | Lee la zona MRZ y comprueba los dígitos de control |
| `mobile/lib/features/visa/visa_screen.dart` | La pantalla (veredicto y los 3 pasos) |
| `mobile/lib/features/papers/trip_check.dart` | `entryPermits`: las webs oficiales (ESTA, eTA, ETA, e-Visa...) |
| `mobile/tool/build_visa_data.py` | Regenera `assets/geo/visas.txt` |
| `mobile/tool/flight3d/build_country_names.mjs` | Regenera `assets/geo/country_names.txt` |

## Actualizar los datos (en VS Code)

Abre la carpeta `mobile` en VS Code y, en la terminal (Terminal → New
Terminal):

```bash
curl -L -o passport-index.json https://raw.githubusercontent.com/imorte/passport-index-data/main/passport-index.json
python3 tool/build_visa_data.py passport-index.json assets/geo/visas.txt 2026-02-17
rm passport-index.json
```

(El último número es la fecha que pone en el README de ese repositorio.)

## Probarlo

```bash
cd mobile
flutter test test/visa_test.dart
```
