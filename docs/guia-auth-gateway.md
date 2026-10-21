# Guía del auth-gateway: la puerta de seguridad, explicada desde cero

Esta guía está escrita para alguien que **no sabe nada** de seguridad ni de
Java. Si es tu primera vez con el proyecto, lee antes
[`guia-principiantes.md`](guia-principiantes.md). Aquí nos centramos en el
servicio que decide **quién eres** y **qué puedes hacer**. Ve por orden: cada
sección se apoya en la anterior.

---

## 0. La idea con una analogía (sin tecnicismos)

Imagina un **festival de música** con varios escenarios (los microservicios):

1. **La taquilla** (`/v1/auth/register` y `/v1/auth/login`): enseñas tu DNI
   (email + contraseña) y te ponen una **pulsera** (el *token de acceso*, un
   JWT). La pulsera lleva impreso tu número de cliente y si eres VIP (tus
   *roles*), y un **sello holográfico** imposible de falsificar (la *firma*).
2. La pulsera **caduca a los 15 minutos**. Así, si te la roban, al ladrón le
   dura poco.
3. Para no hacer cola cada 15 minutos, también te dan un **resguardo**
   (el *token de refresco*). Con él vas a un mostrador rápido
   (`/v1/auth/refresh`) y te cambian la pulsera caducada por una nueva... **y
   el resguardo por otro nuevo**: el viejo se rompe. Si alguien aparece con un
   resguardo ya roto, el mostrador sabe que hay una copia robada y **anula
   todos los resguardos de esa persona**.
4. **Los porteros de cada escenario** (el proxy de borde y los microservicios)
   no llaman a la taquilla para comprobar cada pulsera: miran el sello
   holográfico con su **lupa** (la *clave pública*). Es instantáneo. La lupa
   la reparte la taquilla a quien la pida (`/.well-known/jwks.json`), porque
   sirve para *comprobar* sellos, no para *fabricarlos*. La máquina de hacer
   sellos (la *clave privada*) solo la tiene la taquilla.
5. Hay una **lista negra** en una pizarra (Redis): "la pulsera nº 1234 ya no
   vale" (alguien cerró sesión) o "todas las pulseras de Fulano anteriores a
   las 22:00 ya no valen" (le hemos expulsado). Mirar la pizarra es un vistazo
   de menos de un milisegundo.
6. En la taquilla hay un **portero con contador**: si alguien intenta entrar
   20 veces en un minuto, o falla la contraseña 5 veces seguidas, le dice
   "espera un rato" (*rate limiting*). Así nadie puede probar millones de
   contraseñas.
7. Y lo más importante (*Zero Trust*): **aunque estés dentro del recinto**, cada
   puerta interna te vuelve a pedir la acreditación de personal (*mTLS*). Colarse
   por la valla no sirve de nada.

Eso es el auth-gateway. El resto de la guía explica cómo se hace cada cosa.

---

## 1. Glosario para principiantes

