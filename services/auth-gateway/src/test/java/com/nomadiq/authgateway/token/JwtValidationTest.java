package com.nomadiq.authgateway.token;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.Date;
import java.util.List;
import java.util.UUID;

import com.nimbusds.jose.JOSEObjectType;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.PlainHeader;
import com.nimbusds.jose.crypto.ECDSASigner;
import com.nimbusds.jose.crypto.MACSigner;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.PlainJWT;
import com.nimbusds.jwt.SignedJWT;
import com.nomadiq.authgateway.config.AuthProperties;
import com.nomadiq.authgateway.config.RateLimitPolicy;
import com.nomadiq.authgateway.keys.SigningKeys;
import com.nomadiq.authgateway.user.Role;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.RedisConnectionFailureException;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;

/**
 * Emisión y validación de tokens, sin servidor ni Redis reales.
 *
 * <p>Cada test intenta "colar" un token falso de una forma distinta (los
 * ataques clásicos contra JWT) y comprueba que el decoder lo rechaza.
 */
class JwtValidationTest {

    private static final String ISSUER = "https://auth.nomadiq.app";
    private static final String AUDIENCE = "nomadiq-api";

    private SigningKeys keys;
    private RevocationStore revocations;
    private JwtDecoder decoder;
    private final UUID userId = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        keys = SigningKeys.ephemeral();
        revocations = mock(RevocationStore.class);
        decoder = new JwtConfig().jwtDecoder(keys, props(), revocations);
    }

    static AuthProperties props() {
        RateLimitPolicy p = RateLimitPolicy.parse("10/1m");
        return new AuthProperties(
                new AuthProperties.Http("", "", "", true),
                new AuthProperties.Database("localhost", 5432, "u", "p", "d", "disable", "", 5, true),
                new AuthProperties.Redis(false, true),
                new AuthProperties.Jwt(ISSUER, AUDIENCE, Duration.ofMinutes(15), Duration.ofDays(30), "", List.of(), true),
                new AuthProperties.RateLimits(p, p, p, p));
    }

    private AccessTokenIssuer issuerWithClock(Clock clock) {
        return new AccessTokenIssuer(new JwtConfig().jwtEncoder(keys), keys, props(), clock);
    }

    /** Fabrica un token "a mano" con la clave que queramos, para simular ataques. */
    private String forge(JWSHeader header, JWTClaimsSet claims, com.nimbusds.jose.JWSSigner signer) throws Exception {
        SignedJWT jwt = new SignedJWT(header, claims);
        jwt.sign(signer);
        return jwt.serialize();
    }

    private JWTClaimsSet.Builder validClaims() {
        Instant now = Instant.now();
        return new JWTClaimsSet.Builder()
                .issuer(ISSUER).audience(AUDIENCE).subject(userId.toString())
                .issueTime(Date.from(now)).notBeforeTime(Date.from(now)).expirationTime(Date.from(now.plusSeconds(600)))
                .jwtID(UUID.randomUUID().toString()).claim("roles", List.of("USER"));
    }

    private JWSHeader.Builder es256Header() {
        return new JWSHeader.Builder(JWSAlgorithm.ES256).type(new JOSEObjectType("at+jwt")).keyID(keys.activeKey().getKeyID());
    }

    @Test
    void tokenEmitidoSeValidaYLlevaLoNecesario() {
        AccessTokenIssuer.IssuedAccessToken issued = issuerWithClock(Clock.systemUTC()).issue(userId, List.of(Role.USER, Role.ADMIN));

        Jwt jwt = decoder.decode(issued.value());

        assertThat(jwt.getSubject()).isEqualTo(userId.toString());
        assertThat(jwt.getClaimAsStringList("roles")).containsExactly("USER", "ADMIN");
        assertThat(jwt.getAudience()).containsExactly(AUDIENCE);
        assertThat(jwt.getId()).isEqualTo(issued.tokenId());
        assertThat(jwt.getHeaders()).containsEntry("typ", "at+jwt").containsEntry("alg", "ES256");
        assertThat(Duration.between(jwt.getIssuedAt(), jwt.getExpiresAt())).isEqualTo(Duration.ofMinutes(15));
    }

    @Test
    void rechazaTokenCaducado() {
        Clock haceUnaHora = Clock.fixed(Instant.now().minus(Duration.ofHours(1)), ZoneOffset.UTC);
        String token = issuerWithClock(haceUnaHora).issue(userId, List.of(Role.USER)).value();
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test
    void rechazaAlgNone() {
        // Ataque clásico: token sin firma que dice "alg: none".
        String token = new PlainJWT(new PlainHeader.Builder().type(new JOSEObjectType("at+jwt")).build(), validClaims().build()).serialize();
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test
    void rechazaHs256ConfusionDeAlgoritmo() throws Exception {
        // Ataque de "confusión de algoritmo": firmar con HS256 usando un secreto inventado.
        byte[] secret = new byte[32];
        String token = forge(new JWSHeader.Builder(JWSAlgorithm.HS256).type(new JOSEObjectType("at+jwt")).build(),
                validClaims().build(), new MACSigner(secret));
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test
    void rechazaFirmaDeOtraClave() throws Exception {
        SigningKeys attacker = SigningKeys.ephemeral();
        String token = forge(new JWSHeader.Builder(JWSAlgorithm.ES256).type(new JOSEObjectType("at+jwt"))
                .keyID(keys.activeKey().getKeyID()).build(), validClaims().build(), new ECDSASigner(attacker.activeKey()));
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test
    void rechazaOtroTipoDeToken() throws Exception {
        String token = forge(new JWSHeader.Builder(JWSAlgorithm.ES256).type(JOSEObjectType.JWT).keyID(keys.activeKey().getKeyID()).build(),
                validClaims().build(), new ECDSASigner(keys.activeKey()));
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test
    void rechazaAudienciaOEmisorAjenos() throws Exception {
        String otherAud = forge(es256Header().build(), validClaims().audience("otra-app").build(), new ECDSASigner(keys.activeKey()));
        String otherIss = forge(es256Header().build(), validClaims().issuer("https://malo.example").build(), new ECDSASigner(keys.activeKey()));
        assertThatThrownBy(() -> decoder.decode(otherAud)).isInstanceOf(JwtException.class);
        assertThatThrownBy(() -> decoder.decode(otherIss)).isInstanceOf(JwtException.class);
    }

    @Test
    void rechazaTokenSinCaducidad() throws Exception {
        String token = forge(es256Header().build(), validClaims().expirationTime(null).build(), new ECDSASigner(keys.activeKey()));
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }

    @Test
    void rechazaTokenRevocado() {
        when(revocations.isRevoked(any(), any(), any())).thenReturn(true);
        String token = issuerWithClock(Clock.systemUTC()).issue(userId, List.of(Role.USER)).value();
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class).hasMessageContaining("revocado");
    }

    @Test
    void siRedisCaeSeRechaza() {
        // Fallo cerrado: sin poder mirar la lista negra, no se deja pasar a nadie.
        when(revocations.isRevoked(any(), any(), any())).thenThrow(new RedisConnectionFailureException("caído"));
        String token = issuerWithClock(Clock.systemUTC()).issue(userId, List.of(Role.USER)).value();
        assertThatThrownBy(() -> decoder.decode(token)).isInstanceOf(JwtException.class);
    }
}
