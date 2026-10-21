package com.nomadiq.authgateway.token;

import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.nomadiq.authgateway.config.AuthProperties;
import com.nomadiq.authgateway.keys.SigningKeys;
import com.nomadiq.authgateway.user.Role;
import org.springframework.security.oauth2.jose.jws.SignatureAlgorithm;
import org.springframework.security.oauth2.jwt.JwsHeader;
import org.springframework.security.oauth2.jwt.JwtClaimsSet;
import org.springframework.security.oauth2.jwt.JwtEncoder;
import org.springframework.security.oauth2.jwt.JwtEncoderParameters;
import org.springframework.stereotype.Component;

/**
 * Fabrica los tokens de acceso (JWT firmados con ES256).
 *
 * <p>Un JWT tiene tres partes separadas por puntos: {@code cabecera.datos.firma}.
 * Los datos ("claims") van en Base64, <b>no cifrados</b>: cualquiera puede leerlos.
 * Por eso aquí solo ponemos lo mínimo (id de usuario y roles), nunca el email
 * ni nada personal. La firma garantiza que nadie los ha modificado.
 *
 * <p>Claims que ponemos y por qué:
 * <ul>
 *   <li>{@code iss} (emisor) y {@code aud} (destinatario): un token de otro
 *       sistema, o pensado para otro servicio, se rechaza;</li>
 *   <li>{@code sub}: el id del usuario (UUID, no el email);</li>
 *   <li>{@code iat}, {@code nbf}, {@code exp}: cuándo se emitió, desde cuándo
 *       vale y cuándo caduca (15 min);</li>
 *   <li>{@code jti}: id único del token, para poder revocarlo individualmente;</li>
 *   <li>{@code roles}: para el control de acceso por roles (RBAC).</li>
 * </ul>
 * La cabecera lleva {@code typ: at+jwt} (RFC 9068): marca que es un token de
 * ACCESO, para que no se pueda colar otro tipo de JWT firmado por nosotros.
 */
@Component
public class AccessTokenIssuer {

    /** Tipo de token según RFC 9068. Lo comprobamos también al validar. */
    public static final String ACCESS_TOKEN_TYPE = "at+jwt";
    /** Nombre del claim con los roles. */
    public static final String ROLES_CLAIM = "roles";

    private final JwtEncoder encoder;
    private final SigningKeys keys;
    private final AuthProperties.Jwt config;
    private final Clock clock;

    public AccessTokenIssuer(JwtEncoder encoder, SigningKeys keys, AuthProperties props, Clock clock) {
        this.encoder = encoder;
        this.keys = keys;
        this.config = props.jwt();
        this.clock = clock;
    }

    /** El token firmado y cuándo caduca (la app lo usa para saber cuándo refrescar). */
    public record IssuedAccessToken(String value, String tokenId, Instant expiresAt) {
    }

    public IssuedAccessToken issue(UUID userId, List<Role> roles) {
        Instant now = clock.instant();
        Instant expiresAt = now.plus(config.accessTokenTtl());
        String tokenId = UUID.randomUUID().toString();

        JwtClaimsSet claims = JwtClaimsSet.builder()
                .issuer(config.issuer())
                .audience(List.of(config.audience()))
                .subject(userId.toString())
                .issuedAt(now)
                .notBefore(now)
                .expiresAt(expiresAt)
                .id(tokenId)
                .claim(ROLES_CLAIM, roles.stream().map(Role::name).toList())
                .build();

        JwsHeader header = JwsHeader.with(SignatureAlgorithm.ES256)
                .keyId(keys.activeKey().getKeyID())
                .type(ACCESS_TOKEN_TYPE)
                .build();

        String value = encoder.encode(JwtEncoderParameters.from(header, claims)).getTokenValue();
        return new IssuedAccessToken(value, tokenId, expiresAt);
    }
}
