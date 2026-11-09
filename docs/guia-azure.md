# Guía para principiantes: poner ECLIPTA en Azure

Esta guía pone el servidor de ECLIPTA en **Microsoft Azure**, paso a paso y
sin instalar nada en tu ordenador: todo se hace desde el navegador. Es la
misma instalación que la de Oracle (`docs/guia-produccion.md`), pero con
dos scripts que hacen casi todo solos.

> Analogía: Azure nos alquila un local (la máquina). Un script lo monta
> (paredes, cerradura, alarma) y tú solo tienes que dejar las llaves de
> tus proveedores (las claves de Travelpayouts...) en la caja fuerte del
> propio local. Las llaves nunca pasan por un chat.

## Lo que vas a tener al final

- Un servidor encendido 24 horas en `https://eclipta-xxxxxx.westeurope.cloudapp.azure.com`
  (el nombre lo da Azure gratis; no hace falta DuckDNS).
- El candado https (Let's Encrypt), que se renueva solo.
- Copias de seguridad de la base de datos cada noche, **cifradas** con tu
  contraseña antes de salir del servidor, guardadas en Azure (14 días).
- Avisos al móvil (app **ntfy**) si algo se cae.

## Cuánto cuesta (léelo antes)

| Cuenta | Qué te da | Riesgo de cobro |
|---|---|---|
| **Azure for Students** | 100 $ de crédito, sin tarjeta, 12 meses | Ninguno: si se acaba el crédito, se para |
| **Azure free trial** | 200 $ de crédito durante 30 días, con tarjeta | Ninguno mientras NO pases a "pago por uso" |

La máquina por defecto (**Standard_B2as_v2**: 2 núcleos y 8 GB) cuesta
aproximadamente **60-70 $ al mes** encendida todo el día (precio orientativo:
compruébalo en <https://azure.microsoft.com/pricing/calculator/>). Con 100 $
llega para algo más de un mes; con 200 $, para los 30 días de la prueba.

Para que dure más: cuando no la uses, en el portal → máquina **eclipta** →
**Detener**. Detenida (“Desasignada”) no gasta la máquina, solo unos
céntimos de disco. Al **Iniciar**, todo vuelve solo (tarda unos minutos).

En 8 GB **no cabe la IA local** (Ollama): Flyra contesta con respuestas
sencillas y todo lo demás funciona igual. Con `SIZE=Standard_B4as_v2`
(16 GB) se enciende la IA, pero cuesta el doble.

## Paso 1: la suscripción

1. Entra en <https://portal.azure.com>.
2. En "Welcome to Azure" elige **Azure for Students → Start** (si tienes
   correo de estudiante) o **Azure free trial → Start**.
3. Sigue los pasos hasta que en el portal, arriba, al buscar
   **Subscriptions** te salga una con estado **Active**.

## Paso 2: abrir la consola del navegador (Cloud Shell)

1. Arriba a la derecha del portal, pulsa el icono **>_**.
2. Elige **Bash**.
3. Si pregunta por almacenamiento, elige **Montar una cuenta de
   almacenamiento** y deja que la cree (cuesta céntimos). Así la llave para
   entrar al servidor no se pierde cuando cierras la consola.

Se abre una terminal abajo. Ahí vas a pegar órdenes: clic derecho → Pegar
(o Ctrl+Shift+V).

## Paso 3: crear el servidor (una orden)

Pega esto y pulsa Enter:

```bash
git clone https://github.com/dp2005dario/NoMad-IQ.git
bash NoMad-IQ/infrastructure/azure/crear-servidor.sh
```

Tarda **15-25 minutos** y va poniendo puntos mientras espera. Deja la
pestaña abierta (la Cloud Shell se cierra tras 20 minutos sin que toques
nada: si ves que lleva rato, pulsa una flecha del teclado de vez en cuando).
Si se cortara, vuelve a pegar la segunda orden: sigue donde iba. El script:

1. Activa los servicios de Azure que hacen falta.
2. Crea el grupo **eclipta-rg** (todo va dentro: si algún día quieres
   borrarlo todo, se borra ese grupo).
3. Crea el almacén privado para las copias.
4. Crea la máquina Ubuntu y abre solo las puertas 22, 80 y 443.
5. Espera a que la máquina se prepare sola (cortafuegos, Docker, Kubernetes).
6. Rellena en la máquina todo lo que se sabe solo: el dominio, tu correo,
   las copias y el tema de avisos.

Al final te enseña la **dirección de tu servidor**. Apúntala.

Si sale **"Azure no ha dejado crear la máquina"**: en esa región no hay ese
tamaño para tu cuenta. Borra lo creado y prueba otra región:

```bash
az group delete -n eclipta-rg --yes
REGION=northeurope bash NoMad-IQ/infrastructure/azure/crear-servidor.sh
```

## Paso 4: poner tus claves (sin que pasen por ningún chat)

En la misma Cloud Shell, entra al servidor (cambia la dirección por la tuya):

```bash
ssh azureuser@eclipta-xxxxxx.westeurope.cloudapp.azure.com
cd ~/NoMad-IQ
```

Ahora pon cada clave con `poner-clave.sh`. Te pide que la pegues y **no se
ve mientras la pegas** (es normal, como una contraseña):

```bash
sudo infrastructure/production/poner-clave.sh TRAVELPAYOUTS_TOKEN
sudo infrastructure/production/poner-clave.sh TRAVELPAYOUTS_MARKER
```

Opcionales (si no las pones, esa función se apaga sola):

```bash
sudo infrastructure/production/poner-clave.sh TICKETMASTER_API_KEY   # conciertos en Eventos
sudo infrastructure/production/poner-clave.sh MAPILLARY_TOKEN        # hoy no se usa en la app
```

Dónde está cada una: `que-hago-yo/claves-estado.md` en los archivos del
proyecto. Si te equivocas, vuelve a ejecutar la misma orden: la cambia.

## Paso 5: desplegar

Todavía dentro del servidor:

```bash
sudo nohup infrastructure/production/deploy.sh > ~/deploy.log 2>&1 &
tail -f ~/deploy.log
```

La primera vez tarda **una hora o más** (construye las 8 piezas de ECLIPTA
en la propia máquina). Con `nohup` sigue aunque se cierre la Cloud Shell:
`tail -f` solo te deja mirar cómo va (Ctrl+C deja de mirar, no lo para).
Cuando la última línea diga **"Desplegado."**, ha terminado. Entonces:

```bash
sudo k3s kubectl -n nomadiq get pods     # todos "Running" o "Completed"
```

Y en el navegador: `https://TU-DIRECCION/.well-known/jwks.json` debe enseñar
una llave pública. Si sale, **el servidor funciona**.

Dos cosas importantes al terminar:

- **Guarda la contraseña de las copias** en tu gestor de contraseñas. La ves
  con: `sudo grep BACKUP_PASSPHRASE infrastructure/production/secrets.env`.
  Sin ella, las copias no se pueden abrir.
- **Avisos al móvil**: instala la app **ntfy**, pulsa "+" y suscríbete al
  tema que sale con: `sudo grep NTFY_URL infrastructure/production/secrets.env`
  (lo que va después de `https://ntfy.sh/`).

## Paso 6: la app apuntando a tu servidor

La app de tu móvil tiene que saber la dirección del servidor. Se pone al
compilarla (en tu ordenador, en la carpeta `mobile`):

```bash
flutter build apk --release --dart-define=NOMADIQ_API_URL=https://TU-DIRECCION
```

Eso lo preparamos juntos cuando llegue el momento de probar en tu móvil.

## Avisos push (Firebase), más adelante

El servidor funciona sin Firebase: solo no llegan avisos al móvil (alertas
de precio, etc.). Cuando lo tengas (ver `docs/guia-fcm-real.md`), sube el
`.json` de la cuenta de servicio a la máquina como `/etc/nomadiq/fcm.json`,
pon `FCM_PROJECT_ID` con `poner-clave.sh` y vuelve a ejecutar `deploy.sh`.

## Actualizar cuando haya cambios

```bash
ssh azureuser@TU-DIRECCION
cd ~/NoMad-IQ && git pull
sudo nohup infrastructure/production/deploy.sh > ~/deploy.log 2>&1 &
tail -f ~/deploy.log
```

## Si algo va mal

- **No puedo entrar por SSH** (la Cloud Shell perdió la llave): en el portal
  → máquina **eclipta** → **Ayuda → Restablecer contraseña** → modo "Restablecer
  clave SSH" y pega una nueva, o usa **Conectar → Consola serie**.
- **La máquina se preparó mal**: mira el registro con
  `sudo tail -n 60 /var/log/cloud-init-output.log`.
- **Ver qué falla en ECLIPTA**: `sudo k3s kubectl -n nomadiq get pods` y, del
  que no esté "Running", `sudo k3s kubectl -n nomadiq logs NOMBRE`.
- **Borrarlo todo** (deja de gastar del todo): en la Cloud Shell,
  `az group delete -n eclipta-rg --yes`.

Lo de seguridad (cifrado, mTLS, cortafuegos, copias) es igual que en Oracle:
ver las secciones "Qué es seguro y cómo" y "Restaurar una copia" de
`docs/guia-produccion.md` (en Azure, restaurar usa `BACKUP_PROVIDER=azure`:
pídemelo y te preparo la orden exacta).
