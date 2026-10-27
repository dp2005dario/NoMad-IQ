# Guía para principiantes: Modo coche

Si alquilas un coche en el viaje, el **Modo coche** te enseña con botones
grandes lo que necesitas por la carretera: **gasolina** (o cargador
eléctrico), **dónde aparcar** y las **zonas de tráfico limitado** (las ZTL
italianas, las ZBE españolas...) que ponen multas a los turistas. Y las
**audioguías** suenan por los altavoces del coche.

Se entra desde **Inicio**, en los atajos ("Coche").

> Úsalo con el coche parado o que lo maneje el copiloto. Por eso todo se
> puede **leer en voz alta** (el altavoz de arriba a la derecha lo apaga).

## Los cuatro botones

| Botón | Qué hace |
|---|---|
| Audioguía | Enciende el modo viaje: al pasar por una zona con audioguía te avisa y suena por el coche (Bluetooth o Android Auto). |
| Gasolina | La gasolinera más cercana (o el cargador eléctrico, con "Eléctrico"), su marca y horario. "Ir" abre Google Maps conduciendo. |
| Aparcar | Aparcamientos públicos con nombre o de disuasión, si son de pago y cuántas plazas tienen. |
| Zona ZTL | Las zonas de tráfico limitado a menos de 15 km, con su web oficial, y un enlace a todas las de Europa. |

## Android Auto

ECLIPTA se declara como **app de audio** para Android Auto
(`android/app/src/main/res/xml/automotive_app_desc.xml`). Así la audioguía
que estás escuchando sale en la pantalla del coche con sus botones, usando el
mismo reproductor de siempre. No hace falta pedir nada especial a Google:
las apps de audio están permitidas en Android Auto.

## Lo que no está (y por qué)

- **Navegación giro a giro**: la hace Google Maps. Hacerla nosotros
  costaría servidores de rutas y datos de tráfico de pago.
- **Precio de la gasolina**: solo algunos países lo publican gratis, cada uno
  a su manera. Queda para la v2, país a país.
- **Plazas libres ahora mismo**: no existen datos abiertos fiables.

## De dónde salen los datos (0 €)

De **OpenStreetMap**, a través de nuestro servidor:

```
GET /v1/drive?lat=40.65&lon=14.50
```

- La app manda solo la **casilla de ~5 km** donde estás: el servidor no sabe
  por qué calle vas.
- Casillas grandes a propósito: en coche cruzas muchas casillas pequeñas en
  pocos minutos; con 5 km, una pregunta cubre un buen rato de viaje.
- Cada casilla se guarda **una semana** en Redis y comparte con Cajeros,
  Aeropuerto y Cerca de ti **un solo límite** hacia OpenStreetMap.
- Cada tipo tiene su tope (150 gasolineras, 150 aparcamientos, 100
  cargadores, 20 zonas) para que una gran ciudad no deje fuera a los demás.

## Dónde está el código

| Archivo | Qué hace |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/drive/` | Servidor: consulta, caché y `/v1/drive` |
| `mobile/lib/features/drive/drive_api.dart` | La app pide la casilla y lee la respuesta |
| `mobile/lib/features/drive/drive_screen.dart` | La pantalla |
| `infrastructure/edge/dynamic.yml` | La puerta de entrada deja pasar solo `GET /v1/drive` |

## Probarlo en VS Code

Abre la carpeta del proyecto y la terminal (Ver → Terminal):

```bash
cd services/ai-orchestrator
.venv/bin/pytest tests/test_drive.py
cd ../../mobile
flutter test test/drive_test.dart
```
