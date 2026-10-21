package com.nomadiq.authgateway.api;

import java.util.Map;
import java.util.TreeMap;

import com.nomadiq.authgateway.auth.AuthExceptions.EmailAlreadyRegisteredException;
import com.nomadiq.authgateway.auth.AuthExceptions.InvalidCredentialsException;
import com.nomadiq.authgateway.auth.AuthExceptions.UserNotFoundException;
import com.nomadiq.authgateway.auth.AuthExceptions.WeakPasswordException;
import com.nomadiq.authgateway.ratelimit.RateLimitExceededException;
import com.nomadiq.authgateway.token.InvalidRefreshTokenException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.dao.DataAccessResourceFailureException;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.HttpStatusCode;
import org.springframework.http.ProblemDetail;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.context.request.WebRequest;
import org.springframework.web.servlet.mvc.method.annotation.ResponseEntityExceptionHandler;

/**
 * Traduce cada error a una respuesta HTTP clara con el formato estándar
 * "Problem Details" (RFC 9457), por ejemplo:
 * <pre>{"type":"about:blank","title":"Unauthorized","status":401,"detail":"Email o contraseña incorrectos"}</pre>
 *
 * <p>Regla de seguridad: el cliente recibe un mensaje útil pero genérico; los
 * detalles internos (trazas, SQL, nombres de clases) solo van al log. Una traza
 * de error en la respuesta es un mapa del tesoro para un atacante.
 */
@RestControllerAdvice
public class ApiExceptionHandler extends ResponseEntityExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(ApiExceptionHandler.class);

    @ExceptionHandler(InvalidCredentialsException.class)
    ProblemDetail invalidCredentials() {
        return ProblemDetail.forStatusAndDetail(HttpStatus.UNAUTHORIZED, "Email o contraseña incorrectos");
    }

    @ExceptionHandler(InvalidRefreshTokenException.class)
    ProblemDetail invalidRefresh(InvalidRefreshTokenException e) {
        log.info("Refresh rechazado: {}", e.getMessage());
        return ProblemDetail.forStatusAndDetail(HttpStatus.UNAUTHORIZED, "Sesión caducada: vuelve a iniciar sesión");
    }

    @ExceptionHandler(EmailAlreadyRegisteredException.class)
    ProblemDetail emailTaken() {
        return ProblemDetail.forStatusAndDetail(HttpStatus.CONFLICT, "Ya existe una cuenta con ese email");
    }

    @ExceptionHandler(WeakPasswordException.class)
    ProblemDetail weakPassword(WeakPasswordException e) {
        return ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, e.getMessage());
    }

    @ExceptionHandler(UserNotFoundException.class)
    ProblemDetail userNotFound() {
        return ProblemDetail.forStatusAndDetail(HttpStatus.NOT_FOUND, "Usuario no encontrado");
    }

    /** 429 + Retry-After en segundos (redondeado hacia arriba, mínimo 1). */
    @ExceptionHandler(RateLimitExceededException.class)
    ResponseEntity<ProblemDetail> rateLimited(RateLimitExceededException e) {
        long seconds = Math.max(1, (e.retryAfter().toMillis() + 999) / 1000);
        return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS)
                .header(HttpHeaders.RETRY_AFTER, Long.toString(seconds))
                .body(ProblemDetail.forStatusAndDetail(HttpStatus.TOO_MANY_REQUESTS,
                        "Demasiados intentos: espera " + seconds + " s"));
    }

    /** PostgreSQL o Redis caídos: 503 "vuelve a intentarlo", no un 500 misterioso. */
    @ExceptionHandler(DataAccessResourceFailureException.class)
    ProblemDetail dependencyDown(DataAccessResourceFailureException e) {
        log.error("Dependencia no disponible (PostgreSQL o Redis)", e);
        return ProblemDetail.forStatusAndDetail(HttpStatus.SERVICE_UNAVAILABLE, "Servicio no disponible temporalmente");
    }

    /** Cualquier otro error: 500 genérico y todo el detalle al log. */
    @ExceptionHandler(Exception.class)
    ProblemDetail unexpected(Exception e) {
        log.error("Error inesperado", e);
        return ProblemDetail.forStatusAndDetail(HttpStatus.INTERNAL_SERVER_ERROR, "Error interno");
    }

    /** Errores de validación (400): decimos QUÉ campo está mal, nunca qué valor llegó. */
    @Override
    protected ResponseEntity<Object> handleMethodArgumentNotValid(MethodArgumentNotValidException ex, HttpHeaders headers,
                                                                  HttpStatusCode status, WebRequest request) {
        Map<String, String> fields = new TreeMap<>();
        ex.getBindingResult().getFieldErrors()
                .forEach(f -> fields.putIfAbsent(f.getField(), f.getDefaultMessage()));
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, "Datos de entrada inválidos");
        problem.setProperty("errors", fields);
        return ResponseEntity.badRequest().headers(headers).body(problem);
    }
}
