package com.nomadiq.authgateway.config;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Toda la configuración del servicio, con tipos estrictos y validada al arrancar.
 *
 * <p>Los valores salen de variables de entorno (ver {@code application.yaml},
 * que traduce {@code PGHOST}, {@code JWT_ISSUER}... a estos campos). Nunca hay
 * secretos escritos en el código.
 *
 * <p>Regla de oro, igual que en los servicios Go: <b>si la configuración es
 * insegura, el servicio se niega a arrancar</b>. Es mejor un error claro al
 * desplegar que descubrir meses después que el tráfico iba sin cifrar. Los
 * atajos de desarrollo existen, pero hay que pedirlos explícitamente con una
 * variable {@code *_INSECURE_DEV=true}.
 */
@ConfigurationProperties(prefix = "nomadiq")
public record AuthProperties(Http http, Database database, Redis redis, Jwt jwt, RateLimits rateLimits) {

    /** Modos de PostgreSQL que cifran pero NO comprueban la identidad del servidor (o ni cifran). */
    private static final Set<String> UNVERIFIED_PG_SSL_MODES = Set.of("disable", "allow", "prefer", "require");
    private static final Set<String> VALID_PG_SSL_MODES = Set.of("disable", "allow", "prefer", "require", "verify-ca", "verify-full");

    /**
     * Se ejecuta al crear la configuración. Junta TODOS los errores y los
     * muestra a la vez: así arreglas cinco variables de una tacada en lugar de
     * descubrirlas de una en una arrancando cinco veces.
     */
    public AuthProperties {
        List<String> errors = new ArrayList<>();
        if (http == null || database == null || redis == null || jwt == null || rateLimits == null) {
            throw new IllegalStateException("configuración incompleta: faltan secciones en application.yaml");
        }
        http.validate(errors);
        database.validate(errors);
        redis.validate(errors);
        jwt.validate(errors, http.insecureDev());
        if (!errors.isEmpty()) {
            throw new IllegalStateException("configuración inválida o insegura:\n  - " + String.join("\n  - ", errors));
        }
    }

    /** Trata "" igual que "no definido" (las variables vacías del yaml llegan como ""). */
    static boolean isSet(String value) {
        return value != null && !value.isBlank();
    }

    /**
     * HTTPS con mTLS del propio servicio.
     *
     * <p>En producción, el balanceador de carga público habla con el gateway
     * presentando su propio certificado de cliente (mTLS): ni siquiera dentro
     * de la red interna se acepta a alguien que no se identifique.
     */
    public record Http(String tlsCertFile, String tlsKeyFile, String tlsClientCaFile, boolean insecureDev) {

        public boolean tlsEnabled() {
            return isSet(tlsCertFile);
        }

        void validate(List<String> errors) {
            int set = (isSet(tlsCertFile) ? 1 : 0) + (isSet(tlsKeyFile) ? 1 : 0) + (isSet(tlsClientCaFile) ? 1 : 0);
            if (set != 0 && set != 3) {
                errors.add("mTLS: define TLS_CERT_FILE, TLS_KEY_FILE y TLS_CLIENT_CA_FILE juntas");
            } else if (set == 0 && !insecureDev) {
                errors.add("HTTP sin TLS no está permitido: configura los certificados mTLS o, solo en local, HTTP_INSECURE_DEV=true");
            } else if (set == 3 && insecureDev) {
                errors.add("HTTP_INSECURE_DEV=true contradice los certificados TLS configurados");
            }
        }
    }

    /** Conexión a PostgreSQL. Mismas variables que usa psql ({@code PGHOST}, {@code PGUSER}...). */
    public record Database(String host, int port, String user, String password, String name,
                           String sslMode, String sslRootCert, int maxPoolSize, boolean insecureDev) {

        void validate(List<String> errors) {
            if (!isSet(host) || !isSet(user) || !isSet(name)) {
                errors.add("PostgreSQL: PGHOST, PGUSER y PGDATABASE son obligatorias");
            }
            if (!isSet(password)) {
                errors.add("PostgreSQL: PGPASSWORD es obligatoria");
            }
            if (port < 1 || port > 65535) {
                errors.add("PostgreSQL: PGPORT fuera de rango");
            }
            if (maxPoolSize < 1 || maxPoolSize > 100) {
                errors.add("PostgreSQL: PG_MAX_CONNS debe estar entre 1 y 100");
            }
            String mode = sslMode == null ? "" : sslMode.toLowerCase(Locale.ROOT);
            if (!VALID_PG_SSL_MODES.contains(mode)) {
                errors.add("PostgreSQL: PGSSLMODE '" + sslMode + "' no existe");
            } else if (UNVERIFIED_PG_SSL_MODES.contains(mode) && !insecureDev) {
                errors.add("PostgreSQL: PGSSLMODE=" + mode + " no verifica al servidor; usa verify-full o, solo en local, DB_INSECURE_DEV=true");
            }
        }
    }

