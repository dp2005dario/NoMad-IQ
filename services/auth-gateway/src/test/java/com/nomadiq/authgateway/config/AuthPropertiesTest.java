package com.nomadiq.authgateway.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.time.Duration;
import java.util.List;

import org.junit.jupiter.api.Test;

/**
 * Comprueba la regla "si la configuración es insegura, no se arranca".
 * Cada test monta una configuración y mira si se acepta o qué error da.
 */
class AuthPropertiesTest {

    /** Configuración de producción correcta: todo con TLS y clave en fichero. */
    static AuthProperties secure() {
        return build(new AuthProperties.Http("/tls/cert.pem", "/tls/key.pem", "/tls/ca.pem", false),
                new AuthProperties.Database("db", 5432, "auth", "secreto", "nomadiq", "verify-full", "", 10, false),
                new AuthProperties.Redis(true, false),
                jwt("/keys/jwt.pem", false));
    }

    static AuthProperties.Jwt jwt(String keyFile, boolean ephemeral) {
        return new AuthProperties.Jwt("https://auth.nomadiq.app", "nomadiq-api", Duration.ofMinutes(15),
                Duration.ofDays(30), keyFile, List.of(), ephemeral);
    }

    static AuthProperties build(AuthProperties.Http http, AuthProperties.Database db, AuthProperties.Redis redis,
                                AuthProperties.Jwt jwt) {
        RateLimitPolicy p = RateLimitPolicy.parse("10/1m");
        return new AuthProperties(http, db, redis, jwt, new AuthProperties.RateLimits(p, p, p, p));
    }

    @Test
    void aceptaConfiguracionSegura() {
        assertThatCode(AuthPropertiesTest::secure).doesNotThrowAnyException();
    }

    @Test
    void aceptaModoDesarrolloExplicito() {
        assertThatCode(() -> build(new AuthProperties.Http("", "", "", true),
                new AuthProperties.Database("localhost", 5432, "u", "p", "d", "disable", "", 5, true),
                new AuthProperties.Redis(false, true),
                jwt("", true))).doesNotThrowAnyException();
    }

    @Test
    void rechazaTodoLoInseguroYLoDiceTodoDeUnaVez() {
        assertThatThrownBy(() -> build(new AuthProperties.Http("", "", "", false),
                new AuthProperties.Database("db", 5432, "u", "p", "d", "require", "", 10, false),
                new AuthProperties.Redis(false, false),
                jwt("", true)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("HTTP sin TLS")
                .hasMessageContaining("PGSSLMODE=require")
                .hasMessageContaining("Redis sin TLS")
                .hasMessageContaining("JWT_DEV_EPHEMERAL_KEY");
    }

    @Test
    void mtlsExigeLosTresFicheros() {
        assertThatThrownBy(() -> build(new AuthProperties.Http("/cert.pem", "/key.pem", "", false),
                secure().database(), secure().redis(), secure().jwt()))
                .hasMessageContaining("TLS_CLIENT_CA_FILE");
    }

    @Test
    void exigeUnaSolaFuenteDeClaveJwt() {
        assertThatThrownBy(() -> build(secure().http(), secure().database(), secure().redis(), jwt("", false)))
                .hasMessageContaining("JWT_ACTIVE_KEY_FILE");
        assertThatThrownBy(() -> build(new AuthProperties.Http("", "", "", true), secure().database(), secure().redis(),
                jwt("/keys/jwt.pem", true)))
                .hasMessageContaining("JWT_ACTIVE_KEY_FILE");
    }

    @Test
    void rechazaDuracionesAbsurdas() {
        AuthProperties.Jwt longAccess = new AuthProperties.Jwt("iss", "aud", Duration.ofHours(5), Duration.ofDays(1),
                "/k.pem", List.of(), false);
        assertThatThrownBy(() -> build(secure().http(), secure().database(), secure().redis(), longAccess))
                .hasMessageContaining("ACCESS_TOKEN_TTL");
    }

    @Test
    void limpiaListaDeClavesAntiguas() {
        AuthProperties.Jwt j = new AuthProperties.Jwt("iss", "aud", Duration.ofMinutes(15), Duration.ofDays(1),
                "/k.pem", List.of(" /old.pub.pem ", ""), false);
        assertThat(j.verifyOnlyKeyFiles()).containsExactly("/old.pub.pem");
    }

    @Test
    void parseaLimitesDeVelocidad() {
        assertThat(RateLimitPolicy.parse("5/15m")).isEqualTo(new RateLimitPolicy(5, Duration.ofMinutes(15)));
        assertThat(RateLimitPolicy.parse(" 100 / 1h ")).isEqualTo(new RateLimitPolicy(100, Duration.ofHours(1)));
        assertThatThrownBy(() -> RateLimitPolicy.parse("10 por minuto")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> RateLimitPolicy.parse("0/1m")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> RateLimitPolicy.parse("1/48h")).isInstanceOf(IllegalArgumentException.class);
    }
}