| Palabra | Qué significa, en sencillo |
|---|---|
| **Autenticación** | Demostrar *quién eres* (login). |
| **Autorización** | Decidir *qué puedes hacer* (¿eres ADMIN?). |
| **Token** | Un "papelito" que demuestra que ya te identificaste, para no repetir la contraseña en cada petición. |
| **JWT (JSON Web Token)** | Un token con formato estándar: `cabecera.datos.firma`, en Base64. Los datos se pueden **leer** (no van cifrados), pero no **modificar** sin romper la firma. |
| **Claim** | Cada dato dentro del JWT: `sub` (quién), `exp` (caducidad), `roles`... |
| **Firma digital** | Un sello matemático. Si cambias una sola letra del token, la firma deja de cuadrar. |
| **Clave privada / pública** | Pareja de claves: la privada **firma** (secreta, solo la tiene el gateway); la pública **comprueba** (se puede repartir). |
| **ES256** | El algoritmo de firma que usamos: curvas elípticas P-256 + SHA-256. Firmas pequeñas y verificación muy rápida. |
| **HS256** | Algoritmo con UNA sola clave que firma y comprueba. Lo evitamos: todo el que comprueba podría también falsificar. |
| **JWKS** | "JSON Web Key Set": la lista de claves públicas en formato estándar, publicada en una URL. |
| **kid** | "Key ID": la etiqueta de cada clave, para saber con cuál se firmó un token. |
| **Rotación de claves** | Cambiar la clave de firma periódicamente sin que nadie pierda la sesión. |
| **Access token** | El JWT de vida corta (15 min) que se envía en cada petición: `Authorization: Bearer <token>`. |
| **Refresh token** | Token de vida larga (30 días) que solo sirve para pedir access tokens nuevos. De un solo uso. |
| **Revocación** | Anular un token antes de que caduque. |
| **Stateless (sin estado)** | El servidor no guarda "quién está conectado": cada petición trae todo lo necesario. Permite tener 1 o 100 copias del servicio sin coordinarlas. |
| **Hash** | La "huella dactilar" de un dato: siempre la misma para el mismo dato, e imposible volver atrás desde la huella. |
| **Argon2id** | Algoritmo de hash **lento a propósito** para contraseñas: a un atacante le cuesta muchísimo probar millones. |
| **Rate limiting** | Limitar cuántas peticiones puede hacer alguien por unidad de tiempo. |
| **RBAC** | Control de acceso por roles: los permisos se dan a roles (USER, ADMIN), y los roles a personas. |
| **TLS / mTLS** | Cifrado de la conexión. En mTLS, **los dos lados** enseñan certificado. |
| **Zero Trust** | "Nunca confíes, verifica siempre": estar dentro de la red no da permisos. |
| **Proxy de borde / API Gateway** | El primer servidor que recibe el tráfico de internet y lo reparte a los servicios internos. |
| **Forward auth** | El proxy de borde pregunta al auth-gateway "¿vale este token?" antes de dejar pasar cada petición. |
| **Spring Boot** | El framework de Java más usado en empresas: monta el servidor web, la seguridad, la base de datos... con muy poco código. |
| **Maven** | La herramienta que descarga librerías y compila Java (como `go build` + `go mod`). |
| **Bean** | Un objeto que Spring crea una vez y reparte a quien lo necesite. |
| **Flyway** | Aplica los cambios de la base de datos (migraciones SQL) en orden, una sola vez cada uno. |
| **Testcontainers** | Librería que arranca PostgreSQL y Redis reales en Docker solo durante los tests. |
| **Problem Details (RFC 9457)** | Formato JSON estándar para los errores de una API. |

---

## 2. El viaje de una sesión, paso a paso

```
 1. Registro      POST /v1/auth/register {email, password}
                  → valida → Argon2id(contraseña) → INSERT identity.users → 201

 2. Login         POST /v1/auth/login {email, password}
                  → ¿esta IP ha hecho > 20 logins este minuto?          (Redis)
                  → ¿esta cuenta acumula ≥ 5 fallos?                    (Redis)
                  → Argon2id compara la contraseña                      (PostgreSQL)
                  → firma JWT ES256 (15 min) + refresh token aleatorio  (PostgreSQL guarda su SHA-256)
                  → 200 {access_token, refresh_token, expires_in...}

 3. Cada petición GET /v1/... con "Authorization: Bearer <jwt>"
                  → ¿typ = at+jwt? ¿alg = ES256? ¿firma correcta?       (memoria, ~0,1 ms)
                  → ¿iss, aud, exp correctos?                           (memoria)
                  → ¿está en la lista negra?                            (Redis, 1 consulta)

 4. A los 15 min  POST /v1/auth/refresh {refresh_token}
                  → bloquea la fila del token (FOR UPDATE)
                  → ¿usado ya? → ¡ROBO! revoca la familia entera → 401
                  → marca usado, emite pareja nueva → 200

 5. Logout        POST /v1/auth/logout {refresh_token}  (con el access token)
                  → jti del access token a la lista negra hasta su caducidad
                  → revoca la familia del refresh token → 204
```

