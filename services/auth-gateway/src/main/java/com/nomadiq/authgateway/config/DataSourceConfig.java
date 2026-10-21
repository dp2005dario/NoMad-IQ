package com.nomadiq.authgateway.config;

import javax.sql.DataSource;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Crea el "pool" de conexiones a PostgreSQL.
 *
 * <p>Un pool es como una flota de taxis siempre esperando: abrir una conexión
 * nueva a la base de datos es lento (handshake TLS, autenticación...), así que
 * mantenemos unas cuantas abiertas y las reutilizamos entre peticiones.
 *
 * <p>Lo montamos a mano (en vez de dejar que Spring lo haga solo) para usar
 * las mismas variables que psql y los servicios Go ({@code PGHOST},
 * {@code PGSSLMODE}...) y para que el modo TLS quede validado por
 * {@link AuthProperties} antes de conectar.
 */
@Configuration(proxyBeanMethods = false)
public class DataSourceConfig {

    @Bean
    public DataSource dataSource(AuthProperties props) {
        AuthProperties.Database db = props.database();

        HikariConfig cfg = new HikariConfig();
        cfg.setPoolName("auth-gateway-pg");
        cfg.setJdbcUrl("jdbc:postgresql://" + db.host() + ":" + db.port() + "/" + db.name());
        cfg.setUsername(db.user());
        cfg.setPassword(db.password());
        cfg.setMaximumPoolSize(db.maxPoolSize());
        // Si en 3 segundos no hay conexión libre, fallamos rápido (la petición
        // recibe un 503) en lugar de acumular peticiones colgadas.
        cfg.setConnectionTimeout(3_000);

        // Parámetros del driver JDBC de PostgreSQL (pgjdbc).
        cfg.addDataSourceProperty("sslmode", db.sslMode());
        if (AuthProperties.isSet(db.sslRootCert())) {
            // CA concreta con la que verificar el certificado del servidor.
            cfg.addDataSourceProperty("sslrootcert", db.sslRootCert());
        } else {
            // Sin fichero propio, se confía en las CA del almacén estándar de Java.
            cfg.addDataSourceProperty("sslfactory", "org.postgresql.ssl.DefaultJavaSSLFactory");
        }
        // Nuestras tablas viven en el esquema "identity" (no en "public").
        cfg.addDataSourceProperty("currentSchema", "identity");
        // Nombre visible en pg_stat_activity: ayuda a saber quién usa cada conexión.
        cfg.addDataSourceProperty("ApplicationName", "auth-gateway");
        return new HikariDataSource(cfg);
    }
}
