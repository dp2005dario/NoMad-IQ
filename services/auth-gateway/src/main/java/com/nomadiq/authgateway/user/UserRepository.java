package com.nomadiq.authgateway.user;

import java.sql.Array;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/**
 * Acceso a la tabla {@code identity.users}.
 *
 * <p>Escribimos el SQL a mano (con {@link JdbcClient}) en lugar de usar un ORM
 * que lo genere solo: así se ve exactamente qué se ejecuta. Todos los valores
 * van como parámetros ({@code :email}), NUNCA pegados al texto del SQL: eso
 * hace imposible la inyección SQL (que un email como {@code ' OR 1=1 --}
 * cambie el significado de la consulta).
 */
@Repository
public class UserRepository {

    private static final String COLUMNS = "id, email, password_hash, roles, created_at, disabled_at, photo_url";

    private final JdbcClient jdbc;

    public UserRepository(JdbcClient jdbc) {
        this.jdbc = jdbc;
    }

    /**
     * Inserta un usuario nuevo con el rol USER.
     * Si el email ya existe, PostgreSQL lo rechaza por el índice único y Spring
     * lanza {@code DuplicateKeyException} (la API lo traduce a 409 Conflict).
     */
    public UserAccount insert(UUID id, String email, String passwordHash, Instant now) {
        return jdbc.sql("INSERT INTO users (id, email, password_hash, created_at) VALUES (:id, :email, :hash, :now) RETURNING " + COLUMNS)
                .param("id", id)
                .param("email", email)
                .param("hash", passwordHash)
                .param("now", Timestamp.from(now))
                .query(UserRepository::map)
                .single();
    }

    public Optional<UserAccount> findByEmail(String email) {
        return jdbc.sql("SELECT " + COLUMNS + " FROM users WHERE email = :email")
                .param("email", email)
                .query(UserRepository::map)
                .optional();
    }

    public Optional<UserAccount> findById(UUID id) {
        return jdbc.sql("SELECT " + COLUMNS + " FROM users WHERE id = :id")
                .param("id", id)
                .query(UserRepository::map)
                .optional();
    }

    /** Guarda una huella nueva (cuando subimos la dureza de Argon2, se actualiza en el siguiente login). */
    public void updatePasswordHash(UUID id, String passwordHash) {
        jdbc.sql("UPDATE users SET password_hash = :hash WHERE id = :id")
                .param("hash", passwordHash)
                .param("id", id)
                .update();
    }

    /** El usuario enlazado a esa cuenta de Google, si existe. */
    public Optional<UserAccount> findByGoogleSub(String googleSub) {
        return jdbc.sql("SELECT " + COLUMNS + " FROM users WHERE google_sub = :sub")
                .param("sub", googleSub)
                .query(UserRepository::map)
                .optional();
    }

    /** Crea un usuario que entra con Google (su contraseña es una huella inservible). */
    public UserAccount insertGoogle(UUID id, String email, String unusablePasswordHash, String googleSub,
                                    String photoUrl, Instant now) {
        return jdbc.sql("INSERT INTO users (id, email, password_hash, created_at, google_sub, photo_url) "
                        + "VALUES (:id, :email, :hash, :now, :sub, :photo) RETURNING " + COLUMNS)
                .param("id", id)
                .param("email", email)
                .param("hash", unusablePasswordHash)
                .param("now", Timestamp.from(now))
                .param("sub", googleSub)
                .param("photo", photoUrl)
                .query(UserRepository::map)
                .single();
    }

    /** Enlaza una cuenta que ya existía (por email) con Google y guarda su foto si no tenía. */
    public void linkGoogle(UUID id, String googleSub, String photoUrl) {
        jdbc.sql("UPDATE users SET google_sub = :sub, photo_url = COALESCE(photo_url, :photo) WHERE id = :id")
                .param("sub", googleSub)
                .param("photo", photoUrl)
                .param("id", id)
                .update();
    }

    /** Desactiva la cuenta (baneo). Devuelve false si el usuario no existe. */
    public boolean disable(UUID id, Instant now) {
        return jdbc.sql("UPDATE users SET disabled_at = COALESCE(disabled_at, :now) WHERE id = :id")
                .param("now", Timestamp.from(now))
                .param("id", id)
                .update() == 1;
    }

    /**
     * Borra al usuario DE VERDAD (no lo marca: desaparece la fila). Sus tokens
     * de refresco se van con él solos ({@code ON DELETE CASCADE} en la tabla).
     * Devuelve false si ya no existía.
     */
    public boolean delete(UUID id) {
        return jdbc.sql("DELETE FROM users WHERE id = :id")
                .param("id", id)
                .update() == 1;
    }

    /** Convierte una fila de la tabla en un objeto Java. */
    private static UserAccount map(ResultSet rs, int rowNum) throws SQLException {
        Timestamp disabled = rs.getTimestamp("disabled_at");
        return new UserAccount(
                rs.getObject("id", UUID.class),
                rs.getString("email"),
                rs.getString("password_hash"),
                parseRoles(rs.getArray("roles")),
                rs.getTimestamp("created_at").toInstant(),
                disabled == null ? null : disabled.toInstant(),
                rs.getString("photo_url"));
    }

    private static List<Role> parseRoles(Array array) throws SQLException {
        List<Role> roles = new ArrayList<>();
        for (Object o : (Object[]) array.getArray()) {
            // valueOf lanza una excepción con un rol desconocido: preferimos un
            // error visible a dar (o quitar) permisos por un dato corrupto.
            roles.add(Role.valueOf((String) o));
        }
        return roles;
    }
}
