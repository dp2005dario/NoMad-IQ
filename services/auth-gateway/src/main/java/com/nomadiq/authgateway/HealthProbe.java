package com.nomadiq.authgateway;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/**
 * Mini-programa para el HEALTHCHECK de Docker: pregunta a {@code /livez} y
 * termina con código 0 (sano) o 1 (enfermo).
 *
 * <p>¿Por qué existe? La imagen final es "distroless": no tiene shell, ni curl,
 * ni nada más que Java (menos herramientas = menos cosas que un atacante pueda
 * usar si entra). Así que el chequeo de salud lo hacemos con el propio Java.
 * No arranca Spring: solo usa la librería estándar y tarda milisegundos.
 */
public final class HealthProbe {

    private HealthProbe() {
    }

    public static void main(String[] args) {
        String port = System.getenv().getOrDefault("MANAGEMENT_PORT", "8084");
        try {
            HttpClient client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(2)).build();
            HttpRequest request = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + "/livez"))
                    .timeout(Duration.ofSeconds(3)).GET().build();
            int status = client.send(request, HttpResponse.BodyHandlers.discarding()).statusCode();
            System.exit(status == 200 ? 0 : 1);
        } catch (Exception e) {
            System.exit(1);
        }
    }
}
