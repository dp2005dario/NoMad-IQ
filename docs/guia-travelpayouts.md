# Guía: precios reales de vuelos y comisiones con Travelpayouts

Esta guía explica, para principiantes, cómo ECLIPTA consigue precios de
vuelos **reales** y cómo **ganas dinero** cuando alguien reserva desde la app.

---

## 0. La idea con una analogía

Imagina que tienes una tienda de viajes pequeñita. No vendes billetes tú:
cuando un cliente quiere uno, le das una tarjeta con tu sello para que vaya
a una agencia grande. Si compra allí con tu tarjeta, la agencia te da una
parte de lo que gana. Eso es el **marketing de afiliados**:

| En la analogía | En ECLIPTA |
|---|---|
| La agencia grande | Aviasales (un buscador de vuelos) |
| El programa de "tarjetas con sello" | Travelpayouts (la red de afiliados de Aviasales) |
| Tu sello | El **marker**: tu número de afiliado, que va en cada enlace |
| La lista de precios que te pasa la agencia | La **Data API** (gratis): precios que otros viajeros encontraron hace poco |
| La llave para pedir esa lista | El **token** de la API (secreto) |

**Cuánto se gana (aproximado):** en vuelos, alrededor de un 1–1,5 % del
billete. La comisión se confirma cuando la persona viaja (1–2 meses después).

---

## 1. Registrarte (una vez, gratis)

1. Entra en <https://www.travelpayouts.com> y crea una cuenta.
2. Cuando te pregunte por tu proyecto, di que es una **app móvil de viajes**
   (ECLIPTA) y pon el enlace del repositorio o de la Play Store cuando exista.
3. Únete al programa **Aviasales** (vuelos). Más adelante se pueden añadir
   hoteles, seguros o eSIM, que pagan más.
4. Busca en tu panel estos dos datos (los menús pueden cambiar de nombre):
   - **Marker / ID de socio:** un número, por ejemplo `123456`.
   - **Token de la API:** una cadena larga de letras y números (suele estar
     en la sección de herramientas o API de tu perfil).

> El token es como la contraseña de tu cuenta de afiliado: **nunca** lo
> pegues en un chat, en GitHub ni en el código.

---

## 2. Activarlo en tu ordenador (Visual Studio Code)

1. Abre VS Code → **Archivo → Abrir carpeta…** → `ECLIPTA`.
2. Abre el archivo `infrastructure/.env` (si no existe, copia
   `infrastructure/.env.example` con el nombre `.env`). Ese archivo **no se
   sube a GitHub** (está en `.gitignore`).
3. Añade al final:

   ```bash
   FARE_PROVIDER=travelpayouts
   TRAVELPAYOUTS_TOKEN=pega-aquí-tu-token
   TRAVELPAYOUTS_MARKER=tu-número-de-socio
   TRAVELPAYOUTS_CURRENCY=EUR
   ```

4. Reinicia los servicios en la terminal de VS Code (**Terminal → Nuevo
   terminal**):

   ```bash
   make up-apps
   ```

5. Comprueba que el flight-ingestor usa el proveedor real:

   ```bash
   docker compose -f infrastructure/docker-compose.yml logs flight-ingestor | grep proveedor
   ```

   Debe decir `"provider":"travelpayouts"`.

Si te equivocas con el token verás en el log `token rechazado (HTTP 401)`.
Si falta el marker, el servicio no arranca y te lo dice (sin marker no
cobrarías comisiones).

En producción (Kubernetes) el token irá en un *secret* montado como
fichero (`TRAVELPAYOUTS_TOKEN_FILE`), no como variable.

---

## 3. Cómo funciona por dentro

```
rutas vigiladas ──► flight-ingestor ──(cada ruta, máx. 1 vez / 30 min)──► Data API
                         │                                   precios de ese día
                         ▼
          el más barato + enlace https://www.aviasales.com/search/...&marker=TU_ID
                         │
                         ▼
          Kafka flights.price-observed.v1 ──► price-consumer ──► alertas y app
```

- **Ritmo controlado:** como mucho 2 peticiones por segundo entre todas las
  rutas (un "cubo de fichas"). Si hay muchas rutas, esperan su turno.
- **Sin repetir:** cada ruta se pregunta como mucho cada 30 minutos; la
  Data API se actualiza cada pocas horas, preguntar más es tirar peticiones.
- **Solo turista:** la Data API no tiene business ni primera; esas rutas se
  quedan sin precio (mejor nada que un precio de otra cabina).
- **Enlaces seguros:** solo se aceptan enlaces que apuntan a Aviasales por
  https, y siempre llevan tu marker.
- **El token nunca sale:** viaja en una cabecera (`X-Access-Token`), no en
  la dirección web, para que no aparezca en ningún log.

Código: `services/flight-ingestor/internal/provider/travelpayouts.go`.
Tests (con una API falsa, sin internet): `travelpayouts_test.go`.

---

## 4. Glosario

- **Afiliado:** quien recomienda un producto y cobra una comisión si se vende.
- **Marker:** tu identificador de afiliado dentro de cada enlace.
- **Token de API:** la llave secreta para pedir datos a la API.
- **Data API:** precios "de caché": los que encontraron otros viajeros
  recientemente. Gratis, pero no en vivo.
- **Cubo de fichas (rate limiter):** cada petición gasta una ficha y las
  fichas se reponen a ritmo fijo; si no hay, se espera.
