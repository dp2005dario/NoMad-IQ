package com.nomadiq.authgateway.auth;

/**
 * Errores "de negocio" del login y el registro. La API los traduce a códigos
 * HTTP en {@code ApiExceptionHandler}; aquí solo dicen QUÉ ha pasado.
 */
public final class AuthExceptions {

    private AuthExceptions() {
    }

    /**
     * Email o contraseña incorrectos, o cuenta desactivada. Un único mensaje
     * para todos los casos: así un atacante no puede averiguar qué emails
     * están registrados probando el login.
     */
    public static class InvalidCredentialsException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public InvalidCredentialsException() {
            super("credenciales inválidas");
        }
    }

    /** Ya existe una cuenta con ese email (409 Conflict). */
    public static class EmailAlreadyRegisteredException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public EmailAlreadyRegisteredException() {
            super("email ya registrado");
        }
    }

    /** La contraseña no cumple la política (400). El mensaje sí se muestra al usuario. */
    public static class WeakPasswordException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public WeakPasswordException(String message) {
            super(message);
        }
    }

    /** El usuario indicado no existe (404, solo en endpoints de administración). */
    public static class UserNotFoundException extends RuntimeException {
        private static final long serialVersionUID = 1L;

        public UserNotFoundException() {
            super("usuario no encontrado");
        }
    }
}
