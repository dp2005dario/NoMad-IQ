package com.nomadiq.authgateway.auth;

import java.time.Clock;
import java.time.Instant;
import java.util.Locale;
import java.util.UUID;

import com.nomadiq.authgateway.auth.AuthExceptions.EmailAlreadyRegisteredException;
import com.nomadiq.authgateway.auth.AuthExceptions.InvalidCredentialsException;
import com.nomadiq.authgateway.auth.AuthExceptions.UserNotFoundException;
import com.nomadiq.authgateway.auth.AuthExceptions.WeakPasswordException;
import com.nomadiq.authgateway.config.AuthProperties;
import com.nomadiq.authgateway.ratelimit.RateLimiter;
import com.nomadiq.authgateway.token.AccessTokenIssuer;
import com.nomadiq.authgateway.token.AccessTokenIssuer.IssuedAccessToken;
import com.nomadiq.authgateway.token.RefreshTokenService;
import com.nomadiq.authgateway.token.RefreshTokenService.IssuedRefreshToken;
import com.nomadiq.authgateway.token.RevocationStore;
import com.nomadiq.authgateway.user.UserAccount;
import com.nomadiq.authgateway.user.UserRepository;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DuplicateKeyException;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.oauth2.jwt.Jwt;
import org.springframework.stereotype.Service;

/**
 * El "director de orquesta" de la identidad: registro, login, refresco, logout
 * y baneo. Coordina a los demás (usuarios, tokens, rate limiter, lista negra)
 * sin saber nada de HTTP: así se puede probar sin levantar un servidor web.
 */
@Service
public class AuthService {

    private static final Logger log = LoggerFactory.getLogger(AuthService.class);

    // Nombres de los contadores del rate limiter.
    static final String BUCKET_LOGIN_IP = "login-ip";
    static final String BUCKET_REGISTER_IP = "register-ip";
    static final String BUCKET_REFRESH_IP = "refresh-ip";
    static final String BUCKET_LOGIN_FAILURES = "login-fail";

    /** Un token de acceso y uno de refresco, lo que recibe la app tras el login. */
    public record TokenPair(IssuedAccessToken access, IssuedRefreshToken refresh) {
    }

    private final UserRepository users;
    private final PasswordEncoder passwords;
    private final AccessTokenIssuer accessTokens;
    private final RefreshTokenService refreshTokens;
    private final RevocationStore revocations;
    private final RateLimiter rateLimiter;
    private final AuthProperties props;
    private final Clock clock;
    private final GoogleIdTokenVerifier google;
    /** Huella falsa para que "el email no existe" tarde lo mismo que "contraseña mal". */
    private final String dummyHash;

    public AuthService(UserRepository users, PasswordEncoder passwords, AccessTokenIssuer accessTokens,
                       RefreshTokenService refreshTokens, RevocationStore revocations, RateLimiter rateLimiter,
                       AuthProperties props, Clock clock, GoogleIdTokenVerifier google) {
        this.users = users;
        this.passwords = passwords;
        this.accessTokens = accessTokens;
        this.refreshTokens = refreshTokens;
        this.revocations = revocations;
        this.rateLimiter = rateLimiter;
        this.props = props;
        this.clock = clock;
        this.google = google;
        this.dummyHash = passwords.encode(UUID.randomUUID().toString());
    }

    /** Crea una cuenta nueva. No inicia sesión: la app hace login a continuación. */
    public UserAccount register(String rawEmail, String password, String clientIp) {
        rateLimiter.acquire(BUCKET_REGISTER_IP, clientIp, props.rateLimits().registerPerIp());
        String email = normalizeEmail(rawEmail);
        PasswordPolicy.check(password, email);
        try {
            UserAccount user = users.insert(UUID.randomUUID(), email, passwords.encode(password), clock.instant());
            log.info("Usuario registrado: {}", user.id());
            return user;
        } catch (DuplicateKeyException e) {
            throw new EmailAlreadyRegisteredException();
        }
    }

