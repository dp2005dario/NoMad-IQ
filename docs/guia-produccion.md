# Guía para principiantes: poner NomadIQ en Internet (gratis)

Hasta ahora todo corría en tu ordenador con `docker compose`. Esta guía
explica cómo ponerlo en un **servidor de verdad**, encendido 24 horas, para
que la app del móvil hable con él desde cualquier parte del mundo. Y todo
**sin pagar nada y sin riesgo de facturas sorpresa**.

> Analogía: hasta ahora la cocina estaba en tu casa y solo comías tú. Ahora
> alquilamos (gratis) un local en la calle, con cerradura, alarma, copia de
> las recetas en una caja fuerte y un timbre que te avisa al móvil si algo
> se quema.

## Qué vamos a usar (y por qué es gratis)

| Pieza | Para qué | Por qué 0 € |
|---|---|---|
| **Oracle Cloud "Always Free"** | El servidor (una máquina ARM) | Oracle regala para siempre 2 núcleos ARM, 12 GB de memoria, 200 GB de disco y 10 TB al mes de tráfico de salida ([lista oficial](https://docs.oracle.com/en-us/iaas/Content/FreeTier/resourceref.htm)) |
| **k3s** | Kubernetes ligero dentro del servidor | Software libre |
| **DuckDNS** | Un nombre (`minomadiq.duckdns.org`) en vez de un número IP | Gratis |
| **Let's Encrypt** | El candado https | Gratis, se renueva solo |
| **Oracle Object Storage** | Guardar las copias de seguridad cifradas | 20 GB gratis |
| **ntfy** | Avisos de "algo va mal" en tu móvil | App y servicio gratis |
| **Firebase (plan Spark)** | Notificaciones push | Plan gratis |

### La regla de oro para no pagar nunca

**NO pases la cuenta de Oracle a "Pay As You Go"** (pago por uso) y **no
cambies Firebase al plan Blaze**. Mientras la cuenta sea "Free Tier",
Oracle **no puede** cobrarte: si algo pidiera más recursos de los gratis,
simplemente no se crea. Por eso todos los servicios tienen un techo de
memoria y CPU y, si llega mucha gente, la app va más lenta o pone en cola,
pero **nunca** compra más máquina.

Además pondremos una **alarma de presupuesto** (paso 3) que te avisa si
alguna vez aparece un gasto, aunque sea de 1 céntimo.

## Glosario rápido

- **Servidor / VM**: un ordenador en un centro de datos que alquilas.
- **SSH**: la forma de "entrar" a ese ordenador por terminal, con una llave.
- **Kubernetes (k8s) / k3s**: el "encargado" que arranca cada servicio, lo
  reinicia si se cae y lo vigila. k3s es una versión pequeña.
- **Pod**: un servicio corriendo dentro de Kubernetes (1 o varios contenedores).
- **Secret**: un dato secreto guardado en Kubernetes (cifrado en disco).
- **mTLS**: cada servicio enseña su "carné" (certificado) al hablar con otro;
  si no lo tiene, no le abren. Los fabrica y renueva solo **cert-manager**.
- **ARM**: un tipo de procesador (como el de los móviles). El servidor gratis
  es ARM; por eso algunas imágenes las construimos nosotros.

## Lo que hay en `infrastructure/production/`

| Fichero | Qué es |
|---|---|
| `bootstrap.sh` | Prepara un servidor nuevo (se ejecuta UNA vez) |
| `deploy.sh` | Construye todo y lo despliega (cada vez que actualices) |
| `secrets.env.example` | Plantilla de los secretos (contraseñas, tokens) |
| `config.env.example` | Plantilla de la configuración normal (dominio, modelo de IA) |
| `k8s/00…70` | Las piezas de Kubernetes, numeradas en orden |
| `gen_services.py` | Genera `k8s/20-services.yaml` desde una tabla |
| `render_edge.py` | Pasa las reglas de la puerta de desarrollo a producción (https + mTLS) |
| `postgres.Dockerfile`, `audio-worker.Dockerfile` | Imágenes que construimos nosotros |

Ábrelos en **VS Code** (Archivo → Abrir carpeta → `NoMad-IQ`). Con la
extensión **YAML** (de Red Hat) verás colores y errores en los `.yaml`, y con
**Kubernetes** (de Microsoft) te explica cada campo al pasar el ratón.

---

## Paso 1: crear la cuenta de Oracle Cloud

1. Ve a <https://www.oracle.com/cloud/free/> y pulsa **Start for free**.
2. Te pedirá una tarjeta **solo para comprobar que eres una persona**. Con
   la cuenta "Free Tier" no se cobra nada.
3. **Región de casa (Home Region)**: elige una cercana (p. ej. Madrid o
   Frankfurt). **No se puede cambiar después** y la máquina gratis solo se
   crea en ella.

> Aviso honesto: a veces Oracle dice "Out of capacity" al crear la máquina
> ARM gratis en regiones muy usadas. No es un error tuyo: vuelve a intentarlo
> unas horas más tarde.

## Paso 2: crear el servidor

En la consola de Oracle: **Compute → Instances → Create instance**.

- **Image**: Canonical **Ubuntu 24.04**.
- **Shape**: *Ampere* → **VM.Standard.A1.Flex**, con **2 OCPU y 12 GB**
  (lo máximo gratis).
- **Networking**: deja que cree una red (VCN) nueva con IP pública.
- **SSH keys**: "Generate a key pair" y **descarga la llave privada**.
  Guárdala bien: es la llave de la puerta.
- **Boot volume**: marca "Specify a custom boot volume size" y pon
  **200 GB** (todo el disco gratis).

Abre las puertas web en la red de Oracle: en la instancia, pulsa la
**Subnet** → **Security List** → **Add Ingress Rules**: origen `0.0.0.0/0`,
TCP, puertos **80** y **443**. (Sin esto, Let's Encrypt no puede darte el
candado.)

## Paso 3: alarma de presupuesto a 0 €

Consola de Oracle → **Billing & Cost Management → Budgets → Create Budget**:

- Importe: **1** (la mínima).
- Alerta: **Actual spend**, umbral **1 %** → tu correo.

Si alguna vez te llega ese correo, algo se ha salido de lo gratis: avísame
y lo apagamos antes de que cueste nada.

> Sobre "máquinas inactivas": Oracle puede **parar** (no borrar) una
> máquina gratis si durante 7 días usa menos del 20 % de CPU, red **y**
> memoria. NomadIQ tiene Kafka, la IA y la base de datos cargados en
> memoria, así que lo normal es superar ese 20 % de memoria. Si un día la
> paran, la arrancas desde la consola y todo vuelve (los datos siguen en el
> disco y además hay copias).

## Paso 4: un nombre para tu servidor (DuckDNS)

1. Entra en <https://www.duckdns.org> con tu cuenta de Google o GitHub.
2. Crea un subdominio, p. ej. `minomadiq` → `minomadiq.duckdns.org`.
3. En "current ip" pon la **IP pública** de tu instancia de Oracle y pulsa
   *update ip*. (La IP de Oracle no cambia mientras no borres la máquina.)

## Paso 5: copias de seguridad (Object Storage)

1. Consola → **Storage → Buckets → Create Bucket**: nombre
   `nomadiq-backups`, *Standard*, **sin** acceso público.
2. Arriba a la derecha, tu perfil → **My profile → Customer secret keys →
   Generate secret key**. Copia la **Secret** (solo se ve una vez) y el
   **Access key**. Van a `BACKUP_S3_SECRET_KEY` y `BACKUP_S3_ACCESS_KEY`.
3. El **namespace** aparece en *Tenancy details*. El endpoint es:
   `https://<namespace>.compat.objectstorage.<region>.oraclecloud.com`
   (la región como `eu-madrid-1`). Va a `BACKUP_S3_ENDPOINT` y la región a
   `BACKUP_S3_REGION`.

Cada noche (03:30 UTC) se hace una copia de la base de datos, se **cifra
en el servidor** con tu `BACKUP_PASSPHRASE` y solo entonces se sube.
Oracle guarda un archivo que no puede leer. Se conservan 14 días.

## Paso 6: avisos al móvil (ntfy)

1. Instala la app **ntfy** (Play Store, gratis).
2. Inventa un nombre de "tema" largo y difícil de adivinar (es como una
   contraseña: quien lo sepa puede leer los avisos), p. ej.
   `nomadiq-avisos-7f3k9q2m`.
3. En la app, *Subscribe to topic* → ese nombre.
4. En `secrets.env`: `NTFY_URL=https://ntfy.sh/nomadiq-avisos-7f3k9q2m`.

Te llegará un aviso si: un servicio se cae o se reinicia en bucle, falla la
copia nocturna o lleva más de 36 horas sin hacerse, el disco pasa del 85 %,
un certificado va a caducar o un servicio se queda sin memoria.

## Paso 7: Firebase (push)

1. <https://console.firebase.google.com> → crea un proyecto (plan **Spark**).
2. *Configuración del proyecto → Cuentas de servicio → Generar nueva clave
   privada*: descarga el `.json`. **No lo subas a git ni lo pegues en un chat.**
3. El "ID del proyecto" va a `FCM_PROJECT_ID`.

## Paso 8: preparar el servidor

Desde la terminal de VS Code (Terminal → Nueva terminal) en tu ordenador:

```bash
# Entrar al servidor (cambia la ruta de la llave y la IP)
chmod 600 ~/Descargas/ssh-key.key
ssh -i ~/Descargas/ssh-key.key ubuntu@IP_DEL_SERVIDOR
```

> Truco VS Code: instala la extensión **Remote - SSH**. Con ella abres las
> carpetas del servidor como si fueran tuyas (F1 → "Remote-SSH: Connect to
> Host").

Ya dentro del servidor:

```bash
git clone https://github.com/dp2005dario/NoMad-IQ.git
cd NoMad-IQ
sudo bash infrastructure/production/bootstrap.sh
exit   # sal y vuelve a entrar para que se aplique el grupo "docker"
```

Sube el json de Firebase **desde tu ordenador**:

```bash
scp -i ~/Descargas/ssh-key.key ~/Descargas/tu-proyecto-firebase.json ubuntu@IP_DEL_SERVIDOR:fcm.json
```

Y en el servidor:

```bash
sudo mkdir -p /etc/nomadiq && sudo mv ~/fcm.json /etc/nomadiq/fcm.json && sudo chmod 600 /etc/nomadiq/fcm.json
```

## Paso 9: rellenar secretos y configuración

```bash
cd ~/NoMad-IQ/infrastructure/production
cp secrets.env.example secrets.env && chmod 600 secrets.env
cp config.env.example config.env
nano secrets.env     # guardar: Ctrl+O, Enter; salir: Ctrl+X
nano config.env
```

- Los marcados **(auto)** déjalos vacíos: `deploy.sh` los genera.
- `TRAVELPAYOUTS_TOKEN`/`MARKER`: de tu cuenta de Travelpayouts
  (ver `docs/guia-travelpayouts.md`).
- `MAPILLARY_TOKEN` y `TICKETMASTER_API_KEY` son opcionales.
- En `config.env`: `DOMAIN=minomadiq.duckdns.org` y tu correo.

Estos ficheros **solo existen en el servidor**. Git los ignora (`*.env`).

## Paso 10: desplegar

```bash
cd ~/NoMad-IQ
sudo infrastructure/production/deploy.sh
```

La primera vez tarda bastante (construye 8 imágenes en un procesador
pequeño y descarga el modelo de IA): cuenta con una hora o más. Al acabar:

```bash
sudo k3s kubectl -n nomadiq get pods          # todos "Running" (o "Completed")
```

Y en el navegador: `https://minomadiq.duckdns.org/.well-known/jwks.json`
debe enseñar una llave pública (es pública a propósito: sirve para
comprobar las sesiones).

**Guarda `BACKUP_PASSPHRASE`** (ya rellena en `secrets.env`) en tu gestor
de contraseñas. Si el servidor se pierde, sin ella las copias no se pueden
abrir.

## Paso 11: la app apuntando al servidor

En tu ordenador, para la versión de la Play Store:

```bash
cd mobile
flutter build appbundle --release \
  --dart-define=NOMADIQ_API_URL=https://minomadiq.duckdns.org \
  --dart-define=NOMADIQ_FIREBASE_API_KEY=... \
  --dart-define=NOMADIQ_FIREBASE_APP_ID=... \
  --dart-define=NOMADIQ_FIREBASE_SENDER_ID=... \
  --dart-define=NOMADIQ_FIREBASE_PROJECT_ID=...
```

(Los valores de Firebase de la app salen de *Configuración del proyecto →
Tus apps → Android*. Estos sí son públicos: van dentro de la app.)

## Actualizar cuando haya cambios

```bash
cd ~/NoMad-IQ && git pull
sudo infrastructure/production/deploy.sh
```

Los domingos a las 04:00 UTC los servicios se reinician solos (uno a uno)
para soltar memoria acumulada. Los parches de seguridad de Ubuntu se
instalan solos cada día.

## Restaurar una copia

Si se pierde la base de datos (o quieres llevarla a otro servidor):

```bash
# 1. Ver las copias que hay (en el servidor; las variables salen de secrets.env)
cd ~/NoMad-IQ/infrastructure/production
set -a; . ./secrets.env; set +a
export RCLONE_CONFIG_OCI_TYPE=s3 RCLONE_CONFIG_OCI_PROVIDER=Other \
  RCLONE_CONFIG_OCI_ENDPOINT="$BACKUP_S3_ENDPOINT" RCLONE_CONFIG_OCI_REGION="$BACKUP_S3_REGION" \
  RCLONE_CONFIG_OCI_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY" RCLONE_CONFIG_OCI_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY" \
  RCLONE_CONFIG_OCI_FORCE_PATH_STYLE=true \
  RCLONE_CONFIG_SAFE_TYPE=crypt RCLONE_CONFIG_SAFE_REMOTE="oci:$BACKUP_BUCKET/postgres"
docker run --rm -e RCLONE_CONFIG_OCI_TYPE -e RCLONE_CONFIG_OCI_PROVIDER -e RCLONE_CONFIG_OCI_ENDPOINT \
  -e RCLONE_CONFIG_OCI_REGION -e RCLONE_CONFIG_OCI_ACCESS_KEY_ID -e RCLONE_CONFIG_OCI_SECRET_ACCESS_KEY \
  -e RCLONE_CONFIG_OCI_FORCE_PATH_STYLE -e RCLONE_CONFIG_SAFE_TYPE -e RCLONE_CONFIG_SAFE_REMOTE \
  -e BACKUP_PASSPHRASE -v "$PWD/restore:/restore" rclone/rclone:1.68.2 \
  sh -c 'export RCLONE_CONFIG_SAFE_PASSWORD="$(rclone obscure "$BACKUP_PASSPHRASE")"; rclone ls safe: && rclone copy safe: /restore'

# 2. Meter la copia elegida en PostgreSQL (cambia el nombre del fichero)
sudo k3s kubectl -n nomadiq cp restore/nomadiq-AAAAMMDDTHHMMSSZ.dump postgres-0:/tmp/r.dump
sudo k3s kubectl -n nomadiq exec postgres-0 -- sh -c \
  'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore --clean --if-exists -U "$POSTGRES_USER" -d "$POSTGRES_DB" /tmp/r.dump && rm /tmp/r.dump'
rm -rf restore
```

## Qué es seguro y cómo

- **Cifrado en tránsito**: https con TLS 1.3 hacia la app; dentro, cada
  servicio habla con mTLS (PostgreSQL y Redis solo aceptan TLS). Kafka va
  cifrado con TLS y solo pueden llegar a él los servicios marcados (las
  "NetworkPolicies" bloquean al resto).
- **Cifrado en reposo**: los Secrets de Kubernetes se guardan cifrados
  (`--secrets-encryption`); las copias, cifradas con tu contraseña antes
  de salir del servidor.
- **Mínimo privilegio**: ningún contenedor corre como root, todos con disco
  de solo lectura, sin "capabilities" y con la norma "restricted" de
  Kubernetes. Cada servicio solo puede recibir conexiones de quien lo
  necesita.
- **Puertas abiertas**: solo 22 (SSH con llave), 80 (redirige a https) y 443.

## Límites honestos

- **Una sola máquina**: si Oracle la reinicia por mantenimiento, la app
  deja de responder unos minutos. Para un lanzamiento está bien; para
  "millones de usuarios" harían falta varias máquinas de pago. Los mismos
  ficheros de `k8s/` sirven para un clúster grande: solo cambiarían el
  número de réplicas y los tamaños.
- **La IA sin tarjeta gráfica** es lenta (de varios segundos a un minuto
  por respuesta). Por eso hay cupos diarios por usuario y esperas de hasta
  120 s. Si se satura, la app enseña "inténtalo más tarde" en lugar de
  pagar más máquina.
- **Kafka con un solo nodo**: no hay réplica de los mensajes. La base de
  datos sí tiene copia diaria; lo que esté "en tránsito" en Kafka durante
  un fallo del disco se perdería.
