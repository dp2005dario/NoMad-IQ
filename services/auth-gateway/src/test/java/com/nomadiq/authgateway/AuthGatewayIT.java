package com.nomadiq.authgateway;

import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.data.redis.core.RedisCallback;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;
import tools.jackson.databind.json.JsonMapper;

/**
 * Test de integración: arranca el servicio COMPLETO contra un PostgreSQL y un
 * Redis reales (en contenedores Docker que Testcontainers crea y destruye) y
 * lo usa por HTTP, igual que lo haría la app móvil.
 *
 * <p>Necesita Docker. Se ejecuta con {@code ./mvnw verify} (no con {@code test}).
 */
@Testcontainers
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT, properties = "management.server.port=0")
class AuthGatewayIT {

    private static final String REDIS_PASSWORD = "test-redis-" + UUID.randomUUID();
    private static final String PASSWORD = "caballo correcto grapa pila";

    @Container
    static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:17-alpine");

    @Container
    static final GenericContainer<?> REDIS = new GenericContainer<>("redis:7.4-alpine")
            .withCommand("redis-server", "--requirepass", REDIS_PASSWORD)
            .withExposedPorts(6379);

    /** Configura el servicio para hablar con los contenedores (en modo desarrollo, sin TLS). */
    @DynamicPropertySource
    static void properties(DynamicPropertyRegistry r) {
        r.add("nomadiq.database.host", POSTGRES::getHost);
        r.add("nomadiq.database.port", () -> POSTGRES.getMappedPort(5432));
        r.add("nomadiq.database.user", POSTGRES::getUsername);
        r.add("nomadiq.database.password", POSTGRES::getPassword);
        r.add("nomadiq.database.name", POSTGRES::getDatabaseName);
        r.add("nomadiq.database.ssl-mode", () -> "disable");
        r.add("nomadiq.database.insecure-dev", () -> "true");
        r.add("spring.data.redis.host", REDIS::getHost);
        r.add("spring.data.redis.port", () -> REDIS.getMappedPort(6379));
        r.add("spring.data.redis.password", () -> REDIS_PASSWORD);
        r.add("spring.data.redis.ssl.enabled", () -> "false");
        r.add("nomadiq.redis.tls", () -> "false");
        r.add("nomadiq.redis.insecure-dev", () -> "true");
        r.add("nomadiq.http.insecure-dev", () -> "true");
        r.add("nomadiq.jwt.dev-ephemeral-key", () -> "true");
        r.add("nomadiq.rate-limits.login-per-ip", () -> "30/1m");
        r.add("nomadiq.rate-limits.register-per-ip", () -> "1000/1m");
        r.add("nomadiq.rate-limits.refresh-per-ip", () -> "1000/1m");
        r.add("nomadiq.rate-limits.login-failures-per-account", () -> "5/15m");
    }

    @LocalServerPort
    int port;

    @LocalManagementPort
    int managementPort;

    @Autowired
    StringRedisTemplate redis;

    @Autowired
    JdbcClient jdbc;

    private final HttpClient http = HttpClient.newHttpClient();
    private final JsonMapper json = JsonMapper.builder().build();

    /** Cada test empieza con los contadores y la lista negra vacíos. */
    @BeforeEach
    void cleanRedis() {
        redis.execute((RedisCallback<Void>) c -> {
            c.serverCommands().flushAll();
            return null;
        });
    }

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------

