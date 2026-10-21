package com.nomadiq.authgateway.token;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Acceso a la tabla {@code identity.refresh_tokens}.
 * Solo se guardan huellas SHA-256 de los tokens, nunca el token en sí.
 */
@Repository
public class RefreshTokenRepository {

    /** Una fila de la tabla. */
    public record StoredRefreshToken(UUID userId, UUID familyId, Instant expiresAt, Instant usedAt, Instant revokedAt) {
    }

    private final JdbcClient jdbc;

    public RefreshTokenRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    public void insert(byte[] tokenHash, UUID userId, UUID familyId, Instant issuedAt, Instant expiresAt) {
        jdbc.sql("""
                INSERT INTO refresh_tokens (token_hash, user_id, family_id, issued_at, expires_at)
                VALUES (:hash, :user, :family, :issued, :expires)
                """)
                .param("hash", tokenHash)
                .param("user", userId)
                .param("family", familyId)
                .param("issued", Timestamp.from(issuedAt))
                .param("expires", Timestamp.from(expiresAt))
                .update();
    }

    /**
     * Lee el token y lo "bloquea" hasta el final de la transacción
     * ({@code FOR UPDATE}). Si llegan dos peticiones a la vez con el mismo
     * token, la segunda espera a que termine la primera y entonces lo ve ya
     * usado: es imposible canjear un token dos veces.
     */
    public Optional<StoredRefreshToken> findForUpdate(byte[] tokenHash) {
        return jdbc.sql("""
                SELECT user_id, family_id, expires_at, used_at, revoked_at
                FROM refresh_tokens WHERE token_hash = :hash FOR UPDATE
                """)
                .param("hash", tokenHash)
                .query(RefreshTokenRepository::map)
                .optional();
    }

    public void markUsed(byte[] tokenHash, Instant now) {
        jdbc.sql("UPDATE refresh_tokens SET used_at = :now WHERE token_hash = :hash")
                .param("now", Timestamp.from(now))
                .param("hash", tokenHash)
                .update();
    }

    /** Revoca todos los tokens de una familia (un login concreto, en un dispositivo). */
    public int revokeFamily(UUID familyId, Instant now) {
        return jdbc.sql("UPDATE refresh_tokens SET revoked_at = :now WHERE family_id = :family AND revoked_at IS NULL")
                .param("now", Timestamp.from(now))
                .param("family", familyId)
                .update();
    }

    /** Revoca todos los tokens del usuario (en todos sus dispositivos). */
    public int revokeAllForUser(UUID userId, Instant now) {
        return jdbc.sql("UPDATE refresh_tokens SET revoked_at = :now WHERE user_id = :user AND revoked_at IS NULL")
                .param("now", Timestamp.from(now))
                .param("user", userId)
                .update();
    }

    /** Busca la familia de un token solo si pertenece a ese usuario (para el logout). */
    public Optional<UUID> findFamilyOwnedBy(byte[] tokenHash, UUID userId) {
        return jdbc.sql("SELECT family_id FROM refresh_tokens WHERE token_hash = :hash AND user_id = :user")
                .param("hash", tokenHash)
                .param("user", userId)
                .query(UUID.class)
                .optional();
    }

    private static StoredRefreshToken map(ResultSet rs, int rowNum) throws SQLException {
        return new StoredRefreshToken(
                rs.getObject("user_id", UUID.class),
                rs.getObject("family_id", UUID.class),
                rs.getTimestamp("expires_at").toInstant(),
                toInstant(rs.getTimestamp("used_at")),
                toInstant(rs.getTimestamp("revoked_at")));
    }

    private static Instant toInstant(Timestamp ts) {
        return ts == null ? null : ts.toInstant();
    }
}
