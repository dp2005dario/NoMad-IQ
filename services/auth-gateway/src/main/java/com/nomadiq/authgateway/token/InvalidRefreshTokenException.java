package com.nomadiq.authgateway.token;

/**
 * El token de refresco no sirve (no existe, caducado, revocado o reutilizado).
 *
 * <p>A propósito, la API responde lo mismo en todos los casos (401): si dijéramos
 * "este token existió pero ya se usó", daríamos pistas a un atacante.
 */
public class InvalidRefreshTokenException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    public InvalidRefreshTokenException(String internalReason) {
        // El motivo solo va al log interno, nunca a la respuesta HTTP.
        super(internalReason);
    }
}
