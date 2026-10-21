package com.nomadiq.authgateway.api;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.Email;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * Los "formularios" JSON que entran y salen de la API.
 *
 * <p>Las anotaciones ({@code @NotBlank}, {@code @Size}...) las comprueba Spring
 * ANTES de llamar a nuestro código: si el JSON no cumple, responde 400 y
 * nuestro código ni se entera. Los límites de tamaño también protegen:
 * Argon2 con una "contraseña" de 10 MB sería un ataque de denegación de servicio.
 */
public final class ApiModels {

    private ApiModels() {
    }

    public record RegisterRequest(
            @NotBlank(message = "es obligatorio") @Email(message = "no es un email válido")
            @Size(max = 254, message = "máximo 254 caracteres") String email,
            @NotNull(message = "es obligatoria") @Size(min = 12, max = 128, message = "debe tener entre 12 y 128 caracteres") String password) {

        /** Nunca imprimir la contraseña, ni siquiera en un log de depuración. */
        @Override
        public String toString() {
            return "RegisterRequest[email=***, password=***]";
        }
    }

    public record LoginRequest(
            @NotBlank(message = "es obligatorio") @Size(max = 254, message = "máximo 254 caracteres") String email,
            @NotNull(message = "es obligatoria") @Size(min = 1, max = 128, message = "máximo 128 caracteres") String password) {

        @Override
        public String toString() {
            return "LoginRequest[email=***, password=***]";
        }
    }

    /** Los tokens de refresco miden 43 caracteres; el límite evita basura enorme. */
    public record RefreshRequest(@JsonProperty("refresh_token") @NotBlank(message = "es obligatorio")
                                 @Size(max = 128, message = "demasiado largo") String refreshToken) {

        @Override
        public String toString() {
            return "RefreshRequest[***]";
        }
    }

    /** Logout: el token de refresco es opcional (si no se envía, solo se anula el de acceso). */
    public record LogoutRequest(@JsonProperty("refresh_token") @Size(max = 128, message = "demasiado largo") String refreshToken) {

        @Override
        public String toString() {
            return "LogoutRequest[***]";
        }
    }

    /**
     * Respuesta del login y del refresco, con los nombres estándar de OAuth 2
     * (RFC 6749): así cualquier librería cliente la entiende sin adaptarla.
     */
    public record TokenResponse(
            @JsonProperty("access_token") String accessToken,
            @JsonProperty("token_type") String tokenType,
            @JsonProperty("expires_in") long expiresIn,
            @JsonProperty("refresh_token") String refreshToken,
            @JsonProperty("refresh_token_expires_in") long refreshTokenExpiresIn) {
    }

    /** Datos públicos de un usuario (sin la huella de la contraseña). */
    public record UserResponse(UUID id, String email, List<String> roles, @JsonProperty("created_at") Instant createdAt) {
    }
}