    /**
     * Comprueba email y contraseña y entrega los tokens.
     *
     * <p>Dos frenos contra la fuerza bruta:
     * <ul>
     *   <li>por IP: muchos intentos desde la misma conexión;</li>
     *   <li>por cuenta: muchos fallos contra el mismo email, aunque vengan de
     *       miles de IP distintas (ataque distribuido con una botnet).</li>
     * </ul>
     */
    public TokenPair login(String rawEmail, String password, String clientIp) {
        rateLimiter.acquire(BUCKET_LOGIN_IP, clientIp, props.rateLimits().loginPerIp());
        String email = normalizeEmail(rawEmail);
        rateLimiter.ensureNotBlocked(BUCKET_LOGIN_FAILURES, email, props.rateLimits().loginFailuresPerAccount());

        UserAccount user = users.findByEmail(email).orElse(null);
        // Siempre se calcula un Argon2 (con la huella real o con la falsa):
        // si el email no existiera y respondiéramos al instante, el tiempo de
        // respuesta delataría qué emails están registrados.
        boolean passwordOk = passwords.matches(password, user != null ? user.passwordHash() : dummyHash);
        if (user == null || !passwordOk || user.isDisabled()) {
            rateLimiter.record(BUCKET_LOGIN_FAILURES, email, props.rateLimits().loginFailuresPerAccount());
            log.info("Login fallido (cuenta {})", user != null ? user.id() : "inexistente");
            throw new InvalidCredentialsException();
        }
        rateLimiter.reset(BUCKET_LOGIN_FAILURES, email);

        // Si hemos endurecido Argon2 desde que se guardó la huella, la rehacemos ahora
        // (es el único momento en que tenemos la contraseña en claro).
        if (passwords.upgradeEncoding(user.passwordHash())) {
            users.updatePasswordHash(user.id(), passwords.encode(password));
        }
        return new TokenPair(accessTokens.issue(user.id(), user.roles()), refreshTokens.issueNewFamily(user.id()));
    }

    /**
     * Entrar con Google. Si ya hay una cuenta con ese email se enlaza (Google
     * ya comprobó que el email es de quien entra); si no, se crea una nueva.
     * Su contraseña es una huella de un valor al azar que nadie conoce.
     */
    public TokenPair loginWithGoogle(String idToken, String clientIp) {
        rateLimiter.acquire(BUCKET_LOGIN_IP, clientIp, props.rateLimits().loginPerIp());
        GoogleIdTokenVerifier.GoogleIdentity who = google.verify(idToken);
        String email = normalizeEmail(who.email());
        String photo = who.pictureUrl() != null && who.pictureUrl().startsWith("https://") && who.pictureUrl().length() <= 500
                ? who.pictureUrl() : null;
        UserAccount user = users.findByGoogleSub(who.sub()).orElse(null);
        if (user == null) {
            user = users.findByEmail(email).orElse(null);
            if (user != null) {
                users.linkGoogle(user.id(), who.sub(), photo);
            } else {
                try {
                    user = users.insertGoogle(UUID.randomUUID(), email, passwords.encode(UUID.randomUUID().toString()),
                            who.sub(), photo, clock.instant());
                    log.info("Usuario registrado con Google: {}", user.id());
                } catch (DuplicateKeyException e) {
                    throw new InvalidCredentialsException();
                }
            }
        }
        if (user.isDisabled()) {
            throw new InvalidCredentialsException();
        }
        return new TokenPair(accessTokens.issue(user.id(), user.roles()), refreshTokens.issueNewFamily(user.id()));
    }

    /**
     * Cambiar la contraseña: pide la actual (mismos frenos que borrar la
     * cuenta), cierra las sesiones de los demás móviles y devuelve tokens
     * nuevos para este.
     */
    public TokenPair changePassword(UUID userId, String current, String next, String clientIp) {
        rateLimiter.acquire(BUCKET_LOGIN_IP, clientIp, props.rateLimits().loginPerIp());
        UserAccount user = users.findById(userId).orElseThrow(InvalidCredentialsException::new);
        rateLimiter.ensureNotBlocked(BUCKET_LOGIN_FAILURES, user.email(), props.rateLimits().loginFailuresPerAccount());
        if (!passwords.matches(current, user.passwordHash())) {
            rateLimiter.record(BUCKET_LOGIN_FAILURES, user.email(), props.rateLimits().loginFailuresPerAccount());
            throw new InvalidCredentialsException();
        }
        PasswordPolicy.check(next, user.email());
        users.updatePasswordHash(userId, passwords.encode(next));
        refreshTokens.revokeAllForUser(userId);
        // Un segundo antes: la lista negra compara por segundos y si no, también
        // anularía el token nuevo que entregamos ahora mismo.
        revocations.revokeAllIssuedBefore(userId, clock.instant().minusSeconds(1), props.jwt().accessTokenTtl());
        log.warn("Contraseña cambiada por su dueño: {}", userId);
        return new TokenPair(accessTokens.issue(userId, user.roles()), refreshTokens.issueNewFamily(userId));
    }

