package com.nomadiq.authgateway.config;

import java.time.Clock;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * El reloj del servicio, como un objeto más que se puede sustituir.
 *
 * <p>¿Por qué no llamar a {@code Instant.now()} directamente? Porque así, en
 * los tests, podemos usar un reloj falso y comprobar sin esperar 15 minutos
 * reales qué pasa cuando un token caduca.
 */
@Configuration(proxyBeanMethods = false)
public class ClockConfig {

    @Bean
    public Clock clock() {
        return Clock.systemUTC();
    }
}
