package com.nomadiq.authgateway.api;

import java.util.UUID;

import com.nomadiq.authgateway.api.ApiModels.UserResponse;
import com.nomadiq.authgateway.auth.AuthExceptions.UserNotFoundException;
import com.nomadiq.authgateway.auth.AuthService;
import com.nomadiq.authgateway.user.UserRepository;
import org.springframework.http.HttpStatus;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * Datos del propio usuario y acciones de administración.
 *
 * <pre>
 *  GET  /v1/me                                  quién soy                    (token)
 *  POST /v1/admin/users/{id}/revoke-sessions    cerrar todas sus sesiones    (ADMIN)
 *  POST /v1/admin/users/{id}/disable            banear la cuenta             (ADMIN)
 * </pre>
 *
 * El permiso ADMIN lo comprueba {@code SecurityConfig} antes de llegar aquí.
 */
@RestController
public class UserController {

    private final UserRepository users;
    private final AuthService auth;

    public UserController(UserRepository users, AuthService auth) {
        this.users = users;
        this.auth = auth;
    }

    @GetMapping("/v1/me")
    public UserResponse me(@AuthenticationPrincipal Jwt jwt) {
        return users.findById(UUID.fromString(jwt.getSubject()))
                .map(AuthController::toResponse)
                .orElseThrow(UserNotFoundException::new);
    }

    @PostMapping("/v1/admin/users/{userId}/revoke-sessions")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void revokeSessions(@PathVariable UUID userId) {
        auth.revokeAllSessions(userId);
    }

    @PostMapping("/v1/admin/users/{userId}/disable")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void disable(@PathVariable UUID userId) {
        auth.disableUser(userId);
    }
}
