// Package pseudonym calcula el seudónimo con el que se conoce a cada persona
// dentro del notifier: HMAC-SHA256(clave, user_id), igual que el geo-engine.
//
// Analogía: es como el número de una taquilla del gimnasio. El notifier
// sabe que la taquilla 4F7A tiene dos teléfonos y que hay que avisarla, pero
// no sabe de quién es; solo quien tiene la llave maestra (la clave) puede
// calcular qué taquilla corresponde a cada persona.
//
// El notifier solo calcula seudónimos en un momento: cuando un teléfono se
// registra (la petición trae el user_id ya verificado por el auth-gateway).
// Lo calcula, lo guarda y se olvida del user_id: nunca lo escribe en la base
// de datos ni en los logs.
package pseudonym

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
)

// context es la "etiqueta" que se mezcla antes del user_id (separación de
// dominios). Tiene que ser EXACTAMENTE la misma que en el geo-engine
// (services/geo-engine/src/stream/notify.rs) o los avisos no llegarían a nadie.
const context = "nomadiq/notify/recipient/v1\x00"

// Length es la longitud de un seudónimo: 32 bytes en base64url = 43 caracteres.
const Length = 43

// Pseudonymizer calcula seudónimos. No exporta la clave.
type Pseudonymizer struct {
	key []byte
}

// New crea el calculador. La clave debe tener al menos 32 bytes.
func New(key []byte) (*Pseudonymizer, error) {
	if len(key) < 32 {
		return nil, errors.New("pseudonym: la clave necesita al menos 32 bytes")
	}
	return &Pseudonymizer{key: append([]byte(nil), key...)}, nil
}

// Recipient devuelve el seudónimo de un usuario.
func (p *Pseudonymizer) Recipient(userID string) string {
	mac := hmac.New(sha256.New, p.key)
	mac.Write([]byte(context))
	mac.Write([]byte(userID))
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

// Valid dice si un texto tiene la forma de un seudónimo (43 caracteres
// base64url). No dice si pertenece a alguien: eso solo lo sabe la base de datos.
func Valid(s string) bool {
	if len(s) != Length {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < 'A' || c > 'Z') && (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '-' && c != '_' {
			return false
		}
	}
	// El último carácter solo puede llevar 4 bits útiles (43*6 = 258 bits
	// para 256): comprobarlo descarta textos que no salieron de un HMAC.
	_, err := base64.RawURLEncoding.Strict().DecodeString(s)
	return err == nil
}
