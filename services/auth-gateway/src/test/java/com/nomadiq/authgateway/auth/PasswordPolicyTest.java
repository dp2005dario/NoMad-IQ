package com.nomadiq.authgateway.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.nomadiq.authgateway.auth.AuthExceptions.WeakPasswordException;
import org.junit.jupiter.api.Test;

/** Política de contraseñas y normalización del email. */
class PasswordPolicyTest {

    @Test
    void aceptaFrasesLargas() {
        assertThatCode(() -> AuthService.PasswordPolicy.check("caballo correcto grapa", "dario@example.com"))
                .doesNotThrowAnyException();
    }

    @Test
    void rechazaCortas() {
        assertThatThrownBy(() -> AuthService.PasswordPolicy.check("corta", "dario@example.com"))
                .isInstanceOf(WeakPasswordException.class);
    }

    @Test
    void cuentaCaracteresNoBytes() {
        // 12 emojis son 12 caracteres para una persona (aunque ocupen 24 "char" en Java).
        assertThatCode(() -> AuthService.PasswordPolicy.check("🔒".repeat(12), "dario@example.com"))
                .doesNotThrowAnyException();
        assertThatThrownBy(() -> AuthService.PasswordPolicy.check("🔒".repeat(6), "dario@example.com"))
                .isInstanceOf(WeakPasswordException.class);
    }

    @Test
    void rechazaLaQueContieneElEmail() {
        assertThatThrownBy(() -> AuthService.PasswordPolicy.check("DarioSuperSecreta", "dario@example.com"))
                .isInstanceOf(WeakPasswordException.class);
        assertThatThrownBy(() -> AuthService.PasswordPolicy.check("            ", "dario@example.com"))
                .isInstanceOf(WeakPasswordException.class);
    }

    @Test
    void normalizaEmail() {
        assertThat(AuthService.normalizeEmail("  Dario@Example.COM ")).isEqualTo("dario@example.com");
    }
}
