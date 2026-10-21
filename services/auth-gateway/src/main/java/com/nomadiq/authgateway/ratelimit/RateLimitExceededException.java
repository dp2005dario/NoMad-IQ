package com.nomadiq.authgateway.ratelimit;

import java.time.Duration;

/**
 * Se ha superado un límite de peticiones. La API responde 429 Too Many Requests
 * con la cabecera {@code Retry-After}: "vuelve a intentarlo dentro de N segundos".
 */
public class RateLimitExceededException extends RuntimeException {

    private static final long serialVersionUID = 1L;

    private final transient Duration retryAfter;

    public RateLimitExceededException(String bucket, Duration retryAfter) {
        super("límite superado: " + bucket);
        this.retryAfter = retryAfter;
    }

    public Duration retryAfter() {
        return retryAfter;
    }
}
