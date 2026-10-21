package com.nomadiq.authgateway.keys;

import java.time.Duration;
import java.util.Map;

import org.springframework.http.CacheControl;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Publica las claves PÚBLICAS en formato estándar JWKS (JSON Web Key Set, RFC 7517).
 *
 * <p>Cualquier servicio (en Go, Rust, Python...) que quiera verificar nuestros
 * tokens descarga este JSON una vez, lo guarda en memoria y a partir de ahí
 * comprueba las firmas <b>sin preguntarnos nada</b> en cada petición: por eso
 * el gateway no se convierte en un cuello de botella.
 *
 * <p>La respuesta se puede cachear 5 minutos. Ese tiempo también marca cuánto
 * hay que esperar, durante una rotación, entre publicar una clave nueva y
 * empezar a firmar con ella (ver la guía).
 */
@RestController
public class JwksController {

    private final SigningKeys keys;

    public JwksController(SigningKeys keys) {
        this.keys = keys;
    }

    @GetMapping(path = "/.well-known/jwks.json", produces = "application/jwk-set+json")
    public ResponseEntity<Map<String, Object>> jwks() {
        // toJSONObject() de un JWKSet público nunca incluye la parte privada ("d").
        return ResponseEntity.ok()
                .cacheControl(CacheControl.maxAge(Duration.ofMinutes(5)).cachePublic())
                .body(keys.publicKeys().toJSONObject(true));
    }
}
