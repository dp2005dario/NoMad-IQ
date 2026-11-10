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

Usamos **Azure for Students**: 100 $ de crédito, sin tarjeta, y **nunca te
cobran**: si se acaba el crédito, la máquina se para y ya está.

ECLIPTA es solo para ti por ahora, así que el servidor está pensado para
gastar poco:

- **Máquina Standard_B2as_v2** (2 núcleos, 8 GB): es la más pequeña en la
  que cabe todo el servidor. Unos **0,07-0,08 € por hora encendida** (el
  script te dice el precio exacto de hoy antes de crearla).
- **Se apaga sola cada noche** (a las 23:00 en invierno). Apagada no gasta la
  máquina, solo el disco y la IP: unos **8 € al mes**.
- **Alerta de gasto**: te llega un correo al gastar el 50 %, 90 % y 100 % de
  15 al mes.

| Cómo la uses | Coste aproximado al mes | Los 100 $ duran |
|---|---|---|
| Encendida solo cuando la usas (~2 h al día) | ~13 € | unos 7 meses |
| Encendida de día (~8 h al día) | ~26 € | unos 3-4 meses |
| Siempre encendida (APAGAR=no) | ~63 € | algo más de 1 mes |

(Cifras orientativas con el precio de Europa Occidental; las de verdad las
da el script.)

**Encenderla** cuando quieras usar la app: portal → máquina **eclipta** →
**Iniciar** (o la app **Azure** del móvil, o en la Cloud Shell
`az vm start -g eclipta-rg -n eclipta`). Tarda unos 5 minutos en estar
lista. **Apagarla** a mano: **Detener** (sale "Desasignada": ya no gasta).

Mientras está apagada, la app no conecta y no se vigilan los precios de
vuelos: es lo que se ahorra.

En 8 GB **no cabe la IA local** (Ollama): Flyra contesta con respuestas
sencillas y todo lo demás funciona igual.

Puedes cambiar las opciones al crear el servidor, poniéndolas delante de
`bash` (por ejemplo `APAGAR=0000 AVISO_EUR=10 bash ...`):
`APAGAR` (hora UTC, o `no`), `AVISO_EUR` (presupuesto del mes),
`REGION` y `SIZE`.

## Paso 1: la suscripción

1. Entra en <https://portal.azure.com>.
2. En "Welcome to Azure" elige **Azure for Students → Start** y confirma tu
   correo de estudiante.
3. Sigue los pasos hasta que en el portal, arriba, al buscar
   **Subscriptions** te salga una con estado **Active**.

## Paso 2: abrir la consola del navegador (Cloud Shell)

1. Arriba a la derecha del portal, pulsa el icono **>_**.
2. Elige **Bash**.
3. Si pregunta por almacenamiento, elige **No se requiere cuenta de
   almacenamiento** (o "Montar" si te deja). Las cuentas de estudiante a
   veces no dejan crearla en la región que propone: no pasa nada, el script
   se apaña sin ella.

Se abre una terminal abajo. Ahí vas a pegar órdenes: clic derecho → Pegar
(o Ctrl+Shift+V).

## Paso 3: crear el servidor (una orden)

Pega esto y pulsa Enter:

```bash
git clone https://github.com/dp2005dario/NoMad-IQ.git
APAGAR=no AVISO_EUR=70 bash NoMad-IQ/infrastructure/azure/crear-servidor.sh
```

(`APAGAR=no` la deja siempre encendida, para que otros puedan usar la app;
`AVISO_EUR=70` te avisa por correo al acercarte a 70 € en un mes. Si es solo
para ti, quita las dos cosas y se apagará cada noche para ahorrar.)

Tarda **15-25 minutos** y va poniendo puntos mientras espera. Deja la
pestaña abierta (la Cloud Shell se cierra tras 20 minutos sin que toques
nada: si ves que lleva rato, pulsa una flecha del teclado de vez en cuando).
Si se cortara, vuelve a pegar las dos órdenes: sigue donde iba (si la
primera dice que la carpeta ya existe, no pasa nada). El script:

1. Activa los servicios de Azure que hacen falta.
2. Crea el grupo **eclipta-rg** (todo va dentro: si algún día quieres
   borrarlo todo, se borra ese grupo).
3. Crea el almacén privado para las copias.
4. Crea la máquina Ubuntu y abre solo las puertas 22, 80 y 443.
5. Espera a que la máquina se prepare sola (cortafuegos, Docker, Kubernetes).
6. Rellena en la máquina todo lo que se sabe solo: el dominio, tu correo,
   las copias y el tema de avisos.

Al final te enseña la **dirección de tu servidor**. Apúntala.

El script mira solo qué **regiones** deja usar tu suscripción (las de
estudiante tienen una lista cerrada) y elige la más cercana a España que
tenga la máquina. Si dice que no encuentra ninguna, mándame una captura.

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
