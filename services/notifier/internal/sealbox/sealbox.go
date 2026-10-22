// Package sealbox cifra lo que el notifier guarda o envía.
//
// Dos usos, dos herramientas estándar:
//
//  1. El CONTENIDO de cada aviso (qué zona, qué plantilla) se cifra para el
//     teléfono de destino con HPKE (RFC 9180, "Hybrid Public Key
//     Encryption"), la misma familia que usan los avisos web (Web Push) y
//     la mensajería moderna. Cada teléfono genera un par de claves al
//     instalarse la app y nos da solo la PÚBLICA. Analogía: nos entrega un
//     candado abierto; metemos el mensaje en una caja, cerramos el candado y
//     solo él tiene la llave. Ni Google (FCM), ni quien lea la base de datos,
//     ni el propio notifier pasado un segundo pueden leer el aviso.
//     Suite: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 y AES-256-GCM.
//
//  2. El TOKEN de FCM de cada teléfono (la "dirección" a la que Google
//     entrega) se guarda cifrado con AES-256-GCM y una clave del servicio,
//     y además con un "índice ciego" (HMAC) para detectar el mismo teléfono
//     registrado dos veces sin guardar el token en claro.
//
// No inventamos criptografía: HPKE lo implementa la librería CIRCL de
// Cloudflare (auditada), y AES-GCM, HKDF y HMAC vienen en la librería
// estándar de Go. Aquí solo se combinan las piezas y se fijan los parámetros.
package sealbox

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"

	"github.com/cloudflare/circl/hpke"
)

// PublicKeySize es el tamaño de una clave pública X25519.
const PublicKeySize = 32

// pushInfo identifica el uso de HPKE (se mezcla en la derivación de claves):
// un mensaje cifrado para otra cosa nunca se podría hacer pasar por un aviso.
var pushInfo = []byte("nomadiq push v1")

var (
	kem   = hpke.KEM_X25519_HKDF_SHA256
	suite = hpke.NewSuite(hpke.KEM_X25519_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES256GCM)
)

// ErrInvalidPublicKey: la clave pública del teléfono no sirve.
var ErrInvalidPublicKey = errors.New("sealbox: clave pública inválida")

// ErrOpen: el mensaje no se pudo descifrar (clave equivocada o manipulado).
var ErrOpen = errors.New("sealbox: no se pudo descifrar")

// SealForDevice cifra un aviso para un teléfono. aad ("datos asociados") no
// se cifra pero queda "atado" al mensaje: usamos el device_id, así un aviso
// copiado de un teléfono a otro no se puede descifrar ni aunque fuese suyo.
// Devuelve enc (32 bytes) seguido del texto cifrado.
func SealForDevice(publicKey, plaintext, aad []byte) ([]byte, error) {
	return seal(rand.Reader, pushInfo, publicKey, plaintext, aad)
}

func seal(rnd io.Reader, info, publicKey, plaintext, aad []byte) ([]byte, error) {
	if len(publicKey) != PublicKeySize {
		return nil, ErrInvalidPublicKey
	}
	pk, err := kem.Scheme().UnmarshalBinaryPublicKey(publicKey)
	if err != nil {
		return nil, ErrInvalidPublicKey
	}
	sender, err := suite.NewSender(pk, info)
	if err != nil {
		return nil, fmt.Errorf("sealbox: %w", err)
	}
	// Setup crea una clave efímera nueva para CADA mensaje y la tira: ni
	// nosotros podemos volver a abrir un aviso ya enviado. (Si se robara la
	// clave PRIVADA del teléfono, sí se podrían abrir sus avisos antiguos: por
	// eso la app estrena par de claves cada vez que se registra.)
	// Con claves "débiles" (puntos de orden bajo de X25519) falla aquí.
	enc, sealer, err := sender.Setup(rnd)
	if err != nil {
		return nil, ErrInvalidPublicKey
	}
	ct, err := sealer.Seal(plaintext, aad)
	if err != nil {
		return nil, fmt.Errorf("sealbox: cifrar: %w", err)
	}
	return append(enc, ct...), nil
}

// CheckPublicKey comprueba una clave pública cifrando un mensaje de prueba:
// se usa al registrar un teléfono para rechazar claves inservibles en ese
// momento, y no más tarde cuando ya no hay nadie a quien avisar del error.
func CheckPublicKey(publicKey []byte) error {
	_, err := SealForDevice(publicKey, []byte("probe"), nil)
	return err
}

// OpenOnDevice descifra un aviso con la clave PRIVADA del teléfono. En
// producción esto lo hace la app; aquí lo usan los tests y la herramienta
// notifyctl (para comprobar a mano lo que llega).
func OpenOnDevice(privateKey, envelope, aad []byte) ([]byte, error) {
	return open(pushInfo, privateKey, envelope, aad)
}

