# Guía de Gastos compartidos (para principiantes)

**Dinero → Tu dinero** es el "bote" de un grupo: un viaje, un piso
compartido, una despedida... Cada uno apunta lo que paga y la app dice en
todo momento **quién debe cuánto a quién**. Se abre con el atajo **Gastos**
de Inicio.

## 0. La idea con una analogía

Imagina una libreta en la mesa del piso. Cada vez que alguien paga algo, lo
apunta: "Cena, 86 €, pagó Álex, entre los cuatro". Al final del viaje
alguien hace cuentas con calculadora. Esta pantalla es esa libreta, pero:

- está en el móvil de todos a la vez;
- hace las cuentas sola y sin errores de céntimos;
- calcula **el menor número de pagos** para quedar en paz (si Bea le debe a
  Álex y Álex a Darío, a lo mejor basta con que Bea le pague a Darío).

## 1. Glosario

| Palabra | Qué significa |
|---|---|
| **Bote** | El grupo que comparte gastos. Tiene una moneda (EUR, JPY...) y un código para invitar |
| **Asiento** | Cada persona del bote es un número (1, 2, 3...) con el nombre que eligió. El servidor nunca enseña el id de cuenta de nadie |
| **Céntimos enteros** | El dinero se guarda como número entero (8600 = 86,00 €). Con decimales, 0,1 + 0,2 no da exactamente 0,3 |
| **Saldo** | Lo que has pagado menos lo que te toca. Positivo = te deben; negativo = debes |
| **Resto mayor** | Cómo se reparten 10 € entre 3 sin perder céntimos: 3,34 + 3,33 + 3,33. El céntimo que sobra va a quien tenía "más decimales" |
| **OCR** | Leer el texto de una foto. Aquí lo hace **ML Kit** dentro del móvil, gratis y sin red |
| **Saldar** | Apuntar que ya le pagaste a alguien. NomadIQ **no mueve dinero**: le pagas como siempre (efectivo, Bizum...) y lo apuntas |

## 2. El viaje de "escanear la cena"

1. Tocas **Añadir gasto → Escanear el ticket**. Se abre la cámara del
   sistema y haces la foto.
2. El móvil lee el texto con ML Kit. El alfabeto se elige por la moneda del
   bote (yenes → japonés, yuanes → chino, wones → coreano, rupias →
   devanagari, el resto → latino).
3. `receipt_parser.dart` convierte las filas en líneas: "2 Croquetas 12,00".
   Salta lo que no son platos (IVA, TARJETA, NIF...) y se queda con el
   **TOTAL**.
4. La foto de la cámara se borra: nunca sale del teléfono.
5. Ves el formulario relleno. Corriges lo que se haya leído mal, eliges
   quién pagó y entre quiénes, y si cada uno paga **a partes iguales** o
   **por lo que tomó**.
6. Se manda `POST /v1/expense-groups/{id}/expenses` con las líneas
   confirmadas (no la foto).
7. Cada amigo puede abrir el gasto y tocar su plato: "esto me lo pedí yo"
   (`PUT .../items/{i}/claim`). Solo puede marcarse a sí mismo.
8. El servidor recalcula los saldos y "quién paga a quién" cada vez que se
   abre el bote.

**Si las líneas no suman el total** (la propina, un descuento...), la
diferencia se reparte en proporción a lo que tomó cada uno.

## 3. Fichero a fichero

| Fichero | Para qué sirve |
|---|---|
| `services/ai-orchestrator/src/ai_orchestrator/migrations/0008_expenses.sql` | Las tablas: botes, miembros, gastos, líneas y pagos |
| `.../expenses/domain.py` | Las cuentas: repartir, saldos y el mínimo de pagos (sin base de datos: fácil de probar) |
| `.../expenses/store.py` | Guardar y leer en PostgreSQL, con bloqueos para que dos personas a la vez no se pisen |
| `.../expenses/api.py` | Las direcciones `/v1/expense-groups/...` |
| `mobile/lib/features/money/money_screen.dart` | La pantalla Dinero con sus pestañas y la lista de botes |
| `mobile/lib/features/money/expense_group_screen.dart` | Un bote: tu saldo, "Saldar", el código y los gastos |
| `mobile/lib/features/money/expense_form_screen.dart` | Apuntar un gasto (a mano o del ticket) |
| `mobile/lib/features/money/expense_detail_screen.dart` | El ticket "impreso" y "esto me lo pedí yo" |
| `mobile/lib/features/money/receipt_scanner.dart` | La foto y el OCR en el móvil |
| `mobile/lib/features/money/receipt_parser.dart` | De texto a líneas de la cuenta |

## 4. Límites (para que nadie llene el servidor)

- 20 personas por bote y 1.000 gastos por bote.
- 100 líneas por ticket.
- Un bote solo lo ve quien está dentro. A los demás se les responde 404,
  como si no existiera.
- Un gasto solo lo puede borrar quien lo apuntó o quien lo pagó.

## 5. Probarlo desde Visual Studio Code

1. **Archivo → Abrir carpeta…** → `NoMad-IQ`, y **Ver → Terminal**.
2. Servidor:
   ```bash
   cd services/ai-orchestrator
   source .venv/bin/activate      # en Windows: .venv\Scripts\activate
   pytest tests/test_expenses.py -q
   ```
   Con la base de datos de verdad (`make up` antes):
   ```bash
   pytest -m integration tests/test_expenses_integration.py -q
   ```
3. App:
   ```bash
   cd mobile
   flutter test test/money_test.dart
   ```
