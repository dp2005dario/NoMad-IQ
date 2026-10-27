package com.nomadiq.authgateway.api;

import java.time.Clock;
import java.time.Duration;
import java.util.List;

import com.nomadiq.authgateway.api.ApiModels.ChangePasswordRequest;
import com.nomadiq.authgateway.api.ApiModels.GoogleLoginRequest;
import com.nomadiq.authgateway.api.ApiModels.LoginRequest;
import com.nomadiq.authgateway.api.ApiModels.LogoutRequest;
import com.nomadiq.authgateway.api.ApiModels.RefreshRequest;
import com.nomadiq.authgateway.api.ApiModels.RegisterRequest;
import com.nomadiq.authgateway.api.ApiModels.TokenResponse;
import com.nomadiq.authgateway.api.ApiModels.UserResponse;
import com.nomadiq.authgateway.auth.AuthService;
import com.nomadiq.authgateway.token.AccessTokenIssuer;
import com.nomadiq.authgateway.user.Role;
import com.nomadiq.authgateway.user.UserAccount;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.ResponseStatus;
import org.springframework.web.bind.annotation.RestController;

/**
 * Las rutas HTTP de autenticación. Este controlador es deliberadamente "tonto":
 * traduce HTTP ⇄ Java y delega toda la lógica en {@link AuthService}.
 *
 * <pre>
 *  POST /v1/auth/register   crear cuenta                       (público)
 *  POST /v1/auth/login      email + contraseña -> tokens        (público)
 *  POST /v1/auth/google     id_token de Google -> tokens         (público)
 *  POST /v1/auth/password   cambiar contraseña                  (token)
 *  POST /v1/auth/refresh    refresh token -> tokens nuevos      (público)
 *  POST /v1/auth/logout     cerrar sesión de este dispositivo   (token)
 *  GET  /v1/auth/verify     validar token para el proxy de borde (token)
 * </pre>
 */
@RestController
@RequestMapping("/v1/auth")
public class AuthController {

    /** Cabeceras de identidad que el proxy de borde reenvía a los microservicios internos. */
    public static final String HEADER_USER_ID = "X-User-ID";
    public static final String HEADER_USER_ROLES = "X-User-Roles";
    public static final String HEADER_TOKEN_ID = "X-Token-ID";

    private final AuthService auth;
    private final Clock clock;

    public AuthController(AuthService auth, Clock clock) {
        this.auth = auth;
        this.clock = clock;
    }

    @PostMapping("/register")
    @ResponseStatus(HttpStatus.CREATED)
    public UserResponse register(@Valid @RequestBody RegisterRequest body, HttpServletRequest request) {
        return toResponse(auth.register(body.email(), body.password(), clientIp(request)));
    }

    @PostMapping("/login")
    public TokenResponse login(@Valid @RequestBody LoginRequest body, HttpServletRequest request) {
        return toResponse(auth.login(body.email(), body.password(), clientIp(request)));
    }

    /** Entrar con Google. 503 si el servidor no tiene configurado GOOGLE_CLIENT_ID. */
    @PostMapping("/google")
    public TokenResponse google(@Valid @RequestBody GoogleLoginRequest body, HttpServletRequest request) {
        return toResponse(auth.loginWithGoogle(body.idToken(), clientIp(request)));
    }

    /** Cambiar la contraseña. Cierra las demás sesiones y devuelve tokens nuevos para esta. */
    @PostMapping("/password")
    public TokenResponse changePassword(@AuthenticationPrincipal Jwt jwt,
                                        @Valid @RequestBody ChangePasswordRequest body, HttpServletRequest request) {
        return toResponse(auth.changePassword(java.util.UUID.fromString(jwt.getSubject()),
                body.currentPassword(), body.newPassword(), clientIp(request)));
    }

    @PostMapping("/refresh")
    public TokenResponse refresh(@Valid @RequestBody RefreshRequest body, HttpServletRequest request) {
        return toResponse(auth.refresh(body.refreshToken(), clientIp(request)));
    }

    /** El cuerpo es opcional: sin él solo se anula el token de acceso. */
    @PostMapping("/logout")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void logout(@AuthenticationPrincipal Jwt jwt, @Valid @RequestBody(required = false) LogoutRequest body) {
        auth.logout(jwt, body == null ? null : body.refreshToken());
    }

    /**
     * "Forward auth": el proxy de borde (Envoy, Traefik, NGINX...) llama aquí con
     * el token del cliente antes de dejar pasar cada petición. Si respondemos
     * 204, copia nuestras cabeceras {@code X-User-*} en la petición original y
     * la reenvía al microservicio interno por mTLS. Si respondemos 401, la corta.
     *
     * <p>Así cada microservicio recibe "quién es el usuario" ya verificado, pero
     * SIGUE exigiendo mTLS: un atacante dentro de la red no puede inventarse
     * {@code X-User-ID} porque no tiene certificado de cliente para hablar con él.
     */
    @GetMapping("/verify")
    public ResponseEntity<Void> verify(@AuthenticationPrincipal Jwt jwt) {
        List<String> roles = jwt.getClaimAsStringList(AccessTokenIssuer.ROLES_CLAIM);
        return ResponseEntity.noContent()
                .header(HEADER_USER_ID, jwt.getSubject())
                .header(HEADER_USER_ROLES, roles == null ? "" : String.join(",", roles))
                .header(HEADER_TOKEN_ID, jwt.getId())
                .build();
    }

    // ------------------------------------------------------------------

    /**
     * La IP del cliente, para el rate limiting. Solo se fía de X-Forwarded-For
     * si FORWARD_HEADERS_STRATEGY=native (hay un proxy de confianza delante):
     * en ese caso Tomcat ya la ha puesto aquí.
     */
    static String clientIp(HttpServletRequest request) {
        return request.getRemoteAddr();
    }

    private TokenResponse toResponse(AuthService.TokenPair pair) {
        long accessSeconds = Math.max(0, Duration.between(clock.instant(), pair.access().expiresAt()).toSeconds());
        long refreshSeconds = Math.max(0, Duration.between(clock.instant(), pair.refresh().expiresAt()).toSeconds());
        return new TokenResponse(pair.access().value(), "Bearer", accessSeconds, pair.refresh().value(), refreshSeconds);
    }

    static UserResponse toResponse(UserAccount user) {
        return new UserResponse(user.id(), user.email(), user.roles().stream().map(Role::name).toList(), user.createdAt(), user.photoUrl());
    }
}
