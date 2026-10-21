package com.nomadiq.authgateway.token;

import java.util.UUID;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessException;
import org.springframework.security.oauth2.core.OAuth2Error;
import org.springframework.security.oauth2.core.OAuth2ErrorCodes;
import org.springframework.security.oauth2.core.OAuth2TokenValidator;
import org.springframework.security.oauth2.core.OAuth2TokenValidatorResult;
import org.springframework.security.oauth2.jwt.Jwt;

/**
 * Último control de cada token: ¿está en la lista negra?
 *
 * <p>Se ejecuta DESPUÉS de comprobar la firma y las fechas (eso es pura
 * matemática en memoria). Si Redis no responde, el token se rechaza: en
 * seguridad se prefiere "fallar cerrado" (no dejar pasar a nadie) antes que
 * "fallar abierto" (dejar pasar a todos, incluidos los baneados).
 */
public class RevocationValidator implements OAuth2TokenValidator<Jwt> {

    private static final Logger log = LoggerFactory.getLogger(RevocationValidator.class);

    private final RevocationStore store;

    public RevocationValidator(RevocationStore store) {
        this.store = store;
    }

    @Override
    public OAuth2TokenValidatorResult validate(Jwt jwt) {
        UUID userId;
        try {
            userId = UUID.fromString(jwt.getSubject());
        } catch (IllegalArgumentException | NullPointerException e) {
            return fail("sub no es un identificador válido");
        }
        if (jwt.getId() == null || jwt.getIssuedAt() == null) {
            return fail("faltan jti o iat");
        }
        try {
            if (store.isRevoked(userId, jwt.getId(), jwt.getIssuedAt())) {
                return fail("token revocado");
            }
        } catch (DataAccessException e) {
            log.error("Redis no disponible al comprobar revocaciones: se rechaza el token (fallo cerrado)", e);
            return fail("no se pudo comprobar la revocación");
        }
        return OAuth2TokenValidatorResult.success();
    }

    private static OAuth2TokenValidatorResult fail(String description) {
        return OAuth2TokenValidatorResult.failure(new OAuth2Error(OAuth2ErrorCodes.INVALID_TOKEN, description, null));
    }
}
