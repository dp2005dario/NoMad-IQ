package com.nomadiq.authgateway.user;

/**
 * Roles del control de acceso (RBAC: Role-Based Access Control).
 *
 * <p>En vez de decidir permiso a permiso para cada persona, se agrupan los
 * permisos en roles y a cada persona se le dan roles. Un {@code enum} (lista
 * cerrada) evita errores de tipeo: "ADMNI" no compila.
 */
public enum Role {
    /** Cualquier viajero registrado. */
    USER,
    /** Personal de NomadIQ: puede desactivar cuentas y cerrar sesiones ajenas. */
    ADMIN
}
