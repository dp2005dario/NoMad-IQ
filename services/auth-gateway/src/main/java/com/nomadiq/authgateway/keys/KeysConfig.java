package com.nomadiq.authgateway.keys;

import java.nio.file.Path;

import com.nomadiq.authgateway.config.AuthProperties;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Crea el llavero de claves UNA sola vez al arrancar.
 * Si un fichero de clave falta o está mal, el servicio no arranca (mejor que
 * arrancar y no poder firmar ni un token).
 */
@Configuration(proxyBeanMethods = false)
public class KeysConfig {

    private static final Logger log = LoggerFactory.getLogger(KeysConfig.class);

    @Bean
    public SigningKeys signingKeys(AuthProperties props) {
        AuthProperties.Jwt jwt = props.jwt();
        SigningKeys keys;
        if (jwt.devEphemeralKey()) {
            log.warn("JWT_DEV_EPHEMERAL_KEY=true: clave de firma en memoria; al reiniciar se invalidan todas las sesiones");
            keys = SigningKeys.ephemeral();
        } else {
            keys = SigningKeys.fromFiles(Path.of(jwt.activeKeyFile()),
                    jwt.verifyOnlyKeyFiles().stream().map(Path::of).toList());
        }
        // Registramos el kid (dato público), nunca la clave.
        log.info("Clave de firma activa: kid={} (claves publicadas en JWKS: {})",
                keys.activeKey().getKeyID(), keys.publicKeys().getKeys().size());
        return keys;
    }
}
