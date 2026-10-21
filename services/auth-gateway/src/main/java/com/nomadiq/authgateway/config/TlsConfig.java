package com.nomadiq.authgateway.config;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.web.server.ConfigurableWebServerFactory;
import org.springframework.boot.web.server.Ssl;
import org.springframework.boot.web.server.WebServerFactoryCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Activa HTTPS con mTLS (TLS mutuo) en el puerto principal.
 *
 * <p>TLS normal: el servidor enseña su "DNI" (certificado) al cliente.
 * mTLS: <b>los dos</b> enseñan su DNI. Así, aunque alguien consiga entrar en la
 * red interna, no puede hablar con el gateway sin un certificado firmado por
 * nuestra CA. Es la base del modelo Zero Trust: "nunca confíes, verifica siempre".
 *
 * <p>Solo se aceptan conexiones TLS 1.3 (la versión moderna, sin algoritmos
 * antiguos que se puedan romper).
 */
@Configuration(proxyBeanMethods = false)
public class TlsConfig {

    private static final Logger log = LoggerFactory.getLogger(TlsConfig.class);

    @Bean
    public WebServerFactoryCustomizer<ConfigurableWebServerFactory> mtlsCustomizer(AuthProperties props) {
        return factory -> {
            AuthProperties.Http http = props.http();
            if (!http.tlsEnabled()) {
                // AuthProperties ya garantizó que esto solo ocurre con HTTP_INSECURE_DEV=true.
                log.warn("HTTP SIN TLS (HTTP_INSECURE_DEV=true): úsalo solo en tu máquina, nunca en producción");
                return;
            }
            Ssl ssl = new Ssl();
            ssl.setEnabled(true);
            // Ficheros PEM: el formato de texto que genera openssl (-----BEGIN ...-----).
            ssl.setCertificate("file:" + http.tlsCertFile());
            ssl.setCertificatePrivateKey("file:" + http.tlsKeyFile());
            ssl.setTrustCertificate("file:" + http.tlsClientCaFile());
            // NEED = el cliente está OBLIGADO a presentar un certificado válido.
            ssl.setClientAuth(Ssl.ClientAuth.NEED);
            ssl.setEnabledProtocols(new String[] {"TLSv1.3"});
            factory.setSsl(ssl);
            log.info("mTLS activo (TLS 1.3, certificado de cliente obligatorio)");
        };
    }
}
