package com.nomadiq.authgateway;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

/**
 * Punto de entrada del auth-gateway: la "puerta de seguridad" de NomadIQ.
 *
 * <p>Qué hace este servicio, en una frase: comprueba quién eres (registro y
 * login), te entrega una "pulsera" firmada (el JWT) y, en cada petición
 * posterior, mira esa pulsera para decir a los demás servicios quién eres y
 * qué roles tienes.
 *
 * <p>{@code @SpringBootApplication} activa tres cosas a la vez:
 * <ul>
 *   <li>busca nuestras clases anotadas (@Configuration, @RestController,
 *       @Service...) dentro de este paquete y sus subpaquetes;</li>
 *   <li>autoconfiguración: Spring ve qué librerías hay en el pom.xml y monta
 *       por nosotros el servidor web, el pool de conexiones, Redis, etc.;</li>
 *   <li>permite declarar beans (objetos que Spring crea y reparte).</li>
 * </ul>
 *
 * <p>{@code @ConfigurationPropertiesScan} busca los records anotados con
 * {@code @ConfigurationProperties} (nuestra configuración tipada).
 */
@SpringBootApplication
@ConfigurationPropertiesScan
public class AuthGatewayApplication {

    public static void main(String[] args) {
        SpringApplication.run(AuthGatewayApplication.class, args);
    }
}
