package com.nomadiq.authgateway.token;

import java.time.Duration;
import java.util.List;
import java.util.Set;

import com.nimbusds.jose.JOSEObjectType;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.source.ImmutableJWKSet;
import com.nimbusds.jose.proc.DefaultJOSEObjectTypeVerifier;
import com.nimbusds.jose.proc.JWSVerificationKeySelector;
import com.nimbusds.jose.proc.SecurityContext;
import com.nimbusds.jwt.proc.DefaultJWTProcessor;
import com.nomadiq.authgateway.config.AuthProperties;
import com.nomadiq.authgateway.keys.SigningKeys;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2ErrorCodes;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.security.oauth2.jwt.JwtDecoder;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtIssuerValidator;
import org.springframework.security.oauth2.jwt.JwtTimestampValidator;
import org.springframework.security.oauth2.jwt.JwtTypeValidator;
import org.springframework.security.oauth2.jwt.NimbusJwtDecoder;
import org.springframework.security.oauth2.jwt.NimbusJwtEncoder;

/**
 * Cómo se firman (encoder) y cómo se comprueban (decoder) los JWT.
 *
 * <p>La comprobación es <b>local y sin estado</b>: la firma se verifica con las
 * claves públicas que ya tenemos en memoria, sin llamar a ninguna base de datos
 * ni a ningún proveedor externo. Esto es lo que evita que el gateway sea un
 * cuello de botella. Lo único que se consulta fuera es la lista negra de Redis
 * (una lectura en memoria de menos de 1 ms).
 *
 * <p>Comprobaciones, en orden:
 * <ol>
 *   <li>cabecera {@code typ = at+jwt} (que sea un token de acceso);</li>
 *   <li>algoritmo fijado a ES256: se rechazan {@code alg: none}, HS256 y
 *       cualquier otro (el famoso ataque de "confusión de algoritmo");</li>
 *   <li>firma válida con una de nuestras claves (por su {@code kid});</li>
 *   <li>{@code exp}/{@code nbf} (con 60 s de tolerancia de reloj) e {@code iss};</li>
 *   <li>{@code aud} contiene nuestra audiencia;</li>
 *   <li>están todos los claims obligatorios (un token sin {@code exp} no caducaría nunca);</li>
 *   <li>no está en la lista negra.</li>
 * </ol>
 */
@Configuration(proxyBeanMethods = false)
public class JwtConfig {

    @Bean
    public JwtEncoder jwtEncoder(SigningKeys keys) {
        // El encoder solo conoce la clave activa: es la única con la que se firma.
        return new NimbusJwtEncoder(new ImmutableJWKSet<>(new JWKSet(keys.activeKey())));
    }

    @Bean
    public JwtDecoder jwtDecoder(SigningKeys keys, AuthProperties props, RevocationStore revocations) {
        DefaultJWTProcessor<SecurityContext> processor = new DefaultJWTProcessor<>();
        processor.setJWSTypeVerifier(new DefaultJOSEObjectTypeVerifier<>(new JOSEObjectType(AccessTokenIssuer.ACCESS_TOKEN_TYPE)));
        processor.setJWSKeySelector(new JWSVerificationKeySelector<>(Set.of(JWSAlgorithm.ES256),
                new ImmutableJWKSet<>(keys.publicKeys())));
        // Las comprobaciones de claims las hace Spring (abajo), con mensajes de error mejores.
        processor.setJWTClaimsSetVerifier((claims, context) -> { });

        NimbusJwtDecoder decoder = new NimbusJwtDecoder(processor);
        decoder.setJwtValidator(stopAtFirstFailure(List.of(
                new JwtTypeValidator(AccessTokenIssuer.ACCESS_TOKEN_TYPE),
                new JwtTimestampValidator(Duration.ofSeconds(60)),
                new JwtIssuerValidator(props.jwt().issuer()),
                audienceValidator(props.jwt().audience()),
                requiredClaimsValidator(),
                new RevocationValidator(revocations))));
        return decoder;
    }

    /**
     * Ejecuta las comprobaciones en orden y se detiene en la primera que falla.
     * Así un token caducado o con la firma mal ni siquiera llega a consultar Redis.
     */
    static OAuth2TokenValidator<Jwt> stopAtFirstFailure(List<OAuth2TokenValidator<Jwt>> validators) {
        return jwt -> {
            for (OAuth2TokenValidator<Jwt> v : validators) {
                OAuth2TokenValidatorResult result = v.validate(jwt);
                if (result.hasErrors()) {
                    return result;
                }
            }
            return OAuth2TokenValidatorResult.success();
        };
    }

    /** Rechaza tokens cuyo {@code aud} no incluya a NomadIQ (p. ej. emitidos para otra aplicación). */
    static OAuth2TokenValidator<Jwt> audienceValidator(String audience) {
        return jwt -> jwt.getAudience() != null && jwt.getAudience().contains(audience)
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(new OAuth2Error(OAuth2ErrorCodes.INVALID_TOKEN, "audiencia incorrecta", null));
    }

    /** Exige los claims que siempre emitimos: sin ellos el token no se puede caducar ni revocar. */
    static OAuth2TokenValidator<Jwt> requiredClaimsValidator() {
        return jwt -> jwt.getExpiresAt() != null && jwt.getIssuedAt() != null && jwt.getId() != null && jwt.getSubject() != null
                ? OAuth2TokenValidatorResult.success()
                : OAuth2TokenValidatorResult.failure(new OAuth2Error(OAuth2ErrorCodes.INVALID_TOKEN, "faltan claims obligatorios", null));
    }
}