---

## 3. Los riesgos que señaló Gemini y qué hemos hecho con cada uno

| Riesgo | Solución aplicada | Dónde está |
|---|---|---|
| **1. Cuello de botella**: validar cada token consultando una base de datos. | Validación **sin estado** con clave asimétrica ES256: la firma se comprueba en memoria. Lo único externo es UNA lectura a Redis (`MGET`), de menos de 1 ms. Además, hilos virtuales de Java 21: miles de peticiones esperando no agotan el servidor. | `token/JwtConfig.java`, `application.yaml` |
| **2. Revocación**: un JWT robado vale hasta que caduca. | Access tokens de **15 min** + refresh tokens de **un solo uso** con detección de reutilización. **Lista negra en Redis** con dos tipos de entrada: por token (`jti`, logout) y por usuario ("todo lo anterior a T", baneo). Caducan solas, así la lista nunca crece. Si Redis cae, se rechaza (fallo cerrado). | `token/RevocationStore.java`, `token/RefreshTokenService.java` |
| **3. Gestión de claves**: HS256 obliga a repartir el secreto; rotar mal tumba sesiones. | **ES256**: la privada solo la tiene el gateway. **JWKS** público en `/.well-known/jwks.json` con la clave activa + las antiguas en rotación; el `kid` se calcula solo (huella RFC 7638). Rotar = añadir clave nueva, dejar la vieja como "solo verificar" 15 min, retirarla. | `keys/SigningKeys.java`, `keys/JwksController.java` |
| **4. Romper Zero Trust tras la pasarela.** | El gateway valida y entrega `X-User-ID` / `X-User-Roles` al proxy de borde (`/v1/auth/verify`), y **la red interna sigue exigiendo mTLS**: el propio gateway exige certificado de cliente con TLS 1.3 y se niega a arrancar sin él (salvo en local, pidiéndolo explícitamente). | `api/AuthController.java`, `config/TlsConfig.java`, `config/AuthProperties.java` |
| **5. Fuerza bruta y abuso.** | Rate limiting en **Redis** (compartido por todas las copias del gateway) con un script Lua atómico: por IP en login, registro y refresco, y **por cuenta** tras 5 fallos (frena ataques distribuidos desde miles de IP). Respuesta 429 con `Retry-After`. | `ratelimit/RateLimiter.java`, `auth/AuthService.java` |

Además, cosas que no estaban en la lista pero que un comité de seguridad preguntaría:

- **Ataques clásicos a JWT bloqueados y probados**: `alg: none`, confusión HS256,
  firma con otra clave, otro `typ`, otra audiencia u otro emisor, token sin `exp`
  (`JwtValidationTest.java`).
- **No revelar qué emails existen**: mismo mensaje y mismo tiempo de respuesta
  (siempre se calcula un Argon2, aunque el email no exista).
- **Nada sensible en el token ni en los logs**: el JWT solo lleva un UUID y los
  roles; las contraseñas y tokens nunca se imprimen (`toString()` ocultos).
- **Errores sin pistas**: formato estándar RFC 9457, sin trazas internas.

---

## 4. Fichero a fichero

### `services/auth-gateway/`