    /**
     * Redis (lista negra de tokens y contadores de rate limiting).
     * Host, puerto y contraseña los lee Spring directamente ({@code spring.data.redis.*});
     * aquí solo comprobamos que el cifrado no se ha desactivado por descuido.
     */
    public record Redis(boolean tls, boolean insecureDev) {

        void validate(List<String> errors) {
            if (!tls && !insecureDev) {
                errors.add("Redis sin TLS no está permitido: REDIS_TLS=true o, solo en local, REDIS_INSECURE_DEV=true");
            }
        }
    }

    /**
     * Cómo emitimos y comprobamos los JWT.
     *
     * @param issuer             quién emite el token (claim {@code iss}); los demás servicios lo comprueban
     * @param audience           para quién es el token (claim {@code aud})
     * @param accessTokenTtl     vida del token de acceso: corta (15 min) para que un robo sirva de poco
     * @param refreshTokenTtl    vida del token de refresco: larga (30 días), pero revocable y de un solo uso
     * @param activeKeyFile      clave PRIVADA EC P-256 (PEM PKCS#8) con la que se firma ahora
     * @param verifyOnlyKeyFiles claves PÚBLICAS antiguas que se siguen aceptando durante una rotación
     * @param devEphemeralKey    solo local: genera una clave en memoria (se pierde al reiniciar)
     */
    public record Jwt(String issuer, String audience, Duration accessTokenTtl, Duration refreshTokenTtl,
                      String activeKeyFile, List<String> verifyOnlyKeyFiles, boolean devEphemeralKey) {

        public Jwt {
            // Una lista vacía es más cómoda de usar que null (no hay que comprobarlo en cada sitio).
            verifyOnlyKeyFiles = verifyOnlyKeyFiles == null
                    ? List.of()
                    : verifyOnlyKeyFiles.stream().filter(AuthProperties::isSet).map(String::trim).toList();
        }

        void validate(List<String> errors, boolean devEnvironment) {
            if (!isSet(issuer)) {
                errors.add("JWT: JWT_ISSUER es obligatoria");
            }
            if (!isSet(audience)) {
                errors.add("JWT: JWT_AUDIENCE es obligatoria");
            }
            if (accessTokenTtl == null || accessTokenTtl.compareTo(Duration.ofMinutes(1)) < 0
                    || accessTokenTtl.compareTo(Duration.ofHours(1)) > 0) {
                errors.add("JWT: ACCESS_TOKEN_TTL debe estar entre 1m y 1h (recomendado 15m)");
            }
            if (refreshTokenTtl == null || accessTokenTtl == null || refreshTokenTtl.compareTo(accessTokenTtl) <= 0
                    || refreshTokenTtl.compareTo(Duration.ofDays(90)) > 0) {
                errors.add("JWT: REFRESH_TOKEN_TTL debe ser mayor que ACCESS_TOKEN_TTL y como mucho 90 días");
            }
            if (isSet(activeKeyFile) == devEphemeralKey) {
                errors.add("JWT: define JWT_ACTIVE_KEY_FILE (producción) o JWT_DEV_EPHEMERAL_KEY=true (solo local), una de las dos");
            }
            if (devEphemeralKey && !devEnvironment) {
                errors.add("JWT: JWT_DEV_EPHEMERAL_KEY=true solo se permite junto a HTTP_INSECURE_DEV=true (entorno local)");
            }
        }
    }

    /** Límites de peticiones contra fuerza bruta y abuso. */
    public record RateLimits(RateLimitPolicy loginPerIp, RateLimitPolicy registerPerIp,
                             RateLimitPolicy refreshPerIp, RateLimitPolicy loginFailuresPerAccount) {

        public RateLimits {
            if (loginPerIp == null || registerPerIp == null || refreshPerIp == null || loginFailuresPerAccount == null) {
                throw new IllegalStateException("configuración incompleta: faltan límites de RATE_LIMIT_*");
            }
        }
    }
}
