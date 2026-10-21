package com.nomadiq.authgateway.token;

import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;

import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * La "lista negra" de tokens de acceso revocados, guardada en Redis.
 *
 * <p><b>El problema:</b> un JWT es como una entrada de concierto impresa: vale
 * hasta su fecha de caducidad aunque la persona se haya ido a casa. Si alguien
 * cierra sesión, o le roban el móvil, o le baneamos, queremos poder anular su
 * entrada antes de que caduque.
 *
 * <p><b>La solución:</b> dos tipos de anotación en Redis, que caducan solas
 * (TTL) justo cuando el token habría caducado de todos modos, así la lista
 * nunca crece sin control:
 * <ul>
 *   <li>{@code ...:jti:<id>}: "este token concreto ya no vale" (logout);</li>
 *   <li>{@code ...:all}: "todos los tokens de este usuario emitidos antes de
 *       este instante ya no valen" (baneo, o "cerrar sesión en todos los dispositivos").</li>
 * </ul>
 *
 * <p>Consultar Redis es una operación de memoria de menos de un milisegundo, y
 * se hace con UNA sola ida y vuelta ({@code MGET}) por petición. Las llaves
 * {@code {userId}} hacen que, en un Redis Cluster, las dos claves de un mismo
 * usuario caigan en el mismo nodo (si no, MGET fallaría en un clúster).
 */
@Component
public class RevocationStore {

    private static final String PREFIX = "nomadiq:auth:revoked:";

    private final StringRedisTemplate redis;
    private final Clock clock;

    public RevocationStore(StringRedisTemplate redis, Clock clock) {
        this.redis = redis;
        this.clock = clock;
    }

    /** Anula un token concreto hasta su caducidad ({@code expiresAt}). */
    public void revokeToken(UUID userId, String tokenId, Instant expiresAt) {
        Duration ttl = Duration.between(clock.instant(), expiresAt);
        if (ttl.isNegative() || ttl.isZero()) {
            return; // ya ha caducado: no hace falta apuntarlo
        }
        redis.opsForValue().set(tokenKey(userId, tokenId), "1", ttl);
    }

    /**
     * Anula todos los tokens del usuario emitidos hasta ahora. La anotación dura
     * lo mismo que un token de acceso: pasado ese tiempo, los antiguos ya han
     * caducado y no hace falta recordarla.
     */
    public void revokeAllIssuedBefore(UUID userId, Instant cutoff, Duration accessTokenTtl) {
        // + 1 minuto de margen por la tolerancia de reloj que aceptamos al validar "exp".
        redis.opsForValue().set(allKey(userId), Long.toString(cutoff.getEpochSecond()), accessTokenTtl.plusMinutes(1));
    }

    /** ¿Está anulado este token? Una sola consulta a Redis. */
    public boolean isRevoked(UUID userId, String tokenId, Instant issuedAt) {
        List<String> values = redis.opsForValue().multiGet(List.of(tokenKey(userId, tokenId), allKey(userId)));
        if (values == null || values.size() != 2) {
            // No debería pasar nunca; si pasa, por seguridad lo tratamos como revocado.
            return true;
        }
        if (values.get(0) != null) {
            return true;
        }
        String cutoff = values.get(1);
        // iat se guarda en segundos: "<=" anula también los emitidos en el mismo segundo (opción prudente).
        return cutoff != null && issuedAt.getEpochSecond() <= Long.parseLong(cutoff);
    }

    private static String tokenKey(UUID userId, String tokenId) {
        return PREFIX + "{" + userId + "}:jti:" + tokenId;
    }

    private static String allKey(UUID userId) {
        return PREFIX + "{" + userId + "}:all";
    }
}
