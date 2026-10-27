package com.nomadiq.authgateway.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.RSAPublicKey;
import java.time.Instant;
import java.util.Date;

import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.JWSHeader;
import com.nimbusds.jose.crypto.RSASSASigner;
import com.nimbusds.jwt.JWTClaimsSet;
import com.nimbusds.jwt.SignedJWT;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;

import com.nomadiq.authgateway.auth.AuthExceptions.GoogleNotConfiguredException;
import com.nomadiq.authgateway.auth.AuthExceptions.InvalidCredentialsException;

/**
 * Prueba la validación del id_token de Google SIN internet: firmamos los
 * tokens con una clave propia y se la damos al verificador en lugar de las
 * claves de Google.
 */
class GoogleIdTokenVerifierTest {

    private static final String CLIENT = "mi-app.apps.googleusercontent.com";
    private static KeyPair keys;

    @BeforeAll
    static void makeKeys() throws Exception {
        KeyPairGenerator g = KeyPairGenerator.getInstance("RSA");
        g.initialize(2048);
        keys = g.generateKeyPair();
    }

    private static GoogleIdTokenVerifier verifier() {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withPublicKey((RSAPublicKey) keys.getPublic()).build();
        decoder.setJwtValidator(GoogleIdTokenVerifier.validator(CLIENT));
        return new GoogleIdTokenVerifier(CLIENT, decoder);
    }

    private static String token(String iss, String aud, Object emailVerified, long expiresInSeconds) throws Exception {
        JWTClaimsSet.Builder c = new JWTClaimsSet.Builder()
                .issuer(iss).audience(aud).subject("1234567890")
                .claim("email", "ana@example.com").claim("picture", "https://lh3.googleusercontent.com/a/x")
                .issueTime(Date.from(Instant.now().minusSeconds(10)))
                .expirationTime(Date.from(Instant.now().plusSeconds(expiresInSeconds)));
        if (emailVerified != null) {
            c.claim("email_verified", emailVerified);
        }
        SignedJWT jwt = new SignedJWT(new JWSHeader(JWSAlgorithm.RS256), c.build());
        jwt.sign(new RSASSASigner(keys.getPrivate()));
        return jwt.serialize();
    }

    @Test
    void aceptaUnTokenCorrecto() throws Exception {
        var who = verifier().verify(token("https://accounts.google.com", CLIENT, true, 600));
        assertThat(who.sub()).isEqualTo("1234567890");
        assertThat(who.email()).isEqualTo("ana@example.com");
        assertThat(who.pictureUrl()).startsWith("https://");
    }

    @Test
    void rechazaOtraAudienciaOtroEmisorCaducadoYEmailSinVerificar() throws Exception {
        GoogleIdTokenVerifier v = verifier();
        assertThatThrownBy(() -> v.verify(token("https://accounts.google.com", "otra-app", true, 600)))
                .isInstanceOf(InvalidCredentialsException.class);
        assertThatThrownBy(() -> v.verify(token("https://evil.example", CLIENT, true, 600)))
                .isInstanceOf(InvalidCredentialsException.class);
        assertThatThrownBy(() -> v.verify(token("https://accounts.google.com", CLIENT, true, -3600)))
                .isInstanceOf(InvalidCredentialsException.class);
        assertThatThrownBy(() -> v.verify(token("https://accounts.google.com", CLIENT, false, 600)))
                .isInstanceOf(InvalidCredentialsException.class);
        assertThatThrownBy(() -> v.verify(token("https://accounts.google.com", CLIENT, null, 600)))
                .isInstanceOf(InvalidCredentialsException.class);
        assertThatThrownBy(() -> v.verify("esto-no-es-un-jwt")).isInstanceOf(InvalidCredentialsException.class);
    }

    @Test
    void sinClientIdNoAceptaNada() {
        GoogleIdTokenVerifier off = new GoogleIdTokenVerifier("");
        assertThat(off.isConfigured()).isFalse();
        assertThatThrownBy(() -> off.verify("lo-que-sea")).isInstanceOf(GoogleNotConfiguredException.class);
    }
}
