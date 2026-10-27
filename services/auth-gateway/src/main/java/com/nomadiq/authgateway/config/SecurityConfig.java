package com.nomadiq.authgateway.config;

import java.util.Map;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpMethod;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.crypto.argon2.Argon2PasswordEncoder;
import org.springframework.security.crypto.password.DelegatingPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.security.oauth2.server.resource.authentication.JwtAuthenticationConverter;
import org.springframework.security.oauth2.server.resource.authentication.JwtGrantedAuthoritiesConverter;
import org.springframework.security.web.SecurityFilterChain;

import com.nomadiq.authgateway.token.AccessTokenIssuer;

/**
 * Las reglas de seguridad HTTP: qué rutas son públicas, cuáles exigen token y
 * cuáles exigen además el rol ADMIN.
 *
 * <p>Spring Security funciona como una fila de controles en un aeropuerto
 * (la "cadena de filtros"): cada petición pasa por todos antes de llegar a
 * nuestro código. Si uno falla, la petición se rechaza ahí mismo.
 */
@Configuration(proxyBeanMethods = false)
public class SecurityConfig {

    @Bean
    public SecurityFilterChain apiSecurity(HttpSecurity http) throws Exception {
        http
                // Sin sesiones en el servidor: cada petición trae su token y se
                // valida sola (stateless). Así cualquier copia del gateway puede
                // atender cualquier petición y se escala añadiendo copias.
                .sessionManagement(s -> s.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
                // CSRF protege a webs que usan cookies. Nosotros usamos la cabecera
                // Authorization (que el navegador no envía solo), así que no aplica.
                .csrf(AbstractHttpConfigurer::disable)
                // Nada de formularios de login ni contraseñas por "Basic auth".
                .httpBasic(AbstractHttpConfigurer::disable)
                .formLogin(AbstractHttpConfigurer::disable)
                .logout(AbstractHttpConfigurer::disable)
                .authorizeHttpRequests(auth -> auth
                        // Públicas: no puedes tener token antes de hacer login.
                        .requestMatchers(HttpMethod.POST, "/v1/auth/register", "/v1/auth/login", "/v1/auth/refresh", "/v1/auth/google").permitAll()
                        .requestMatchers(HttpMethod.GET, "/.well-known/jwks.json").permitAll()
                        // Salud (puerto de gestión) y página de error interna.
                        .requestMatchers("/livez", "/readyz", "/actuator/health/**", "/error").permitAll()
                        // RBAC: solo ADMIN.
                        .requestMatchers("/v1/admin/**").hasRole("ADMIN")
                        // Todo lo demás: token válido obligatorio. Lo que no está
                        // listado arriba queda cerrado por defecto (lista blanca).
                        .anyRequest().authenticated())
                // Valida "Authorization: Bearer <jwt>" con el JwtDecoder de JwtConfig.
                .oauth2ResourceServer(o -> o.jwt(jwt -> jwt.jwtAuthenticationConverter(rolesConverter())))
                // Cabeceras de seguridad: esta API no sirve HTML, así que el navegador
                // no debe ejecutar nada ni mostrarla dentro de otra web.
                .headers(h -> h.contentSecurityPolicy(csp -> csp.policyDirectives("default-src 'none'; frame-ancestors 'none'")));
        return http.build();
    }

    /** Convierte el claim {@code roles: ["ADMIN"]} en el permiso {@code ROLE_ADMIN} que entiende Spring. */
    static JwtAuthenticationConverter rolesConverter() {
        JwtGrantedAuthoritiesConverter authorities = new JwtGrantedAuthoritiesConverter();
        authorities.setAuthoritiesClaimName(AccessTokenIssuer.ROLES_CLAIM);
        authorities.setAuthorityPrefix("ROLE_");
        JwtAuthenticationConverter converter = new JwtAuthenticationConverter();
        converter.setJwtGrantedAuthoritiesConverter(authorities);
        return converter;
    }

    /**
     * Cómo se guardan las contraseñas: Argon2id, el ganador del concurso
     * mundial de algoritmos de contraseñas (Password Hashing Competition).
     *
     * <p>Es lento y gasta memoria A PROPÓSITO (19 MiB y 2 pasadas, lo que
     * recomienda OWASP): para nosotros son unos milisegundos por login, pero a
     * un atacante que robe la base de datos le cuesta muchísimo probar
     * contraseñas, incluso con tarjetas gráficas.
     *
     * <p>El "Delegating" antepone {@code {argon2}} a cada huella. Si algún día
     * cambiamos de algoritmo, las huellas antiguas siguen funcionando y se
     * migran solas en el siguiente login de cada usuario.
     */
    @Bean
    public PasswordEncoder passwordEncoder() {
        Argon2PasswordEncoder argon2 = new Argon2PasswordEncoder(16, 32, 1, 19 * 1024, 2);
        return new DelegatingPasswordEncoder("argon2", Map.of("argon2", argon2));
    }
}