    /** Canjea un token de refresco por una pareja nueva (rotación). */
    public TokenPair refresh(String refreshToken, String clientIp) {
        rateLimiter.acquire(BUCKET_REFRESH_IP, clientIp, props.rateLimits().refreshPerIp());
        RefreshTokenService.Rotation rotation = refreshTokens.rotate(refreshToken,
                id -> users.findById(id).map(u -> !u.isDisabled()).orElse(false));
        // Los roles se leen de nuevo de la base de datos: si a alguien le
        // quitamos ADMIN, su siguiente token ya no lo lleva.
        UserAccount user = users.findById(rotation.userId()).orElseThrow(InvalidCredentialsException::new);
        return new TokenPair(accessTokens.issue(user.id(), user.roles()), rotation.replacement());
    }

    /**
     * Cierra la sesión de este dispositivo: el token de acceso actual entra en
     * la lista negra y el de refresco (y su familia) queda revocado.
     */
    public void logout(Jwt accessToken, String refreshToken) {
        UUID userId = UUID.fromString(accessToken.getSubject());
        revocations.revokeToken(userId, accessToken.getId(), accessToken.getExpiresAt());
        if (refreshToken != null && !refreshToken.isBlank() && !refreshTokens.revokeFamily(refreshToken, userId)) {
            log.info("Logout de {} con un refresh token desconocido o ajeno (ignorado)", userId);
        }
    }

    /** Cierra TODAS las sesiones de un usuario, en todos sus dispositivos. */
    public void revokeAllSessions(UUID userId) {
        users.findById(userId).orElseThrow(UserNotFoundException::new);
        Instant now = clock.instant();
        int revoked = refreshTokens.revokeAllForUser(userId);
        revocations.revokeAllIssuedBefore(userId, now, props.jwt().accessTokenTtl());
        log.warn("Sesiones del usuario {} revocadas ({} refresh tokens)", userId, revoked);
    }

    /** Baneo: desactiva la cuenta y expulsa todas sus sesiones al instante. */
    public void disableUser(UUID userId) {
        if (!users.disable(userId, clock.instant())) {
            throw new UserNotFoundException();
        }
        revokeAllSessions(userId);
    }

    /**
     * "Borrar mi cuenta" (lo exige Google Play y el RGPD). Pasos:
     * <ol>
     *   <li>los mismos frenos que el login (por IP y por cuenta): nadie puede
     *       probar contraseñas a millones por esta puerta;</li>
     *   <li>se comprueba la contraseña otra vez (un móvil prestado no basta);</li>
     *   <li>se expulsan todas las sesiones, en todos los móviles;</li>
     *   <li>se borra la fila del usuario (y con ella sus tokens de refresco).</li>
     * </ol>
     * Los datos de los demás servicios (botes, alertas...) los borra la app
     * ANTES de llamar aquí, con el mismo pase (ver docs/guia-ajustes.md).
     */
    public void deleteAccount(UUID userId, String password, String clientIp) {
        rateLimiter.acquire(BUCKET_LOGIN_IP, clientIp, props.rateLimits().loginPerIp());
        UserAccount user = users.findById(userId).orElseThrow(InvalidCredentialsException::new);
        rateLimiter.ensureNotBlocked(BUCKET_LOGIN_FAILURES, user.email(), props.rateLimits().loginFailuresPerAccount());
        if (!passwords.matches(password, user.passwordHash())) {
            rateLimiter.record(BUCKET_LOGIN_FAILURES, user.email(), props.rateLimits().loginFailuresPerAccount());
            throw new InvalidCredentialsException();
        }
        revokeAllSessions(userId);
        users.delete(userId);
        // Solo el id (un número al azar): ni el email ni nada que identifique.
        log.warn("Cuenta {} borrada a petición de su dueño", userId);
    }

    /** "Ana@Mail.com " y "ana@mail.com" son la misma cuenta. */
    static String normalizeEmail(String email) {
        return email == null ? "" : email.trim().toLowerCase(Locale.ROOT);
    }

    /** Reglas de contraseña al estilo NIST SP 800-63B: largo mínimo, sin reglas absurdas de símbolos. */
    static final class PasswordPolicy {
        static final int MIN_LENGTH = 12;

        private PasswordPolicy() {
        }

        static void check(String password, String email) {
            if (password == null || password.codePointCount(0, password.length()) < MIN_LENGTH) {
                throw new WeakPasswordException("la contraseña debe tener al menos " + MIN_LENGTH + " caracteres");
            }
            // La parte antes de la @ (si tiene 4+ letras) no puede aparecer en la contraseña.
            String localPart = email.split("@", 2)[0];
            if (password.isBlank() || (localPart.length() >= 4 && password.toLowerCase(Locale.ROOT).contains(localPart))) {
                throw new WeakPasswordException("la contraseña no puede contener tu email");
            }
        }
    }
}
