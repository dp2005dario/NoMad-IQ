# Guía para principiantes: Perfiles de familia

Una pantalla para apuntar **quién viaja contigo**: nombre, edad, alergias, lo
que necesita (camina poco, silla de coche, carrito, medicación) y lo que le
gusta (museos, comida, playa...). Entra desde Inicio, con el icono de la
familia.

Con eso la app te da **"Así os lo planeo"**: consejos que salen de toda la
familia, y cada uno dice por quién es ("Por Carmen"). Si tocas la tarjeta de
una persona, solo ves los suyos. El botón **"Pedir a Flyra un plan para todos"**
abre Flyra con la familia resumida en la pregunta, que puedes leer y cambiar
antes de mandarla.

## Privacidad

- Las alergias y la medicación son datos de salud, así que los perfiles se
  guardan **cifrados en el móvil** (en el Keystore de Android, como la Bóveda).
- No se mandan a ningún servidor. Solo salen si tú pulsas el botón de Flyra.
- Si borras tu cuenta desde Ajustes, los perfiles también se borran.
- Como mucho 12 personas.

## Dónde está el código

| Archivo | Qué hace |
| --- | --- |
| `mobile/lib/features/family/family.dart` | la persona, los consejos y el almacén cifrado |
| `mobile/lib/features/family/family_screen.dart` | la pantalla y la hoja para añadir o editar |
| `mobile/test/family_test.dart` | las pruebas |

Para probarlo en VS Code: `Terminal > Nuevo terminal`, y luego
`cd mobile` y `flutter test test/family_test.dart`.

## Glosario

- **Keystore**: la caja fuerte del propio Android donde se guardan las llaves
  de cifrado; ni otras apps ni nosotros podemos leerla.
- **Cifrar**: convertir los datos en algo ilegible sin la llave.