| Fichero | Qué hace |
|---|---|
| `pom.xml` | Receta de Maven: Spring Boot 4.1, Java 21, librerías y tipos de test. |
| `mvnw`, `mvnw.cmd`, `.mvn/` | El "wrapper": descarga Maven solo. Usa `./mvnw` (Mac/Linux) o `mvnw.cmd` (Windows). |
| `Dockerfile` | Imagen en dos etapas; la final es *distroless* (sin shell) y sin root. |
| `src/main/resources/application.yaml` | Traduce variables de entorno a configuración. Sin secretos. |
| `src/main/resources/db/migration/V1__...sql` | Tablas `users` y `refresh_tokens` en el esquema `identity`. |
| `AuthGatewayApplication.java` | Punto de arranque. |
| `HealthProbe.java` | Chequeo de salud para Docker (la imagen no tiene curl). |
| `config/AuthProperties.java` | Configuración tipada. **Se niega a arrancar si algo es inseguro** y lista todos los errores a la vez. |
| `config/SecurityConfig.java` | Qué rutas son públicas, cuáles piden token y cuáles ADMIN. Argon2id. |
| `config/TlsConfig.java` | mTLS con TLS 1.3. |
| `config/DataSourceConfig.java` | Pool de conexiones a PostgreSQL con TLS verificado. |
| `keys/SigningKeys.java` | Lee las claves PEM, calcula la pública y el `kid`, prepara el JWKS. |
| `keys/JwksController.java` | Publica `/.well-known/jwks.json`. |
| `token/AccessTokenIssuer.java` | Fabrica y firma los JWT. |
| `token/JwtConfig.java` | Cómo se validan: algoritmo fijo, tipo, emisor, audiencia, fechas, lista negra. |
| `token/RevocationStore.java` + `RevocationValidator.java` | La lista negra en Redis y su comprobación. |
| `token/RefreshTokenService.java` + `RefreshTokenRepository.java` | Refresh tokens: emisión, rotación, detección de robo, revocación. |
| `ratelimit/RateLimiter.java` | Contadores atómicos en Redis. |
| `auth/AuthService.java` | La lógica: registro, login, refresco, logout, baneo, política de contraseñas. |
| `user/*` | El usuario, sus roles y su tabla. |
| `api/*` | Las rutas HTTP, los JSON de entrada/salida y la traducción de errores. |

### Tests

| Fichero | Qué comprueba |
|---|---|
| `AuthPropertiesTest` | Que las configuraciones inseguras se rechazan. |
| `SigningKeysTest` | Carga de claves, `kid` estable, rotación, que nunca se publica la parte privada, otras curvas rechazadas. |
| `JwtValidationTest` | Los ataques clásicos contra JWT, caducidad, revocación y fallo cerrado si Redis cae. |
| `PasswordPolicyTest` | Política de contraseñas y normalización de emails. |
| `AuthGatewayIT` | El servicio entero contra PostgreSQL y Redis reales: flujo completo, robo de refresh token, bloqueo por fallos, límite por IP, baneo por un ADMIN, JWKS y salud. |

### Cambios fuera del servicio

- `infrastructure/docker-compose.yml`: nuevo servicio `auth-gateway` (perfil `apps`), solo lectura, sin privilegios.
- `.github/workflows/ci.yml`: job `auth-gateway (Java)` con `./mvnw verify` y prueba de registro + login en el contenedor durante la integración.
- `Makefile`: `make test-java`.
- `.vscode/`: extensiones de Java y Spring Boot.

---

## 5. Trabajar con el proyecto desde Visual Studio Code

### Instalar lo necesario (una sola vez)

1. **Java 21 (JDK)**: descarga "Temurin 21 (LTS)" de <https://adoptium.net> e
   instálalo con las opciones por defecto. En Windows, marca la casilla
   *"Set JAVA_HOME variable"*. Para comprobarlo, abre una terminal y escribe
   `java -version`: debe decir `21`.
2. **Maven NO hace falta**: el proyecto trae `mvnw`, que lo descarga solo.
3. **Docker Desktop** (ya lo tienes si seguiste la guía de principiantes):
   necesario para los tests de integración y para `make up-apps`.
4. **Extensiones de VS Code**: al abrir la carpeta del proyecto, VS Code te
   ofrecerá (abajo a la derecha) instalar las extensiones recomendadas. Pulsa
   **"Instalar todas"**. Para Java son:
   - *Extension Pack for Java* (Microsoft): autocompletado, errores al
     escribir, ejecutar tests JUnit y depurador.
   - *Spring Boot Extension Pack* (VMware): autocompletado del
     `application.yaml` y un panel para arrancar la app.

### Abrir el proyecto

- `Archivo → Abrir carpeta...` y elige la carpeta **raíz** `NoMad-IQ` (no la
  del servicio): así VS Code ve también los servicios Go.