    @Test
    void flujoCompletoRegistroLoginRefrescoYLogout() throws Exception {
        String email = newEmail();
        Resp reg = post("/v1/auth/register", Map.of("email", email.toUpperCase(), "password", PASSWORD), null);
        assertThat(reg.status()).isEqualTo(201);
        assertThat(reg.body()).containsEntry("email", email).containsEntry("roles", List.of("USER"));
        assertThat(reg.raw()).doesNotContain("password");

        Resp login = login(email, PASSWORD);
        assertThat(login.status()).isEqualTo(200);
        assertThat(login.body()).containsEntry("token_type", "Bearer").containsKey("refresh_token");
        assertThat(login.header("cache-control")).contains("no-store");
        String access = (String) login.body().get("access_token");
        String refresh = (String) login.body().get("refresh_token");

        // El token sirve para /me y para el "forward auth" del proxy de borde.
        assertThat(get("/v1/me", access).body()).containsEntry("email", email);
        Resp verify = get("/v1/auth/verify", access);
        assertThat(verify.status()).isEqualTo(204);
        assertThat(verify.header("x-user-id")).isEqualTo(reg.body().get("id"));
        assertThat(verify.header("x-user-roles")).isEqualTo("USER");

        // Rotación: el refresh devuelve una pareja nueva y distinta.
        Resp rotated = post("/v1/auth/refresh", Map.of("refresh_token", refresh), null);
        assertThat(rotated.status()).isEqualTo(200);
        String refresh2 = (String) rotated.body().get("refresh_token");
        String access2 = (String) rotated.body().get("access_token");
        assertThat(refresh2).isNotEqualTo(refresh);

        // Logout: el token de acceso actual queda en la lista negra al instante.
        assertThat(post("/v1/auth/logout", Map.of("refresh_token", refresh2), access2).status()).isEqualTo(204);
        assertThat(get("/v1/me", access2).status()).isEqualTo(401);
        // ...y el refresh de esa sesión ya no sirve.
        assertThat(post("/v1/auth/refresh", Map.of("refresh_token", refresh2), null).status()).isEqualTo(401);
    }

    @Test
    void reutilizarUnRefreshRevocaTodaLaFamilia() throws Exception {
        String email = newEmail();
        register(email);
        String refresh1 = (String) login(email, PASSWORD).body().get("refresh_token");
        String refresh2 = (String) post("/v1/auth/refresh", Map.of("refresh_token", refresh1), null).body().get("refresh_token");

        // Un "ladrón" usa el token viejo: se rechaza...
        assertThat(post("/v1/auth/refresh", Map.of("refresh_token", refresh1), null).status()).isEqualTo(401);
        // ...y también se anula el legítimo de la misma familia (los dos deben volver a entrar).
        assertThat(post("/v1/auth/refresh", Map.of("refresh_token", refresh2), null).status()).isEqualTo(401);
        // Otras sesiones (otro login) no se ven afectadas.
        String otherSession = (String) login(email, PASSWORD).body().get("refresh_token");
        assertThat(post("/v1/auth/refresh", Map.of("refresh_token", otherSession), null).status()).isEqualTo(200);
    }

    @Test
    void bloqueaUnaCuentaTrasVariosFallos() throws Exception {
        String email = newEmail();
        register(email);
        for (int i = 0; i < 5; i++) {
            assertThat(login(email, "contraseña equivocada").status()).isEqualTo(401);
        }
        // Al sexto intento ni siquiera la contraseña correcta vale: hay que esperar.
        Resp blocked = login(email, PASSWORD);
        assertThat(blocked.status()).isEqualTo(429);
        assertThat(Long.parseLong(blocked.header("retry-after"))).isBetween(1L, 15L * 60);
    }

    @Test
    void limitaLoginsPorIp() throws Exception {
        for (int i = 0; i < 30; i++) {
            assertThat(login(newEmail(), PASSWORD).status()).isEqualTo(401);
        }
        assertThat(login(newEmail(), PASSWORD).status()).isEqualTo(429);
    }

    @Test
    void elMismoErrorParaEmailInexistenteYContrasenaMala() throws Exception {
        String email = newEmail();
        register(email);
        Resp wrongPassword = login(email, "contraseña equivocada");
        Resp unknownEmail = login(newEmail(), "contraseña equivocada");
        assertThat(wrongPassword.status()).isEqualTo(unknownEmail.status()).isEqualTo(401);
        assertThat(wrongPassword.body().get("detail")).isEqualTo(unknownEmail.body().get("detail"));
    }

    @Test
    void registroValidaYRechazaDuplicados() throws Exception {
        String email = newEmail();
        assertThat(register(email).status()).isEqualTo(201);
        assertThat(register(email).status()).isEqualTo(409);
        Resp invalid = post("/v1/auth/register", Map.of("email", "no-es-email", "password", "corta"), null);
        assertThat(invalid.status()).isEqualTo(400);
        assertThat(invalid.body()).containsKey("errors");
    }

