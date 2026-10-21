package com.nomadiq.authgateway.keys;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.spec.ECGenParameterSpec;
import java.util.Base64;
import java.util.List;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/** Carga de claves PEM, kid automático, rotación y que nunca se publique la parte privada. */
class SigningKeysTest {

    @TempDir
    Path dir;

    /** Genera un par de claves EC y lo guarda como lo haría openssl. */
    static KeyPair writeKeyPair(Path dir, String name, String curve) throws Exception {
        KeyPairGenerator gen = KeyPairGenerator.getInstance("EC");
        gen.initialize(new ECGenParameterSpec(curve));
        KeyPair kp = gen.generateKeyPair();
        Files.writeString(dir.resolve(name + ".pem"), pem("PRIVATE KEY", kp.getPrivate().getEncoded()));
        Files.writeString(dir.resolve(name + ".pub.pem"), pem("PUBLIC KEY", kp.getPublic().getEncoded()));
        return kp;
    }

    static String pem(String type, byte[] der) {
        return "-----BEGIN " + type + "-----\n"
                + Base64.getMimeEncoder(64, "\n".getBytes()).encodeToString(der)
                + "\n-----END " + type + "-----\n";
    }

    @Test
    void cargaClaveActivaYDerivaLaPublica() throws Exception {
        KeyPair kp = writeKeyPair(dir, "active", "secp256r1");
        SigningKeys keys = SigningKeys.fromFiles(dir.resolve("active.pem"), List.of());

        // La pública calculada desde la privada coincide con la real.
        assertThat(keys.activeKey().toECPublicKey().getW()).isEqualTo(((java.security.interfaces.ECPublicKey) kp.getPublic()).getW());
        assertThat(keys.activeKey().isPrivate()).isTrue();
        assertThat(keys.publicKeys().getKeys()).hasSize(1);
    }

    @Test
    void elKidEsEstableParaLaMismaClave() throws Exception {
        writeKeyPair(dir, "active", "secp256r1");
        String kid1 = SigningKeys.fromFiles(dir.resolve("active.pem"), List.of()).activeKey().getKeyID();
        String kid2 = SigningKeys.fromFiles(dir.resolve("active.pem"), List.of()).activeKey().getKeyID();
        assertThat(kid1).isEqualTo(kid2).isNotBlank();
    }

    @Test
    void publicaClavesAntiguasParaLaRotacionYNuncaLaParteSecreta() throws Exception {
        writeKeyPair(dir, "active", "secp256r1");
        writeKeyPair(dir, "old", "secp256r1");
        SigningKeys keys = SigningKeys.fromFiles(dir.resolve("active.pem"), List.of(dir.resolve("old.pub.pem")));

        assertThat(keys.publicKeys().getKeys()).hasSize(2);
        assertThat(keys.publicKeys().getKeys()).allMatch(k -> !k.isPrivate());
        // "d" es el nombre de la parte privada en una JWK EC: no debe aparecer.
        assertThat(keys.publicKeys().toString(true)).doesNotContain("\"d\"");
    }

    @Test
    void rechazaOtrasCurvas() throws Exception {
        writeKeyPair(dir, "p384", "secp384r1");
        assertThatThrownBy(() -> SigningKeys.fromFiles(dir.resolve("p384.pem"), List.of()))
                .hasMessageContaining("P-256");
    }

    @Test
    void rechazaFicherosQueNoSonClaves() throws Exception {
        Files.writeString(dir.resolve("basura.pem"), "hola");
        assertThatThrownBy(() -> SigningKeys.fromFiles(dir.resolve("basura.pem"), List.of()))
                .hasMessageContaining("BEGIN PRIVATE KEY");
        assertThatThrownBy(() -> SigningKeys.fromFiles(dir.resolve("no-existe.pem"), List.of()))
                .hasMessageContaining("no se puede leer");
    }

    @Test
    void rechazaClaveAntiguaRepetida() throws Exception {
        writeKeyPair(dir, "active", "secp256r1");
        assertThatThrownBy(() -> SigningKeys.fromFiles(dir.resolve("active.pem"), List.of(dir.resolve("active.pub.pem"))))
                .hasMessageContaining("repetida");
    }
}
