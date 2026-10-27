package com.nomadiq.authgateway.user;

import java.time.Instant;
import java.util.List;
import java.util.Objects;
import java.util.UUID;

/**
 * Un usuario tal como está guardado en la base de datos.
 *
 * <p>{@code passwordHash} es la huella Argon2id de la contraseña. Este objeto
 * nunca se devuelve tal cual en la API (ver {@code UserResponse}), para que la
 * huella no salga del servicio ni por accidente.
 */
public record UserAccount(UUID id, String email, String passwordHash, List<Role> roles,
                          Instant createdAt, Instant disabledAt, String photoUrl) {

    public UserAccount {
        Objects.requireNonNull(id, "id");
        Objects.requireNonNull(email, "email");
        Objects.requireNonNull(passwordHash, "passwordHash");
        Objects.requireNonNull(createdAt, "createdAt");
        roles = List.copyOf(roles); // copia inmutable: nadie puede añadir ADMIN por la puerta de atrás
    }

    public boolean isDisabled() {
        return disabledAt != null;
    }

    /** Evita que la huella de la contraseña aparezca en un log si alguien imprime el objeto. */
    @Override
    public String toString() {
        return "UserAccount[id=" + id + ", roles=" + roles + ", disabled=" + isDisabled() + "]";
    }
}
