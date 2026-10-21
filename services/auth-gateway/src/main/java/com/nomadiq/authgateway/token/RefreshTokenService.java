package com.nomadiq.authgateway.token;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Instant;
import java.util.Base64;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Predicate;

import com.nomadiq.authgateway.config.AuthProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * Tokens de refresco: la "llave de larga duración" para pedir tokens de acceso nuevos.
 *
 * <p><b>Analogía:</b> el token de acceso es la tarjeta de la habitación del
 * hotel, válida 15 minutos. El de refresco es el resguardo con el que vas a
 * recepción a por una tarjeta nueva. Recepción te cambia el resguardo por uno
 * nuevo cada vez (rotación) y rompe el viejo. Si alguien aparece con un
 * resguardo ya roto, recepción sabe que hay una copia robada y anula todos los
 * resguardos de esa estancia.
 *
 * <p>A diferencia del JWT, este token NO lleva datos dentro: son 32 bytes
 * aleatorios (256 bits, imposibles de adivinar). Por eso se puede revocar al
 * instante: basta con marcarlo en la base de datos.
 */
@Service
public class RefreshTokenService {

    private static final Logger log = LoggerFactory.getLogger(RefreshTokenService.class);
    private static final int TOKEN_BYTES = 32;

    /** Resultado de emitir un token nuevo: el valor (solo lo ve el cliente) y su caducidad. */
    public record IssuedRefreshToken(String value, Instant expiresAt) {
    }

    /** Resultado de una rotación correcta: de quién era y el token que lo sustituye. */
    public record Rotation(UUID userId, IssuedRefreshToken replacement) {
    }

    // SecureRandom = generador aleatorio criptográfico (el normal, Random, es predecible).
    private final SecureRandom random = new SecureRandom();
    private final RefreshTokenRepository repo;
    private final AuthProperties.Jwt config;
    private final Clock clock;

    public RefreshTokenService(RefreshTokenRepository repo, AuthProperties props, Clock clock) {
        this.repo = repo;
        this.config = props.jwt();
        this.clock = clock;
    }

    /** Emite el primer token de una sesión nueva (login). Empieza una familia nueva. */
    @Transactional
    public IssuedRefreshToken issueNewFamily(UUID userId) {
        return issue(userId, UUID.randomUUID(), clock.instant());
    }

    /**
     * Canjea un token por otro nuevo. Todo ocurre en UNA transacción: o se
     * marca el viejo como usado Y se crea el nuevo, o no pasa nada.
     *
     * <p>{@code noRollbackFor}: si detectamos reutilización, revocamos la
     * familia y lanzamos la excepción. Sin esta opción, la excepción desharía
     * también la revocación, ¡justo lo que no queremos!
     *
     * @param userIsActive se llama con el id del dueño para comprobar que la cuenta sigue activa
     */
    @Transactional(noRollbackFor = InvalidRefreshTokenException.class)
    public Rotation rotate(String presentedToken, Predicate<UUID> userIsActive) {
        byte[] hash = hash(presentedToken);
        Instant now = clock.instant();
        RefreshTokenRepository.StoredRefreshToken stored = repo.findForUpdate(hash)
                .orElseThrow(() -> new InvalidRefreshTokenException("token desconocido"));

        if (stored.revokedAt() != null) {
            throw new InvalidRefreshTokenException("token revocado");
        }
        if (stored.usedAt() != null) {
            // ¡Alarma! Alguien reutiliza un token ya canjeado: probable robo.
            int revoked = repo.revokeFamily(stored.familyId(), now);
            log.warn("Reutilización de refresh token detectada: familia {} del usuario {} revocada ({} tokens)",
                    stored.familyId(), stored.userId(), revoked);
            throw new InvalidRefreshTokenException("token reutilizado");
        }
        if (!stored.expiresAt().isAfter(now)) {
            throw new InvalidRefreshTokenException("token caducado");
        }
        if (!userIsActive.test(stored.userId())) {
            repo.revokeAllForUser(stored.userId(), now);
            throw new InvalidRefreshTokenException("cuenta desactivada");
        }

        repo.markUsed(hash, now);
        return new Rotation(stored.userId(), issue(stored.userId(), stored.familyId(), now));
    }

    /**
     * Logout de un dispositivo: revoca la familia del token, pero solo si es
     * del usuario que lo pide (nadie puede cerrar la sesión de otro con un token ajeno).
     */
    @Transactional
    public boolean revokeFamily(String presentedToken, UUID userId) {
        Optional<UUID> family = repo.findFamilyOwnedBy(hash(presentedToken), userId);
        family.ifPresent(f -> repo.revokeFamily(f, clock.instant()));
        return family.isPresent();
    }

    /** "Cerrar sesión en todos los dispositivos" o baneo. */
    @Transactional
    public int revokeAllForUser(UUID userId) {
        return repo.revokeAllForUser(userId, clock.instant());
    }

    private IssuedRefreshToken issue(UUID userId, UUID familyId, Instant now) {
        byte[] bytes = new byte[TOKEN_BYTES];
        random.nextBytes(bytes);
        // Base64 "URL-safe": sin + ni / ni =, se puede enviar en cualquier sitio sin escapar.
        String value = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
        Instant expiresAt = now.plus(config.refreshTokenTtl());
        repo.insert(hash(value), userId, familyId, now, expiresAt);
        return new IssuedRefreshToken(value, expiresAt);
    }

    /**
     * Huella SHA-256 del token. Para contraseñas usaríamos Argon2 (lento a
     * propósito), pero aquí el token ya es aleatorio y larguísimo: no se puede
     * adivinar por fuerza bruta, así que basta con un hash rápido.
     */
    static byte[] hash(String token) {
        try {
            return MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.US_ASCII));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 siempre existe en Java", e);
        }
    }
}