    @Test
    void soloAdminPuedeBanearYElBaneoExpulsaAlInstante() throws Exception {
        String adminEmail = newEmail();
        register(adminEmail);
        jdbc.sql("UPDATE users SET roles = ARRAY['USER','ADMIN'] WHERE email = :e").param("e", adminEmail).update();
        String adminToken = (String) login(adminEmail, PASSWORD).body().get("access_token");

        String victimEmail = newEmail();
        String victimId = (String) register(victimEmail).body().get("id");
        Resp victimLogin = login(victimEmail, PASSWORD);
        String victimAccess = (String) victimLogin.body().get("access_token");
        String victimRefresh = (String) victimLogin.body().get("refresh_token");

        // Un usuario normal no puede usar rutas de administración (403).
        assertThat(post("/v1/admin/users/" + UUID.randomUUID() + "/disable", null, victimAccess).status()).isEqualTo(403);

        assertThat(post("/v1/admin/users/" + victimId + "/disable", null, adminToken).status()).isEqualTo(204);

        // Token de acceso, refresh y login: todo rechazado desde ya.
        assertThat(get("/v1/me", victimAccess).status()).isEqualTo(401);
        assertThat(post("/v1/auth/refresh", Map.of("refresh_token", victimRefresh), null).status()).isEqualTo(401);
        assertThat(login(victimEmail, PASSWORD).status()).isEqualTo(401);
        // Usuario inexistente: 404.
        assertThat(post("/v1/admin/users/" + UUID.randomUUID() + "/disable", null, adminToken).status()).isEqualTo(404);
    }

    @Test
    void sinTokenOConTokenFalsoNoSeEntra() throws Exception {
        assertThat(get("/v1/me", null).status()).isEqualTo(401);
        assertThat(get("/v1/me", "esto.no.es-un-jwt").status()).isEqualTo(401);
        assertThat(get("/v1/auth/verify", null).status()).isEqualTo(401);
    }

    @Test
    void publicaJwksSinParteSecretaYTieneSalud() throws Exception {
        Resp jwks = get("/.well-known/jwks.json", null);
        assertThat(jwks.status()).isEqualTo(200);
        assertThat(jwks.raw()).contains("\"kty\":\"EC\"").contains("\"crv\":\"P-256\"").doesNotContain("\"d\"");

        HttpResponse<String> ready = http.send(HttpRequest.newBuilder(
                URI.create("http://127.0.0.1:" + managementPort + "/readyz")).build(), HttpResponse.BodyHandlers.ofString());
        assertThat(ready.statusCode()).isEqualTo(200);
    }

    // ------------------------------------------------------------------
    // Ayudantes HTTP
    // ------------------------------------------------------------------

    /** Respuesta simplificada: código, cabeceras y cuerpo JSON. */
    record Resp(int status, HttpResponse<String> response, Map<String, Object> body, String raw) {
        String header(String name) {
            return response.headers().firstValue(name).orElse(null);
        }
    }

    private static String newEmail() {
        return "viajero-" + UUID.randomUUID() + "@example.com";
    }

    private Resp register(String email) throws Exception {
        return post("/v1/auth/register", Map.of("email", email, "password", PASSWORD), null);
    }

    private Resp login(String email, String password) throws Exception {
        return post("/v1/auth/login", Map.of("email", email, "password", password), null);
    }

    private Resp post(String path, Map<String, ?> body, String bearer) throws Exception {
        HttpRequest.Builder b = request(path, bearer).header("Content-Type", "application/json")
                .POST(body == null ? HttpRequest.BodyPublishers.noBody()
                        : HttpRequest.BodyPublishers.ofString(json.writeValueAsString(body)));
        return send(b);
    }

    private Resp get(String path, String bearer) throws Exception {
        return send(request(path, bearer).GET());
    }

    private HttpRequest.Builder request(String path, String bearer) {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + path));
        if (bearer != null) {
            b.header("Authorization", "Bearer " + bearer);
        }
        return b;
    }

    @SuppressWarnings("unchecked")
    private Resp send(HttpRequest.Builder b) throws Exception {
        HttpResponse<String> r = http.send(b.build(), HttpResponse.BodyHandlers.ofString());
        Map<String, Object> body = r.body().isBlank() ? Map.of() : json.readValue(r.body(), Map.class);
        return new Resp(r.statusCode(), r, body, r.body());
    }
}
