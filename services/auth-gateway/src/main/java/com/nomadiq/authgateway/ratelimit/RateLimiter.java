package com.nomadiq.authgateway.ratelimit;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Duration;
import java.util.HexFormat;
import java.util.List;
import java.util.concurrent.TimeUnit;

import com.nomadiq.authgateway.config.RateLimitPolicy;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.RedisScript;
import org.springframework.stereotype.Component;

/**
 * Limitador de peticiones con contadores en Redis ("ventana fija").
 *
 * <p><b>Analogía:</b> el portero de una discoteca con un contador de clics por
 * cada persona. Cada minuto pone su contador a cero. Si alguien intenta entrar
 * más de 20 veces en ese minuto, le dice "espera". Un atacante que prueba
 * millones de contraseñas se queda en 20 por minuto: inútil.
 *
 * <p>¿Por qué en Redis y no en la memoria del propio servicio? Porque habrá
 * varias copias del gateway detrás del balanceador: si cada una contara por su
 * cuenta, con 10 copias el atacante tendría 10 veces más intentos. Redis es el
 * contador compartido por todas.
 *
 * <p>Las claves llevan una huella SHA-256 del identificador (la IP o el email),
 * no el dato en claro: Redis no tiene por qué guardar datos personales.
 *
 * <p>Si Redis no responde se lanza una excepción y la API devuelve 503:
 * preferimos no dejar entrar a nadie a quitar la protección contra fuerza bruta.
 */
@Component
public class RateLimiter {

    private static final String PREFIX = "nomadiq:auth:rl:";

    /**
     * Script Lua: Redis lo ejecuta de forma ATÓMICA (nadie puede colarse entre
     * medias). Suma 1 al contador; si es el primero de la ventana, le pone
     * caducidad. Devuelve {contador, milisegundos que faltan para el reinicio}.
     * Hacerlo en dos órdenes separadas podría dejar un contador sin caducidad
     * si el servicio se cae justo entre ambas: bloquearía a esa IP para siempre.
     */
    private static final RedisScript<List<Long>> INCREMENT = toListScript("""
            local count = redis.call('INCR', KEYS[1])
            if count == 1 then
              redis.call('PEXPIRE', KEYS[1], ARGV[1])
            end
            return {count, redis.call('PTTL', KEYS[1])}
            """);

    private final StringRedisTemplate redis;

    public RateLimiter(StringRedisTemplate redis) {
        this.redis = redis;
    }

    /** Cuenta una petición y lanza {@link RateLimitExceededException} si se supera el límite. */
    public void acquire(String bucket, String identifier, RateLimitPolicy policy) {
        Counter c = increment(bucket, identifier, policy);
        if (c.count() > policy.maxRequests()) {
            throw new RateLimitExceededException(bucket, c.resetIn());
        }
    }

    /** Lanza la excepción si el contador YA está en el límite, sin sumar nada (para "intentos fallidos"). */
    public void ensureNotBlocked(String bucket, String identifier, RateLimitPolicy policy) {
        String key = key(bucket, identifier);
        String value = redis.opsForValue().get(key);
        if (value != null && Long.parseLong(value) >= policy.maxRequests()) {
            Long ttlMs = redis.getExpire(key, TimeUnit.MILLISECONDS);
            throw new RateLimitExceededException(bucket, ttlMs == null || ttlMs < 0 ? policy.window() : Duration.ofMillis(ttlMs));
        }
    }

    /** Suma uno sin lanzar nada (registrar un fallo de contraseña). */
    public void record(String bucket, String identifier, RateLimitPolicy policy) {
        increment(bucket, identifier, policy);
    }

    /** Pone el contador a cero (tras un login correcto). */
    public void reset(String bucket, String identifier) {
        redis.delete(key(bucket, identifier));
    }

    private record Counter(long count, Duration resetIn) {
    }

    private Counter increment(String bucket, String identifier, RateLimitPolicy policy) {
        List<Long> result = redis.execute(INCREMENT, List.of(key(bucket, identifier)),
                Long.toString(policy.window().toMillis()));
        if (result == null || result.size() != 2) {
            throw new IllegalStateException("respuesta inesperada de Redis en el rate limiter");
        }
        long ttl = result.get(1);
        return new Counter(result.get(0), ttl > 0 ? Duration.ofMillis(ttl) : policy.window());
    }

    private static String key(String bucket, String identifier) {
        return PREFIX + bucket + ":" + sha256Hex(identifier);
    }

    static String sha256Hex(String value) {
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(value.getBytes(StandardCharsets.UTF_8));
            return HexFormat.of().formatHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 siempre existe en Java", e);
        }
    }

    @SuppressWarnings({"unchecked", "rawtypes"})
    private static RedisScript<List<Long>> toListScript(String lua) {
        // Redis devuelve una lista de enteros; Java necesita saber el tipo.
        return (RedisScript<List<Long>>) (RedisScript) RedisScript.of(lua, List.class);
    }
}
