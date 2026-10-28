# Guía: notificaciones push con FCM real (para principiantes)

Por defecto el `notifier` habla con un **FCM falso** (`fcm-fake`) que solo
existe en tu ordenador. Esta guía explica cómo hacer que hable con **Google de
verdad** para que los avisos lleguen a teléfonos reales. El modo de desarrollo
no cambia: si no haces nada de esto, todo sigue como siempre.

## Cómo funciona (en corto)

- El `notifier` necesita una **clave de cuenta de servicio** (un fichero JSON)
  para demostrarle a Google que es él quien envía.
- Esa clave es una **contraseña**: quien la tenga puede enviar avisos a tus
  usuarios. Por eso vive **fuera del repositorio** y se monta en el contenedor
  **de solo lectura**. Nunca se sube a git ni entra en una imagen de Docker.
- Con FCM real el notifier exige `https` y se niega a arrancar si mezclas la
  clave con `FCM_INSECURE_DEV=true`. El override ya lo tiene en cuenta.

## Paso 1. Generar la clave en Firebase

1. Entra en <https://console.firebase.google.com> y abre tu proyecto
   (de ejemplo usamos `eclipta-9ef7e`; el tuyo puede ser otro).
2. Rueda dentada junto a "Descripción general" > **Configuración del proyecto**.
3. Pestaña **Cuentas de servicio**.
4. Pulsa **Generar nueva clave privada** y confirma. Se descarga un `.json`.
5. Anota el **ID del proyecto** (pestaña "General"): es tu `FCM_PROJECT_ID`.

Consejo: si la cuenta tiene el rol "Administrador de Firebase Cloud Messaging"
o equivalente, es suficiente; no uses una con permisos de propietario.

## Paso 2. Subir la clave al servidor

Desde tu ordenador (cambia usuario y servidor):

```bash
scp ~/Descargas/eclipta-9ef7e-firebase-adminsdk-xxxx.json usuario@servidor:/tmp/fcm.json
```

En el servidor, déjala en una ruta FUERA del repo y con permisos estrictos.
El contenedor corre como el usuario `nonroot` (uid 65532), así que ese usuario
debe poder leerla:

```bash
sudo mkdir -p /etc/nomadiq
sudo mv /tmp/fcm.json /etc/nomadiq/fcm-service-account.json
sudo chown 65532:65532 /etc/nomadiq/fcm-service-account.json
sudo chmod 400 /etc/nomadiq/fcm-service-account.json
```

Después **borra el .json de tu ordenador** (o guárdalo en un gestor de
contraseñas) y no lo envíes por chat ni correo.

## Paso 3. Arrancar con FCM real

En `infrastructure/.env` añade (hay un ejemplo comentado en `.env.example`):

```bash
FCM_PROJECT_ID=eclipta-9ef7e
FCM_CREDENTIALS_HOST_PATH=/etc/nomadiq/fcm-service-account.json
# FCM_ENDPOINT=https://fcm.googleapis.com   # es el valor por defecto
```

Y arranca con el fichero de override (desde `infrastructure/`):

```bash
docker compose -f docker-compose.yml -f docker-compose.fcm.yml --profile apps up -d
```

Qué cambia respecto al modo normal: se usa `https://fcm.googleapis.com`, se
monta la clave en `/run/secrets/fcm-service-account.json` (solo lectura), se
quita `FCM_INSECURE_DEV` y el notifier ya no espera a `fcm-fake`. Hace falta
Docker Compose 2.24 o superior (`docker compose version`).

Para volver al modo de desarrollo, arranca sin `-f docker-compose.fcm.yml`.

## Paso 4. Probar

1. Comprueba que el notifier arrancó y está sano:

   ```bash
   docker compose -f docker-compose.yml -f docker-compose.fcm.yml --profile apps logs notifier
   curl -s http://127.0.0.1:8090/readyz
   ```

   Si faltan variables o el JSON no es una cuenta de servicio, el notifier se
   niega a arrancar y el log lo explica.
2. Instala la app en un móvil real, inicia sesión y entra en una zona (por
   ejemplo, usa un viaje de prueba). La app registra su token en
   `PUT /v1/devices/{id}`.
3. Provoca un aviso (zona o alerta de precio) y mira si llega al teléfono.
   Los pasos del flujo completo están en `docs/guia-notificaciones.md`.
4. Si no llega, mira `docker compose ... logs notifier`: un 401/403 suele ser
   permisos de la cuenta de servicio o un `FCM_PROJECT_ID` que no corresponde
   a esa clave.

## Si algo falla

| Síntoma | Causa probable |
|---|---|
| `Define FCM_CREDENTIALS_HOST_PATH en .env` | Falta esa variable en `.env` |
| Compose crea un directorio en vez de montar el fichero | La ruta del host no existe: revisa que sea el fichero |
| `permission denied` leyendo el JSON | Haz `chown 65532:65532` y `chmod 400` (paso 2) |
| 401/403 de Google | El proyecto o los permisos de la cuenta no coinciden |

## Seguridad: lo que NUNCA debes hacer

- Subir el `.json` a git (`.gitignore` y `.dockerignore` bloquean los nombres
  habituales, pero no es una excusa para guardarlo en el repo).
- Pegarlo en una incidencia, chat o captura de pantalla.
- Si se filtra: en Firebase > Cuentas de servicio, borra esa clave y genera otra.
