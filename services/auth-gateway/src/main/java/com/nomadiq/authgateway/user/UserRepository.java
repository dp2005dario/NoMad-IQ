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

    private static final String COLUMNS = "id, email, password_hash, roles, created_at, disabled_at";

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

    /** Desactiva la cuenta (baneo). Devuelve false si el usuario no existe. */
    public boolean disable(UUID id, Instant now) {
        return jdbc.sql("UPDATE users SET disabled_at = COALESCE(disabled_at, :now) WHERE id = :id")
                .param("now", Timestamp.from(now))
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
                disabled == null ? null : disabled.toInstant());
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
