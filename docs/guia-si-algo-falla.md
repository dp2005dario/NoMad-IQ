# Guía para principiantes: Si algo falla

Dos sustos típicos de un viaje: **la maleta no sale por la cinta** y
**pierdes el vuelo de conexión** porque el primero llegó tarde. Esta
pantalla te dice qué hacer en cada caso y te deja la reclamación escrita.

Se entra desde **Inicio**, en los atajos ("Si algo falla").

## Mi maleta

1. Elige si **no ha llegado** o si **llegó rota**.
2. Sigue la lista (se va marcando y se guarda):
   - Antes de salir de la sala de cintas, pide en el mostrador de
     equipajes el **parte (PIR)**. Sin él, reclamar es mucho más difícil.
   - Apunta la referencia del parte (tipo `MADIB12345`) y el número de la
     etiqueta de la maleta.
   - Guarda los tickets de lo básico que compres (puedes apuntarlo en Dinero).
   - Manda la reclamación por escrito **antes del plazo**.
3. Pon el día que aterrizaste (y el día que te la devolvieron, si ya
   apareció) y la app te dice **tu plazo**:

| Caso | Plazo (Convenio de Montreal) |
|---|---|
| Llegó rota | 7 días desde que te la dan |
| Llegó tarde | 21 días desde que te la dan |
| No aparece | A los 21 días cuenta como perdida y reclamas su valor |

La aerolínea responde hasta **1.519 DEG** (unos 1.800 €) por pasajero.

4. **Escribir la reclamación** abre tu correo con la carta ya escrita en
   inglés (la entienden todas las aerolíneas). Solo pones la dirección de
   la aerolínea (en su web, "baggage claims") y adjuntas los tickets.

### ¿Y la etiqueta Bluetooth de la maqueta?

La maqueta veía la maleta en un mapa. Los AirTag, SmartTag y Tile usan
redes privadas de Apple, Samsung y Tile que ninguna app de fuera puede leer.
Lo que sí hacemos: en la app de tu etiqueta, "Compartir ubicación del
objeto", y pegas ese enlace aquí. Va dentro de la carta, y muchas
aerolíneas ya lo usan para encontrar maletas.

## Escala perdida

- **Todo en una sola reserva** (un código para los dos vuelos): **no compres
  otro billete**. La aerolínea tiene que llevarte en el siguiente vuelo sin
  coste.
- **Billetes sueltos**: nadie está obligado a reubicarte. "Buscar vuelos de
  hoy" abre nuestro buscador con tu aeropuerto y tu destino.
- **Tus derechos**: comida y bebida mientras esperas, y hotel si pasas la
  noche (en vuelos que salen de la UE o con aerolínea europea). Si llegas
  más de 3 h tarde, "Reclamar el retraso" te lleva a Papeles (de 250 a 600 €).
- Hay una frase en inglés lista para leer en el mostrador.

La maqueta reservaba sola el vuelo alternativo. Eso necesita los sistemas
de reservas de las aerolíneas, que no son públicos: lo hace el mostrador.

## Privacidad y coste

Todo se guarda **solo en el móvil** (`LocalData.bagClaim`). No hay
servidor: 0 €. "Borrar mi cuenta" lo borra con lo demás.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `mobile/lib/features/trouble/bag_claim.dart` | Plazos, la carta y cómo se guarda |
| `mobile/lib/features/trouble/trouble_screen.dart` | La pantalla de las dos pestañas |

## Probarlo en VS Code

Abre la carpeta del proyecto y la terminal (Ver → Terminal):

```bash
cd mobile
flutter test test/trouble_test.dart
```