- La primera vez, la extensión de Java tarda 1-2 minutos en "importar el
  proyecto Maven" (verás una ruedita abajo con *"Java: Importing..."*).
  Espera a que termine. Si te pregunta *"Do you trust the authors?"*, di que sí
  (es tu propio código).
- En la barra lateral aparece **"JAVA PROJECTS"**: ahí ves los paquetes
  (`config`, `keys`, `token`...) como carpetas.

### La terminal integrada

`Ver → Terminal` (o `Ctrl + ñ` / `Ctrl + ``). Para trabajar con el servicio:

```bash
cd services/auth-gateway
./mvnw test        # Windows (PowerShell): .\mvnw.cmd test
./mvnw verify      # + tests de integración (Docker Desktop debe estar abierto)
```

### Ejecutar tests sin escribir comandos

Abre un fichero de test (por ejemplo `JwtValidationTest.java`). Encima de cada
método `@Test` aparece **"Run Test | Debug Test"**: haz clic. También puedes
usar el icono del **matraz** (Testing) de la barra lateral para ver todos los
tests en árbol y lanzarlos con ▶. Verde = pasa, rojo = falla.

### Depurar (ver el programa "a cámara lenta")

1. Haz clic a la izquierda del número de línea (sale un punto rojo: un
   *breakpoint*), por ejemplo dentro de `AuthService.login`.
2. En el test `AuthGatewayIT`, pulsa **"Debug Test"** encima de
   `flujoCompletoRegistroLoginRefrescoYLogout`.
3. El programa se parará en tu punto rojo. A la izquierda verás el valor de
   cada variable. Con **F10** avanzas línea a línea; con **F5** continúas.

### Consejos

- **Ctrl + clic** sobre un nombre (clase o método) te lleva a donde está definido.
- **F2** sobre un nombre lo renombra en todo el proyecto sin romper nada.
- Si VS Code se lía tras cambiar el `pom.xml`: `Ctrl + Shift + P` →
  *"Java: Clean Java Language Server Workspace"*.
- Los avisos del compilador son errores (`-Werror`): si algo sale subrayado en
  amarillo, arréglalo antes de subirlo o la CI fallará.

---

## 6. Probarlo tú mismo

```bash
# 1. Arranca todo (infraestructura + microservicios, incluido el auth-gateway)
make up-apps

# 2. ¿Está sano?
curl http://127.0.0.1:8084/readyz            # {"status":"UP"}

# 3. Crea una cuenta
curl -X POST http://127.0.0.1:8083/v1/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"email":"dario@example.com","password":"caballo correcto grapa pila"}'

# 4. Inicia sesión y copia el "access_token" de la respuesta
curl -X POST http://127.0.0.1:8083/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"dario@example.com","password":"caballo correcto grapa pila"}'

# 5. Úsalo
curl http://127.0.0.1:8083/v1/me -H 'Authorization: Bearer PEGA_AQUI_EL_TOKEN'

# 6. Mira qué lleva dentro: pega el token en https://jwt.io (es un token
#    local de pruebas, no lo hagas nunca con uno de producción).
#    Verás "alg": "ES256", "typ": "at+jwt", tu "sub" y "roles": ["USER"].

# 7. Las claves públicas
curl http://127.0.0.1:8083/.well-known/jwks.json

# 8. Prueba el rate limiting: falla la contraseña 6 veces seguidas y verás
#    un 429 "Demasiados intentos".
```

En Windows con PowerShell, `curl` es otra cosa: usa **Git Bash** (viene con
Git) o la extensión *REST Client* de VS Code.

**Convertirte en ADMIN** (solo en local), para probar el baneo. Abre la
consola de PostgreSQL:

```bash
cd infrastructure
docker compose exec postgres sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

y dentro escribe (el `;` final es obligatorio), y luego `\q` para salir:

```sql
UPDATE identity.users SET roles = ARRAY['USER','ADMIN'] WHERE email = 'dario@example.com';
```

Vuelve a hacer login para recibir un token con el rol nuevo. No hay una ruta
de la API para hacerse ADMIN a propósito: si existiera, sería el primer sitio
que atacaría alguien.

---

## 7. Cómo contarlo en una entrevista (30 segundos)

> "El auth-gateway es un servicio Spring Boot 4 con Java 21 que emite JWT
> firmados con ES256 y publica sus claves en un JWKS, así cualquier servicio
> valida tokens localmente sin llamar a nadie: no es un cuello de botella. Los
> access tokens duran 15 minutos y los refresh tokens son opacos, de un solo
> uso y con detección de reutilización por familias, al estilo de OAuth 2.1.
> Para revocar al instante uso una lista negra en Redis con TTL y claves con
> hash tags compatibles con Redis Cluster, con fallo cerrado. El rate
> limiting es atómico con Lua, por IP y por cuenta. Contraseñas con Argon2id
> con parámetros de OWASP. Y es Zero Trust: mTLS con TLS 1.3 obligatorio,
> PostgreSQL verify-full, y el servicio se niega a arrancar con una
> configuración insegura. Todo probado con Testcontainers contra Postgres y
> Redis reales, incluidos los ataques clásicos a JWT."

Preguntas que te pueden hacer y su respuesta corta:

- *¿Por qué no Keycloak?* Coste cero y control total: es un portfolio y el
  alcance es pequeño. En una empresa grande valoraría Keycloak/Auth0, y como
  publicamos JWKS estándar, migrar sería transparente para los demás servicios.
- *¿Por qué consultar Redis si el JWT es "sin estado"?* Es el compromiso para
  poder revocar: una lectura en memoria de < 1 ms por petición frente a una
  base de datos. Sin Redis, la revocación tardaría hasta 15 minutos.
- *¿Por qué refresh tokens opacos y no JWT?* Porque hay que poder revocarlos y
  marcarlos como usados: necesitan estado igualmente, así que mejor un valor
  aleatorio que no expone datos.

---

## 8. Lo que NO está hecho todavía (siguientes pasos)

Está hecho a propósito sin sobreingeniería. Esto queda pendiente, por orden de prioridad:

1. **Proxy de borde real** (Envoy o Traefik en docker-compose) usando
   `/v1/auth/verify`, que además **borre** cualquier `X-User-*` que venga del
   cliente antes de añadir las nuestras.
2. **mTLS en local**: script que genere una CA de desarrollo y certificados
   para cada servicio, para que docker-compose funcione sin `*_INSECURE_DEV`.
3. **Gestión de secretos en producción**: montar la clave de firma desde un
   gestor (Kubernetes Secrets con cifrado, Vault o SOPS), nunca en la imagen.
   Automatizar la rotación (p. ej. cada 90 días).
4. **Verificación de email** y **recuperación de contraseña** (con tokens de un
   solo uso). Con verificación, el registro podría responder igual exista o no
   el email (hoy un 409 revela que existe).
5. **Usuario de base de datos propio** para el auth-gateway con permisos solo
   sobre el esquema `identity` (hoy comparte el usuario de desarrollo).
6. **Limpieza periódica** de refresh tokens caducados y **caducidad absoluta**
   de la sesión (hoy cada rotación la alarga 30 días más).
7. **Periodo de gracia** de unos segundos en la rotación: si la app móvil
   envía dos refrescos simultáneos por un fallo de red, hoy se interpreta como
   robo y se cierra la sesión.
8. **Contraseñas filtradas**: comprobar contra Have I Been Pwned (k-anonimato).
9. **Login social** (Google/Apple) y **passkeys / WebAuthn**, y el enlace con
   la biometría del móvil para la bóveda de documentos.
10. **Que los demás servicios validen el JWT** ellos mismos con el JWKS
    (defensa en profundidad extra) y propaguen la identidad por gRPC.
11. **Observabilidad**: métricas de logins fallidos, 429 y reutilización de
    tokens, con alertas.
