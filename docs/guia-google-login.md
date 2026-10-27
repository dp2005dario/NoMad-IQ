# Guía: entrar con Google y cambiar la contraseña (para principiantes)

## La idea con una analogía
Cuando pulsas "Continuar con Google", Google te da un **justificante firmado**
(el `id_token`): "esta persona es dueña de esta cuenta de Google". La app se lo
enseña a nuestro servidor (`auth-gateway`) y el servidor comprueba con las
claves públicas de Google que la firma es de verdad, que va dirigido a NUESTRA
app y que el correo está verificado. Si todo cuadra, entra con sus propios pases.
La app nunca ve la contraseña de Google.

## Qué hay hecho
- App: `mobile/lib/auth/google_id_token.dart` (paquete `google_sign_in`),
  botón en la Bienvenida, `SessionController.signInWithGoogle`.
- Servidor: `POST /v1/auth/google` (`GoogleIdTokenVerifier.java`). Si ya había
  una cuenta con ese correo, se enlaza; si no, se crea. Guarda la foto de Google
  (`photo_url`, migración `V2`) y el app la enseña.
- Cambiar contraseña: `POST /v1/auth/password` (pide la actual; cierra las
  sesiones de los demás móviles y devuelve pases nuevos para este). Botón en
  Ajustes > Cuenta.
- Sin `GOOGLE_CLIENT_ID` en el servidor, `/v1/auth/google` responde **503**
  y la app dice "El acceso con Google no está disponible ahora". Nunca acepta
  un token sin poder comprobarlo.

## Lo que te toca a ti (DARIO): conseguir el Client ID
1. Google Cloud Console > APIs y servicios > Credenciales > crear un
   **ID de cliente OAuth de tipo "Aplicación web"**. Copia el ID
   (`xxxx.apps.googleusercontent.com`). No es un secreto.
2. Crea otro ID de tipo **Android** con el paquete `com.eclipta.app` y la huella
   SHA-1 de la llave con la que firmas el APK (la de depuración sirve para probar).
3. Ponlo en el servidor: `infrastructure/.env` → `GOOGLE_CLIENT_ID=...`
   (en producción, `config.env`).
4. Compila la app con el MISMO ID web:
   `--dart-define=NOMADIQ_GOOGLE_CLIENT_ID=xxxx.apps.googleusercontent.com`.
5. iOS (si algún día): añadir `GIDClientID` a `Info.plist`. No está hecho.

## Lo que NO está hecho
- **Recuperar la contraseña por correo**: necesita enviar correos (un servidor
  SMTP o un servicio de correo). Sin eso no hay forma de mandar el enlace.
- No he podido probar el botón con una cuenta de Google real (necesita tu
  Client ID y un móvil). Sí hay tests de la parte del servidor (con tokens
  firmados con una clave de prueba) y de la app (con un Google falso).
