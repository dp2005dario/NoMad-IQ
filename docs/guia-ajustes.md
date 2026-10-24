# Guía de Ajustes, "Descargar mis datos" y "Borrar mi cuenta" (para principiantes)

**Ajustes** se abre tocando tu círculo (la inicial) arriba a la derecha de
Inicio. Desde ahí: el idioma, la Bóveda, cerrar sesión, **descargar una copia
de tus datos** y **borrar tu cuenta para siempre**.

## 0. ¿Por qué esto es obligatorio?

- **Google Play** no publica una app que deja crear cuentas si no deja
  también **borrarlas desde dentro de la propia app** (y desde una web).
- El **RGPD** (la ley europea de privacidad) da derecho a llevarte una copia
  de tus datos ("portabilidad") y a que se borren ("derecho al olvido").

## 1. Glosario

| Palabra | Qué significa |
|---|---|
| **Borrado en cascada** | Al borrar la fila del usuario, PostgreSQL borra solo sus filas "hijas" (sus tokens de refresco) porque la tabla lo dice (`ON DELETE CASCADE`) |
| **Anonimizar** | Dejar el dato pero sin que se sepa de quién es. Tu asiento en un bote compartido se queda (si no, las cuentas de tus amigos se descuadrarían) pero pasa a llamarse "—" y a no estar unido a ninguna cuenta |
| **Idempotente** | Hacerlo dos veces da lo mismo que una. Si se corta la red a mitad, la app puede repetir el borrado sin miedo |
| **Reautenticar** | Volver a pedir la contraseña antes de algo grave. Así, quien coja tu móvil desbloqueado no puede borrar tu cuenta |

## 2. Qué pasa al tocar "Sí, borrar mi cuenta"

El orden importa (`mobile/lib/features/settings/account_data.dart`, clase
`AccountEraser`):

1. **Contraseña.** La app entra otra vez con tu email y la contraseña que
   escribes. Si está mal, no se toca NADA.
2. **Datos en los servicios**, mientras el pase aún vale:
   - `DELETE /v1/me/data` (ai-orchestrator): borra tus recomendaciones de
     vuelos y los botes donde estabas solo; en los botes y viajes en grupo
     compartidos tu asiento queda anónimo y tus preferencias privadas se borran.
   - `DELETE /v1/fares/me` (price-consumer): tus rutas vigiladas y tus avisos
     de precio.
3. **La cuenta** (`DELETE /v1/me` en el auth-gateway, con la contraseña otra
   vez): expulsa todas tus sesiones en todos los móviles y borra la fila.
   Antes, como al cerrar sesión, el móvil se da de baja de los avisos push.
4. **Este móvil:** se borra la Bóveda (los archivos y su llave del Keystore) y
   tus ajustes personales (tu chat con Flyra, sellos, tarjetas, presupuesto...).
   Se quedan el idioma y los tipos de cambio, que no dicen nada de ti.

Si el paso 2 o 3 falla (sin red), la cuenta **sigue viva** y el mensaje lo
dice: se puede volver a intentar.

**¿Y las copias de seguridad?** El borrado es inmediato. Las copias de
seguridad del servidor se renuevan solas y en 30 días ya no queda nada.

## 3. "Descargar mis datos"

`collectMyData()` pide a cada servicio lo tuyo (rutas vigiladas, avisos,
recomendaciones, botes con sus gastos, viajes en grupo) y le suma lo que solo
está en este móvil. Se guarda como **un archivo JSON** con el selector
"Guardar como" de Android (`nomadiq-mis-datos-AAAA-MM-DD.json`). JSON es
texto con llaves `{ }`: se abre con cualquier editor, también con VS Code.

Si un servicio no responde, la copia sale igual y ese apartado dice
`"unavailable"`. Los documentos de la Bóveda **no** van en la copia: sacarlos
en claro a un archivo sería un riesgo. Se ven en la propia Bóveda.

## 3 bis. Privacidad

**Ajustes → Privacidad y seguridad**:

- **Ubicación en segundo plano**: es el mismo "modo viaje" del Mapa.
- **Avisos de audioguías** y **Chollos de vuelos**: se pueden apagar. Ojo
  al truco: el servidor NO se entera. El aviso llega cifrado, el móvil lo
  abre y, si es de un tipo apagado, no lo enseña
  (`mobile/lib/features/push/notice_prefs.dart`). Así no guardamos tus gustos.
- **Avisos de seguridad**: siempre encendidos (el interruptor se ve, pero no
  se mueve).
- **Olvidar este teléfono**: da de baja el móvil en el notifier, borra su
  llave de avisos y el token de Firebase, y no vuelve a registrarse solo
  hasta que tocas **Volver a activar los avisos**.

## 4. Fichero a fichero

| Fichero | Para qué sirve |
|---|---|
| `services/auth-gateway/.../api/UserController.java` | `DELETE /v1/me` |
| `services/auth-gateway/.../auth/AuthService.java` | `deleteAccount`: frenos anti-fuerza-bruta, contraseña, expulsar sesiones, borrar |
| `services/ai-orchestrator/src/ai_orchestrator/erasure.py` | Borrar y anonimizar en UNA transacción |
| `services/price-consumer/internal/store/fares.go` | `EraseUser` |
| `mobile/lib/features/settings/settings_screen.dart` | La pantalla y los diálogos |
| `mobile/lib/features/settings/account_data.dart` | La copia y el borrado, sin pantallas (fácil de probar) |
| `mobile/lib/features/settings/privacy_screen.dart` | La pantalla Privacidad |
| `mobile/lib/features/push/notice_prefs.dart` | Qué tipos de aviso has apagado |

## 5. Probarlo desde Visual Studio Code

1. **Archivo → Abrir carpeta…** → `NoMad-IQ`, y **Ver → Terminal**.
2. App: `cd mobile` y `flutter test test/settings_test.dart`.
3. ai-orchestrator: `cd services/ai-orchestrator`, activa el `.venv` y
   `pytest tests/test_erasure.py -q`.
4. price-consumer: `cd services/price-consumer` y `go test ./internal/api/`.
5. auth-gateway (necesita Docker abierto): `cd services/auth-gateway` y
   `mvn verify` (el test `borrarMiCuentaPideLaContrasenaYLoBorraTodo`).

## 6. Lo que te toca a ti para Google Play

En la ficha de Play Console ("Seguridad de los datos") Google pide también
**una web** donde se pueda pedir el borrado sin tener la app. Basta una
página sencilla con un formulario o un email de contacto; la prepararemos con
la política de privacidad.

## Avisos (el historial)

La **campana** de Inicio abre **Avisos**: todo lo que te ha llegado, con
pestañas **Todos / Zonas / Vuelos / Seguridad**. Tocar un aviso abre su
pantalla.

- Cada aviso que el móvil enseña se apunta con su texto ya traducido en
  `LocalData.noticeLog` (los 100 últimos). Lo hace `showPush` en
  `mobile/lib/features/push/firebase_push.dart`, también con la app cerrada.
- Como ese "apunte" puede venir de otro proceso, la pantalla vuelve a leer
  del disco al abrirse (`SettingsStore.reload()`).
- El servidor no guarda qué avisos te llegaron: el historial solo existe en
  tu teléfono y se borra con **Borrar historial** o al borrar la cuenta.

Probarlo en VS Code: `cd mobile` y `flutter test test/notices_test.dart`.
