// Package api es la API HTTP con la que la app registra el teléfono.
//
// Seguridad Zero Trust, igual que la API del ai-orchestrator:
//
//   - Esta API NO valida tokens JWT. El proxy de borde pregunta al
//     auth-gateway si el token es bueno y nos reenvía la petición con las
//     cabeceras X-User-ID y X-User-Roles ya verificadas.
//   - Nadie de dentro de la red puede inventarse esas cabeceras: el puerto
//     exige mTLS, y solo el proxy de borde tiene un certificado válido.
//
// Privacidad: el user_id se usa UNA vez, para calcular el seudónimo, y se
// olvida. No se guarda ni se escribe en los logs.
//
// Endpoints:
//
//	PUT    /v1/devices/{device_id}  registra o renueva el teléfono (la app lo
//	                                llama al abrirse: así el token de FCM
//	                                siempre está al día)
//	DELETE /v1/devices/{device_id}  deja de recibir avisos (al cerrar sesión
//	                                o al desactivarlos en ajustes)
package api

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"regexp"
	"strings"

	"github.com/google/uuid"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

// Cabeceras que pone el proxy de borde tras validar el JWT.
const (
	HeaderUserID    = "X-User-ID"
	HeaderUserRoles = "X-User-Roles"
	requiredRole    = "USER"
	maxBodyBytes    = 8 << 10
	maxTokenLength  = 4096
)

var (
	userIDPattern = regexp.MustCompile(`^[A-Za-z0-9._:@-]{1,128}$`)
	rolePattern   = regexp.MustCompile(`^[A-Z_]{1,32}$`)
)

// Registration son los datos de un teléfono ya validados.
type Registration struct {
	DeviceID  string
	Recipient string
	Platform  string
	FCMToken  string
	PublicKey []byte
}

// ErrDeviceOwnedByOther: ese device_id ya pertenece a otra persona.
var ErrDeviceOwnedByOther = errors.New("api: el teléfono pertenece a otra cuenta")

// Registry guarda los teléfonos (store.Postgres en producción).
type Registry interface {
	RegisterDevice(ctx context.Context, r Registration) error
	DeleteDevice(ctx context.Context, recipient, deviceID string) error
}

// Pseudonymizer calcula el seudónimo de un user_id.
type Pseudonymizer interface {
	Recipient(userID string) string
}

// Handler crea el router de la API.
func Handler(registry Registry, pseudonyms Pseudonymizer, log *slog.Logger) http.Handler {
	h := &handler{registry: registry, pseudonyms: pseudonyms, log: log}
	mux := http.NewServeMux()
	mux.HandleFunc("PUT /v1/devices/{device_id}", h.register)
	mux.HandleFunc("DELETE /v1/devices/{device_id}", h.unregister)
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		problem(w, http.StatusNotFound, "no encontrado")
	})
	return mux
}

type handler struct {
	registry   Registry
	pseudonyms Pseudonymizer
	log        *slog.Logger
}

type registerBody struct {
	Platform  string `json:"platform"`
	FCMToken  string `json:"fcm_token"`
	PublicKey string `json:"public_key"` // X25519, base64url sin relleno
}

// problem responde con el formato estándar de errores RFC 9457.
func problem(w http.ResponseWriter, status int, title string) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"type": "about:blank", "title": title, "status": status})
}

// recipient comprueba la identidad y calcula el seudónimo.
func (h *handler) recipient(w http.ResponseWriter, r *http.Request) (string, bool) {
	userID := r.Header.Get(HeaderUserID)
	if !userIDPattern.MatchString(userID) {
		problem(w, http.StatusUnauthorized, "identidad ausente o inválida")
		return "", false
	}
	hasRole := false
	for _, role := range strings.Split(r.Header.Get(HeaderUserRoles), ",") {
		role = strings.TrimSpace(role)
		if role == "" {
			continue
		}
		if !rolePattern.MatchString(role) {
			problem(w, http.StatusUnauthorized, "roles inválidos")
			return "", false
		}
		hasRole = hasRole || role == requiredRole
	}
	if !hasRole {
		problem(w, http.StatusForbidden, "se necesita el rol USER")
		return "", false
	}
	return h.pseudonyms.Recipient(userID), true
}

func deviceID(w http.ResponseWriter, r *http.Request) (string, bool) {
	id, err := uuid.Parse(r.PathValue("device_id"))
	if err != nil || id.Version() != 4 {
		problem(w, http.StatusBadRequest, "device_id debe ser un UUID v4")
		return "", false
	}
	return id.String(), true
}

func validToken(t string) bool {
	if t == "" || len(t) > maxTokenLength {
		return false
	}
	for i := 0; i < len(t); i++ {
		// Los tokens de FCM son ASCII imprimible sin espacios.
		if t[i] <= ' ' || t[i] > '~' {
			return false
		}
	}
	return true
}

func (h *handler) register(w http.ResponseWriter, r *http.Request) {
	recipient, ok := h.recipient(w, r)
	if !ok {
		return
	}
	id, ok := deviceID(w, r)
	if !ok {
		return
	}
	if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		problem(w, http.StatusUnsupportedMediaType, "se esperaba application/json")
		return
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes))
	// Campos desconocidos = error: un cliente que envía de más (o se
	// equivoca de nombre) se entera en lugar de fallar en silencio.
	dec.DisallowUnknownFields()
	var body registerBody
	if err := dec.Decode(&body); err != nil || dec.Decode(&struct{}{}) != io.EOF {
		problem(w, http.StatusBadRequest, "cuerpo JSON inválido")
		return
	}
	if body.Platform != "android" {
		problem(w, http.StatusUnprocessableEntity, "platform: de momento solo android")
		return
	}
	if !validToken(body.FCMToken) {
		problem(w, http.StatusUnprocessableEntity, "fcm_token inválido")
		return
	}
	key, err := base64.RawURLEncoding.DecodeString(body.PublicKey)
	if err != nil || sealbox.CheckPublicKey(key) != nil {
		problem(w, http.StatusUnprocessableEntity, "public_key: se esperaba una clave X25519 válida en base64url")
		return
	}
	err = h.registry.RegisterDevice(r.Context(), Registration{
		DeviceID: id, Recipient: recipient, Platform: body.Platform, FCMToken: body.FCMToken, PublicKey: key,
	})
	switch {
	case errors.Is(err, ErrDeviceOwnedByOther):
		// Mismo mensaje que si existiera con otro formato: no se revela
		// a quién pertenece. La app genera un device_id nuevo por cuenta.
		problem(w, http.StatusConflict, "ese device_id ya está en uso: genera uno nuevo")
	case err != nil:
		h.log.Error("no se pudo registrar el teléfono", slog.Any("error", err))
		problem(w, http.StatusServiceUnavailable, "inténtalo de nuevo más tarde")
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

func (h *handler) unregister(w http.ResponseWriter, r *http.Request) {
	recipient, ok := h.recipient(w, r)
	if !ok {
		return
	}
	id, ok := deviceID(w, r)
	if !ok {
		return
	}
	// Idempotente: borrar algo que no existe (o que no es tuyo) también
	// responde 204. Así no se puede usar para averiguar qué ids existen.
	if err := h.registry.DeleteDevice(r.Context(), recipient, id); err != nil {
		h.log.Error("no se pudo borrar el teléfono", slog.Any("error", err))
		problem(w, http.StatusServiceUnavailable, "inténtalo de nuevo más tarde")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
