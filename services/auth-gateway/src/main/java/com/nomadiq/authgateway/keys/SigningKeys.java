package com.nomadiq.authgateway.keys;

import java.io.IOException;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.interfaces.ECPrivateKey;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.security.spec.PKCS8EncodedKeySpec;
import java.security.spec.X509EncodedKeySpec;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.nimbusds.jose.JOSEException;
import com.nimbusds.jose.JWSAlgorithm;
import com.nimbusds.jose.jwk.Curve;
import com.nimbusds.jose.jwk.ECKey;
import com.nimbusds.jose.jwk.JWKSet;
import com.nimbusds.jose.jwk.KeyUse;
import org.bouncycastle.jce.ECNamedCurveTable;
import org.bouncycastle.jce.spec.ECNamedCurveParameterSpec;

/**
 * El "llavero" con las claves que firman y verifican los JWT.
 *
 * <p><b>Por qué claves asimétricas (ES256) y no un secreto compartido (HS256):</b>
 * con HS256 la misma contraseña firma y verifica, así que cada servicio que
 * quiera comprobar un token tendría que conocerla... y cualquiera de ellos
 * podría fabricar tokens falsos. Con ES256 hay dos piezas:
 * <ul>
 *   <li>la clave <b>privada</b> (el sello del notario) solo la tiene este servicio;</li>
 *   <li>la clave <b>pública</b> (la forma de reconocer el sello) se publica en
 *       {@code /.well-known/jwks.json} y la puede tener todo el mundo: sirve para
 *       comprobar firmas, nunca para crearlas.</li>
 * </ul>
 *
 * <p><b>Rotación sin cortes:</b> cada clave tiene un identificador ({@code kid}).
 * Para cambiar de clave: (1) generas la nueva, (2) arrancas con la nueva como
 * activa y la antigua (solo su parte pública) en {@code JWT_VERIFY_ONLY_KEY_FILES},
 * (3) cuando hayan caducado todos los tokens antiguos (15 min), quitas la antigua.
 * Nadie pierde la sesión en el proceso.
 *
 * <p>Usamos la curva P-256 (ES256): firmas pequeñas (64 bytes) y muy rápidas de
 * verificar, ideal para millones de peticiones.
 */
public final class SigningKeys {

    private static final String CURVE_NAME = "secp256r1"; // = P-256

    private final ECKey activeKey;
    private final JWKSet publicKeys;

    private SigningKeys(ECKey activeKey, List<ECKey> verifyOnlyKeys) {
        this.activeKey = activeKey;
        // El JWKS público contiene la clave activa y las antiguas, sin la parte privada.
        Map<String, ECKey> byKid = new LinkedHashMap<>();
        byKid.put(activeKey.getKeyID(), activeKey.toPublicJWK());
        for (ECKey k : verifyOnlyKeys) {
            if (byKid.putIfAbsent(k.getKeyID(), k.toPublicJWK()) != null) {
                throw new IllegalStateException("la clave " + k.getKeyID() + " está repetida en JWT_VERIFY_ONLY_KEY_FILES");
            }
        }
        this.publicKeys = new JWKSet(new ArrayList<>(byKid.values()));
    }

    /** Carga la clave activa (privada) y las antiguas (públicas) desde ficheros PEM. */
    public static SigningKeys fromFiles(Path activePrivateKeyPem, List<Path> verifyOnlyPublicKeyPems) {
        ECPrivateKey priv = readPrivateKey(activePrivateKeyPem);
        ECKey active = toJwk(derivePublicKey(priv), priv);
        List<ECKey> old = new ArrayList<>();
        for (Path p : verifyOnlyPublicKeyPems) {
            old.add(toJwk(readPublicKey(p), null));
        }
        return new SigningKeys(active, old);
    }

    /**
     * Solo desarrollo: crea una clave nueva en memoria. Al reiniciar el servicio
     * cambia, así que todos los tokens emitidos antes dejan de valer.
     */
    public static SigningKeys ephemeral() {
        try {
            KeyPairGenerator gen = KeyPairGenerator.getInstance("EC");
            gen.initialize(new ECGenParameterSpec(CURVE_NAME));
            KeyPair kp = gen.generateKeyPair();
            return new SigningKeys(toJwk((ECPublicKey) kp.getPublic(), (ECPrivateKey) kp.getPrivate()), List.of());
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("no se pudo generar la clave EC efímera", e);
        }
    }

