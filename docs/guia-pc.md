# Guía para principiantes: ECLIPTA en tu PC (gratis), para usarlo en tu móvil

El servidor de ECLIPTA corre en **tu propio ordenador con Windows**, y tu
móvil llega a él por **Tailscale**, una red privada gratis entre tus
aparatos. Sin suscripciones, sin servidores de pago y sin tarjeta.

> Analogía: tu PC es la cocina y tu móvil el comedor. Tailscale es un pasillo
> privado entre los dos que solo tú puedes usar: nadie de la calle entra.

## Lo que hay que saber antes

- **Funciona mientras el PC esté encendido** (y sin suspender). Con el PC
  apagado, la app no conecta y no se vigilan los precios de vuelos.
- **Se adapta a tu PC**: con 16 GB de memoria o más se enciende la IA de
  Flyra; con menos, Flyra contesta con respuestas sencillas y todo lo demás
  funciona igual.
- **Por ahora sin avisos push reales** (las alertas de precio llegan a la
  app cuando la abres). Se añaden con Firebase más adelante, también gratis.
- **Las audioguías no se graban en audio** en esta versión (el texto sí).
- Necesitas unos **30 GB libres** en el disco.

## Paso 1: Docker Desktop

1. Descárgalo de <https://www.docker.com/products/docker-desktop/> e
   instálalo (deja marcada la opción **WSL 2**). Puede pedir reiniciar.
2. Ábrelo. Acepta las condiciones (uso personal: gratis). No hace falta
   crear cuenta: puedes pulsar **Skip**.
3. Espera a que abajo a la izquierda ponga **Engine running**.
4. Recomendado: **Settings → General → Start Docker Desktop when you sign
   in** marcado. Así, al encender el PC, ECLIPTA vuelve solo.

## Paso 2: Tailscale en el PC y en el móvil

1. En el PC: descárgalo de <https://tailscale.com/download/windows>,
   instálalo y entra con tu cuenta (por ejemplo, la de Google).
2. En el móvil: instala **Tailscale** de la Play Store y entra con la
   **misma cuenta**. Actívalo (el interruptor de arriba).
3. En el navegador, entra en <https://login.tailscale.com/admin/dns> y
   comprueba que **MagicDNS** está activado y pulsa **Enable HTTPS** (abajo,
   en "HTTPS Certificates"). Es para tener el candado https.

## Paso 3: descargar ECLIPTA

En <https://github.com/dp2005dario/NoMad-IQ>: botón verde **Code →
Download ZIP**. Descomprímelo en una carpeta corta, por ejemplo
`C:\ECLIPTA` (las rutas largas de Windows a veces dan problemas).

(Si tienes Git: `git clone https://github.com/dp2005dario/NoMad-IQ.git C:\ECLIPTA`.)

Todo lo que vas a usar está en la carpeta `C:\ECLIPTA\infrastructure\pc`.

## Paso 4: tus claves

En `infrastructure\pc`, doble clic en **PONER-CLAVE.cmd**. Te enseña la
lista; escribe el nombre, pulsa Enter y pega la clave (**no se ve mientras la
pegas**, es normal). Hazlo dos veces:

- `TRAVELPAYOUTS_TOKEN`
- `TRAVELPAYOUTS_MARKER`

Opcional: `TICKETMASTER_API_KEY` (conciertos en Eventos).

Se guardan en `infrastructure\.env`, en tu PC. Ese fichero nunca se sube a
GitHub y las claves nunca pasan por ningún chat.

Si Windows avisa de que el archivo "podría dañar el equipo" (SmartScreen):
**Más información → Ejecutar de todas formas**. Son nuestros scripts.

## Paso 5: arrancar

Doble clic en **ARRANCAR.cmd**.

- **Si tu PC tiene menos de 20 GB**, la primera vez te dirá que ha dejado a
  Docker usar más memoria y que **reinicies Docker Desktop** (icono de la
  ballena, abajo a la derecha → *Quit Docker Desktop*; espera 10 segundos y
  ábrelo). Después, doble clic otra vez en ARRANCAR.cmd.
- **La primera vez tarda 30-60 minutos**: construye las 8 piezas de ECLIPTA.
  Las siguientes veces, un par de minutos.
- Al final sale **"Tu dirección de ECLIPTA: https://tu-pc.xxxx.ts.net"**.
  Apúntala (también queda en `infrastructure\pc\direccion.txt`).

**Comprobar desde el móvil** (con Tailscale encendido): abre en el navegador
`https://tu-pc.xxxx.ts.net/.well-known/jwks.json`. Si sale un texto con
"keys", **el servidor funciona**.

## Paso 6: la app

La app necesita saber tu dirección. Se pone al compilarla:

```
flutter build apk --release --dart-define=NOMADIQ_API_URL=https://tu-pc.xxxx.ts.net
```

Este paso lo hacemos juntos cuando llegue el momento.

## El día a día

| Quiero... | Haz |
|---|---|
| Usar la app | PC encendido + Tailscale encendido en el móvil |
| Ver si va bien | doble clic en **ESTADO.cmd** |
| Liberar memoria del PC | doble clic en **PARAR.cmd** (tus datos se quedan) |
| Volver a encenderlo | doble clic en **ARRANCAR.cmd** |
| Cambiar una clave | **PONER-CLAVE.cmd** y luego **ARRANCAR.cmd** |
| Actualizar ECLIPTA | descarga el ZIP nuevo encima (o `git pull`) y **ARRANCAR.cmd** |

Para que no se corte mientras lo usas: **Configuración → Sistema →
Inicio/apagado y suspensión** → con el cargador, "Suspender: Nunca".

## Seguridad

- Los puertos de ECLIPTA solo escuchan en tu PC (`127.0.0.1`): ni tu wifi
  ni internet llegan a ellos. Solo tus aparatos dentro de tu Tailscale.
- El tráfico entre el móvil y el PC va cifrado dos veces (Tailscale y https).
- Las contraseñas internas se inventan solas al azar la primera vez.

## Si algo va mal

- **"Docker Desktop no está encendido"**: ábrelo y espera a "Engine running".
- **"Falta Tailscale"**: instálalo (paso 2) y entra con tu cuenta.
- **"Tailscale no ha podido abrir la puerta"**: haz el paso 2.3 (Enable HTTPS).
- **Algo no arrancó**: ESTADO.cmd te dice qué pieza falla. Mándame una
  captura (sin claves) y lo vemos.
