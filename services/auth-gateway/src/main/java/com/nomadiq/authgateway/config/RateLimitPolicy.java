package com.nomadiq.authgateway.config;

import java.time.Duration;
import java.util.Objects;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Una regla de "límite de velocidad": como máximo {@code maxRequests}
 * peticiones dentro de cada ventana de tiempo {@code window}.
 *
 * <p>Se escribe en las variables de entorno de forma corta y legible:
 * {@code 10/1m} = 10 peticiones por minuto, {@code 5/15m} = 5 cada 15 minutos.
 *
 * <p>Es un {@code record}: una clase inmutable (no cambia después de crearse)
 * que Java nos genera con constructor, getters, equals y toString. Inmutable
 * significa que nadie puede modificarla por error a mitad de ejecución.
 */
public record RateLimitPolicy(int maxRequests, Duration window) {

    // Número, barra, número y unidad (s = segundos, m = minutos, h = horas).
    private static final Pattern FORMAT = Pattern.compile("^\\s*(\\d+)\\s*/\\s*(\\d+)([smh])\\s*$");

    /**
     * El "constructor compacto" de un record se ejecuta siempre al crearlo:
     * es el sitio perfecto para rechazar valores absurdos lo antes posible.
     */
    public RateLimitPolicy {
        Objects.requireNonNull(window, "window");
        if (maxRequests < 1) {
            throw new IllegalArgumentException("el límite debe permitir al menos 1 petición");
        }
        if (window.compareTo(Duration.ofSeconds(1)) < 0 || window.compareTo(Duration.ofDays(1)) > 0) {
            throw new IllegalArgumentException("la ventana debe estar entre 1 segundo y 24 horas");
        }
    }

    /** Convierte el texto {@code "10/1m"} en una regla. Lanza una excepción clara si el formato es incorrecto. */
    public static RateLimitPolicy parse(String text) {
        if (text == null) {
            throw new IllegalArgumentException("falta el límite (formato esperado: 10/1m)");
        }
        Matcher m = FORMAT.matcher(text);
        if (!m.matches()) {
            throw new IllegalArgumentException("límite '" + text + "' inválido (formato esperado: 10/1m, 5/15m, 100/1h)");
        }
        long amount = Long.parseLong(m.group(2));
        Duration window = switch (m.group(3)) {
            case "s" -> Duration.ofSeconds(amount);
            case "m" -> Duration.ofMinutes(amount);
            case "h" -> Duration.ofHours(amount);
            default -> throw new IllegalStateException("unidad imposible: el patrón solo admite s, m y h");
        };
        return new RateLimitPolicy(Integer.parseInt(m.group(1)), window);
    }
}