    /** Clave con la que se firman los tokens nuevos (incluye la parte privada: no sale nunca del proceso). */
    public ECKey activeKey() {
        return activeKey;
    }

    /** Todas las claves públicas válidas: lo que se publica en el endpoint JWKS. */
    public JWKSet publicKeys() {
        return publicKeys;
    }

    // ---------------------------------------------------------------------
    // Lectura de PEM y utilidades criptográficas
    // ---------------------------------------------------------------------

    private static ECKey toJwk(ECPublicKey pub, ECPrivateKey priv) {
        requireP256(pub.getParams());
        ECKey.Builder b = new ECKey.Builder(Curve.P_256, pub)
                .keyUse(KeyUse.SIGNATURE)
                .algorithm(JWSAlgorithm.ES256);
        if (priv != null) {
            b.privateKey(priv);
        }
        try {
            // kid = huella SHA-256 de la clave pública (RFC 7638): la misma clave
            // siempre tiene el mismo kid, sin tener que inventarlo ni configurarlo.
            return b.keyIDFromThumbprint().build();
        } catch (JOSEException e) {
            throw new IllegalStateException("no se pudo calcular el kid de la clave", e);
        }
    }

    private static ECPrivateKey readPrivateKey(Path pem) {
        byte[] der = decodePem(pem, "PRIVATE KEY");
        try {
            return (ECPrivateKey) KeyFactory.getInstance("EC").generatePrivate(new PKCS8EncodedKeySpec(der));
        } catch (GeneralSecurityException | ClassCastException e) {
            throw new IllegalStateException(pem + " no es una clave privada EC en formato PKCS#8"
                    + " (genérala con: openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256)", e);
        }
    }

    private static ECPublicKey readPublicKey(Path pem) {
        byte[] der = decodePem(pem, "PUBLIC KEY");
        try {
            return (ECPublicKey) KeyFactory.getInstance("EC").generatePublic(new X509EncodedKeySpec(der));
        } catch (GeneralSecurityException | ClassCastException e) {
            throw new IllegalStateException(pem + " no es una clave pública EC (genérala con: openssl pkey -in privada.pem -pubout)", e);
        }
    }

    /**
     * La clave pública se puede calcular a partir de la privada (al revés es
     * imposible: en eso se basa la seguridad). Así basta con un fichero.
     * Cuenta: punto_publico = d × G, donde d es la clave privada y G el punto
     * generador de la curva.
     */
    private static ECPublicKey derivePublicKey(ECPrivateKey priv) {
        requireP256(priv.getParams());
        ECNamedCurveParameterSpec spec = ECNamedCurveTable.getParameterSpec(CURVE_NAME);
        org.bouncycastle.math.ec.ECPoint q = spec.getG().multiply(priv.getS()).normalize();
        ECPoint w = new ECPoint(new BigInteger(1, q.getAffineXCoord().getEncoded()),
                new BigInteger(1, q.getAffineYCoord().getEncoded()));
        try {
            return (ECPublicKey) KeyFactory.getInstance("EC").generatePublic(new ECPublicKeySpec(w, priv.getParams()));
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException("no se pudo derivar la clave pública", e);
        }
    }

    /** Rechaza otras curvas (P-384, secp256k1...): un token ES256 solo puede ir firmado con P-256. */
    private static void requireP256(ECParameterSpec params) {
        if (!Curve.P_256.equals(Curve.forECParameterSpec(params))) {
            throw new IllegalStateException("solo se admiten claves de la curva P-256 (ES256)");
        }
    }

    /** Quita las líneas -----BEGIN/END----- y decodifica el Base64 del medio. */
    private static byte[] decodePem(Path pem, String type) {
        String text;
        try {
            text = Files.readString(pem, StandardCharsets.US_ASCII);
        } catch (IOException e) {
            throw new IllegalStateException("no se puede leer el fichero de clave " + pem, e);
        }
        String begin = "-----BEGIN " + type + "-----";
        String end = "-----END " + type + "-----";
        int from = text.indexOf(begin);
        int to = text.indexOf(end);
        if (from < 0 || to < from) {
            throw new IllegalStateException(pem + " no contiene un bloque '" + begin + "'");
        }
        String base64 = text.substring(from + begin.length(), to).replaceAll("\\s", "");
        try {
            return Base64.getDecoder().decode(base64);
        } catch (IllegalArgumentException e) {
            throw new IllegalStateException(pem + " tiene Base64 inválido", e);
        }
    }
}