4. En un móvil de verdad: `flutter run`, entra con tu cuenta, **Inicio →
   Gastos → Nuevo bote**. Pasa el código a un amigo para que entre con
   **Unirme con un código**.

## 6. Límites honestos

- El lector de tickets acierta mucho con tickets impresos y rectos. Con
  tickets arrugados o a mano puede leer mal algún número: por eso todo se
  revisa antes de guardar.
- Las cuentas se hacen en la moneda del bote. Si pagas en otra moneda,
  conviértelo antes (la pestaña **Divisas** lo hará por ti).

## 7. Divisas: la moneda que vuela

La pestaña **Divisas** de Dinero convierte entre monedas con los tipos
**oficiales del Banco Central Europeo** (BCE), que se publican gratis cada
día laborable hacia las 16:00 de Fráncfort.

- El servidor (`services/ai-orchestrator/src/ai_orchestrator/fx/`) los pide
  al BCE como mucho una vez cada 6 horas y los guarda en Redis y en memoria.
  Si el BCE no responde, sigue dando la última copia buena.
- `GET /v1/fx/rates` es pública (también para invitados).
- La app guarda la última respuesta en el móvil: sin red, Divisas sigue
  funcionando y avisa de qué día son los tipos.
- Al tocar **Lanzar la moneda**, la moneda sube girando 3 vueltas y media y
  cae enseñando la otra cara: la cantidad ya convertida.

Monedas: las ~30 que publica el BCE (dólar, libra, yen, franco suizo,
yuan, rupia, peso mexicano, real brasileño...). Las que el BCE no publica no
salen en la lista.

## 8. Habitaciones justas

La pestaña **Habitaciones** reparte un alojamiento entre la gente de un bote:

1. Eliges el bote (sus personas son las que duermen), el precio total y las
   habitaciones (doble con baño, doble, individual, sofá cama).
2. Las camas **se sortean** (botón "Sortear de nuevo").
3. **Según la habitación**: cada tipo tiene un peso (1,4 / 1 / 0,9 / 0,6) y
   quien duerme mejor paga un poco más. **Todos igual**: a partes iguales.
4. **Apuntar en el bote** crea un gasto "por lo que tomó cada uno": cada
   habitación es una línea y la "toman" quienes duermen en ella. Así queda en
   las cuentas del bote como cualquier otro gasto.

El reparto usa el mismo método que el servidor (resto mayor): nunca se
pierde ni sobra un céntimo.

## 9. Bote común y modo pareja

La pestaña **Bote común** tiene dos modos:

**Grupo (la hucha).** Es como el sobre con billetes que lleva uno en la
mochila: todos ponen al principio y se paga desde ahí.

- Para el servidor, la hucha es el **asiento 0**. Poner dinero = un pago al
  asiento 0; pagar con la hucha = un gasto cuyo pagador es el asiento 0; que
  la hucha te devuelva lo que sobra = un pago con `from_kitty: true`.
- **Pedir a todos** guarda cuánto debe poner cada uno
  (`PUT /v1/expense-groups/{id}/kitty`). Cada persona sale con "Hecho" o
  "Pendiente".
- Así no hacen falta tablas nuevas: las mismas cuentas de siempre (saldos y
  mínimo de pagos) ya saben repartir la hucha.

**Pareja.** Para botes de 2 personas: **A medias** o **Según ingresos**
(por ejemplo 60/40). El porcentaje se guarda en el bote
(`PUT /v1/expense-groups/{id}/weights`) y cada gasto nuevo se reparte con
él (reparto `weights`). En el formulario de gasto también puedes elegir
**Por porcentaje** para un gasto suelto.

Ficheros: `migrations/0009_kitty_weights.sql`, `expenses/domain.py`
(`KITTY`, `kitty()`), `mobile/lib/features/money/kitty_view.dart`.

## 10. Tu dinero fuera

La pestaña **Tu dinero fuera** tiene cuatro partes:

**Cajeros.** Al tocar "Buscar cajeros cerca" se pide la ubicación (solo
entonces). El móvil manda la zona **redondeada a ~1 km** (dos decimales) a
`GET /v1/atms`; el servidor (`services/ai-orchestrator/src/ai_orchestrator/atms/`)
pregunta a **Overpass**, el buscador gratuito de OpenStreetMap, por la casilla
y sus vecinas (~3 km) y lo guarda un día en Redis. El móvil ordena por
distancia con tu posición real y los dibuja en un "radar". Colores: verde =
sin comisión, amarillo = no se sabe, rojo = cobra. Debajo, el consejo que más
dinero ahorra: si el cajero ofrece "cobrar en tu moneda", di que no.

**Tarjetas.** Apuntas cada tarjeta con lo que cobra fuera (pagar %, sacar % y
lo fijo por cada retirada) y cuánto piensas gastar. `travel_cards.dart`
calcula el coste: lo pagado con tarjeta × % de pagar + lo sacado × % de sacar
+ una comisión fija por cada 200 que saques. La más barata sale con "MEJOR
AQUÍ". Se guarda **solo en el móvil** y del número solo los 4 últimos dígitos.

**Presupuesto.** Eliges un bote, tu límite y las fechas. Cuenta **tu parte**
de cada gasto del bote (`trip_budget.dart`). La gráfica enseña lo gastado y
hacia dónde vas con tres ritmos: seguir igual, un 25 % menos o la mitad.

**Seguro.** Se pregunta a la póliza guardada en la Bóveda (llega con ella).

Para probarlo en VS Code: `pytest tests/test_atms.py -q` (servidor) y
`flutter test test/abroad_test.dart` (app).
