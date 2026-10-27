package com.nomadiq.authgateway.auth;

import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtException;
import org.springframework.security.oauth2.jwt.JwtValidators;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.stereotype.Component;

import com.nomadiq.authgateway.auth.AuthExceptions.GoogleNotConfiguredException;
import com.nomadiq.authgateway.auth.AuthExceptions.InvalidCredentialsException;

/**
 * Comprueba el "id_token" que la app recibe de Google al pulsar "Continuar con
 * Google". Un id_token es un JWT firmado por Google. Comprobamos:
 * <ol>
 *   <li>la firma, con las claves públicas de Google (JWKS);</li>
 *   <li>que lo emitió Google (iss) y que no ha caducado (exp);</li>
 *   <li>que va dirigido a NUESTRA app (aud = GOOGLE_CLIENT_ID): sin esto,
 *       cualquier token de Google de otra app valdría;</li>
 *   <li>que el email está verificado por Google.</li>
 * </ol>
 * Sin GOOGLE_CLIENT_ID configurado el servicio responde 503 (no hay forma
 * segura de validar), nunca acepta el token a ciegas.
 */
@Component
public class GoogleIdTokenVerifier {

    private static final Logger log = LoggerFactory.getLogger(GoogleIdTokenVerifier.class);
    static final String JWKS_URI = "https://www.googleapis.com/oauth2/v3/certs";
    static final List<String> ISSUERS = List.of("https://accounts.google.com", "accounts.google.com");

    /** Lo que nos interesa del token ya validado. */
    public record GoogleIdentity(String sub, String email, String pictureUrl) {
    }

    private final String clientId;
    private final JwtDecoder decoder;

    @org.springframework.beans.factory.annotation.Autowired
    public GoogleIdTokenVerifier(@Value("${GOOGLE_CLIENT_ID:}") String clientId) {
        this(clientId, clientId == null || clientId.isBlank() ? null : buildDecoder(clientId.trim()));
    }

    /** Para los tests: se les pasa un decodificador con claves propias. */
    GoogleIdTokenVerifier(String clientId, JwtDecoder decoder) {
        this.clientId = clientId == null ? "" : clientId.trim();
        this.decoder = decoder;
    }

    public boolean isConfigured() {
        return !clientId.isEmpty() && decoder != null;
    }

    public GoogleIdentity verify(String idToken) {
        if (!isConfigured()) {
            throw new GoogleNotConfiguredException();
        }
        Jwt jwt;
        try {
            jwt = decoder.decode(idToken);
        } catch (JwtException e) {
            log.info("id_token de Google rechazado: {}", e.getMessage());
            throw new InvalidCredentialsException();
        }
        String email = jwt.getClaimAsString("email");
        if (email == null || !Boolean.TRUE.equals(jwt.getClaim("email_verified")) || jwt.getSubject() == null) {
            log.info("id_token de Google sin email verificado");
            throw new InvalidCredentialsException();
        }
        return new GoogleIdentity(jwt.getSubject(), email, jwt.getClaimAsString("picture"));
    }

    static JwtDecoder buildDecoder(String clientId) {
        NimbusJwtDecoder decoder = NimbusJwtDecoder.withJwkSetUri(JWKS_URI).build();
        decoder.setJwtValidator(validator(clientId));
        return decoder;
    }

    /** Fecha de caducidad + emisor de Google + destinatario = nuestro client id. */
    static OAuth2TokenValidator<Jwt> validator(String clientId) {
        OAuth2TokenValidator<Jwt> issuer = jwt -> ISSUERS.contains(jwt.getClaimAsString("iss"))
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(new OAuth2Error("invalid_token", "emisor no es Google", null));
        OAuth2TokenValidator<Jwt> audience = jwt -> jwt.getAudience() != null && jwt.getAudience().contains(clientId)
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(new OAuth2Error("invalid_token", "audiencia incorrecta", null));
        return new org.springframework.security.oauth2.core.DelegatingOAuth2TokenValidator<>(
                JwtValidators.createDefault(), issuer, audience);
    }
}