func open(info, privateKey, envelope, aad []byte) ([]byte, error) {
	encSize := kem.Scheme().CiphertextSize()
	if len(envelope) <= encSize {
		return nil, ErrOpen
	}
	sk, err := kem.Scheme().UnmarshalBinaryPrivateKey(privateKey)
	if err != nil {
		return nil, ErrOpen
	}
	receiver, err := suite.NewReceiver(sk, info)
	if err != nil {
		return nil, ErrOpen
	}
	opener, err := receiver.Setup(envelope[:encSize])
	if err != nil {
		return nil, ErrOpen
	}
	pt, err := opener.Open(envelope[encSize:], aad)
	if err != nil {
		return nil, ErrOpen
	}
	return pt, nil
}

// GenerateDeviceKeys crea un par de claves como el que genera la app
// (público, privado). Solo para tests y para notifyctl.
func GenerateDeviceKeys() (publicKey, privateKey []byte, err error) {
	pk, sk, err := kem.Scheme().GenerateKeyPair()
	if err != nil {
		return nil, nil, fmt.Errorf("sealbox: generar claves: %w", err)
	}
	if publicKey, err = pk.MarshalBinary(); err != nil {
		return nil, nil, fmt.Errorf("sealbox: %w", err)
	}
	if privateKey, err = sk.MarshalBinary(); err != nil {
		return nil, nil, fmt.Errorf("sealbox: %w", err)
	}
	return publicKey, privateKey, nil
}

// Vault cifra y descifra los tokens de FCM guardados en la base de datos.
type Vault struct {
	aead     cipher.AEAD
	indexKey []byte
	spamKey  []byte
}

// NewVault deriva, de UNA clave maestra, tres subclaves independientes con
// HKDF (una "fábrica de claves"): una para cifrar tokens, otra para el
// índice ciego y otra para los nombres de las claves anti-spam de Redis.
// Así cada subclave solo sirve para lo suyo.
func NewVault(master []byte) (*Vault, error) {
	if len(master) < 32 {
		return nil, errors.New("sealbox: la clave maestra necesita al menos 32 bytes")
	}
	derive := func(label string) ([]byte, error) {
		return hkdf.Key(sha256.New, master, nil, "nomadiq/notifier/"+label, 32)
	}
	encKey, err := derive("token-encryption/v1")
	if err != nil {
		return nil, fmt.Errorf("sealbox: %w", err)
	}
	indexKey, err := derive("token-index/v1")
	if err != nil {
		return nil, fmt.Errorf("sealbox: %w", err)
	}
	spamKey, err := derive("antispam-keys/v1")
	if err != nil {
		return nil, fmt.Errorf("sealbox: %w", err)
	}
	block, err := aes.NewCipher(encKey)
	if err != nil {
		return nil, fmt.Errorf("sealbox: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("sealbox: %w", err)
	}
	return &Vault{aead: aead, indexKey: indexKey, spamKey: spamKey}, nil
}

func tokenAAD(deviceID string) []byte { return []byte("fcm-token:" + deviceID) }

// EncryptToken cifra un token. El "nonce" (número de un solo uso) es
// aleatorio y va delante del texto cifrado. El device_id va como dato
// asociado: copiar el token cifrado a la fila de otro teléfono no funciona.
func (v *Vault) EncryptToken(deviceID, token string) ([]byte, error) {
	nonce := make([]byte, v.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("sealbox: %w", err)
	}
	return v.aead.Seal(nonce, nonce, []byte(token), tokenAAD(deviceID)), nil
}

// DecryptToken hace lo contrario.
func (v *Vault) DecryptToken(deviceID string, sealed []byte) (string, error) {
	n := v.aead.NonceSize()
	if len(sealed) < n+v.aead.Overhead() {
		return "", ErrOpen
	}
	pt, err := v.aead.Open(nil, sealed[:n], sealed[n:], tokenAAD(deviceID))
	if err != nil {
		return "", ErrOpen
	}
	return string(pt), nil
}

// TokenIndex es el "índice ciego" de un token: siempre igual para el mismo
// token, imposible de revertir sin la clave.
func (v *Vault) TokenIndex(token string) []byte {
	mac := hmac.New(sha256.New, v.indexKey)
	mac.Write([]byte(token))
	return mac.Sum(nil)
}

// SpamKey da un nombre opaco para una clave de Redis. En Redis no queda
// "el seudónimo X estuvo en la zona Y", sino un número que solo el notifier
// puede recalcular.
func (v *Vault) SpamKey(parts ...string) []byte {
	mac := hmac.New(sha256.New, v.spamKey)
	for _, p := range parts {
		mac.Write([]byte(p))
		mac.Write([]byte{0})
	}
	return mac.Sum(nil)[:16]
}
