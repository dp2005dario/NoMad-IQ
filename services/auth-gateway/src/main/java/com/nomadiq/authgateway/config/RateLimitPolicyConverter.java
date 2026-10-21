package com.nomadiq.authgateway.config;

import org.springframework.boot.context.properties.ConfigurationPropertiesBinding;
import org.springframework.core.convert.converter.Converter;
import org.springframework.stereotype.Component;

/**
 * Enseña a Spring a convertir el texto de una variable de entorno
 * (por ejemplo {@code RATE_LIMIT_LOGIN_IP=10/1m}) en un {@link RateLimitPolicy}.
 *
 * <p>Sin esto, Spring no sabría cómo rellenar ese campo de la configuración.
 * {@code @ConfigurationPropertiesBinding} indica que este conversor se usa
 * justo al leer la configuración, antes de crear el resto de objetos.
 */
@Component
@ConfigurationPropertiesBinding
public class RateLimitPolicyConverter implements Converter<String, RateLimitPolicy> {

    @Override
    public RateLimitPolicy convert(String source) {
        return RateLimitPolicy.parse(source);
    }
}
