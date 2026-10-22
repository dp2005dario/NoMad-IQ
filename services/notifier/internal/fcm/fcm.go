// Package fcm envía avisos a teléfonos Android con Firebase Cloud Messaging
// (API HTTP v1). FCM es gratis: Google cobra por muchas cosas, pero no por
// entregar avisos push.
//
// Cómo funciona: cada teléfono con la app tiene un "token" (una dirección
// que Google le asigna). Nosotros le decimos a Google "entrega estos datos a
// este token" y Google lo hace llegar aunque la app esté cerrada.
//
// Qué viaja a Google: solo el token, un campo "v" con la versión y un campo
// "p" con el aviso CIFRADO para ese teléfono (ver sealbox). Google no puede
// saber de qué zona se trata ni qué dice el aviso. Es un mensaje "de datos"
// (no de notificación): la app lo descifra y muestra ella el texto, en el
// idioma del usuario y respetando sus preferencias.
//
// Lo más delicado es CLASIFICAR los errores, porque cada uno pide algo
// distinto: un teléfono que desinstaló la app (UNREGISTERED) hay que
// olvidarlo; un "vas demasiado rápido" (429) pide frenar a todos los envíos;
// un fallo puntual de Google (503) se reintenta más tarde.
package fcm

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"golang.org/x/oauth2"
	"golang.org/x/oauth2/google"
)

// Scope es el permiso mínimo que pedimos a Google: solo enviar avisos.
const Scope = "https://www.googleapis.com/auth/firebase.messaging"

// Message es un aviso de datos para un teléfono.
type Message struct {
	Token string
	Data  map[string]string
	// TTL: si el teléfono está apagado, cuánto lo guarda Google. Pasado ese
	// tiempo lo tira (un "acabas de llegar" de hace una hora no sirve).
	TTL time.Duration
	// CollapseKey: si hay varios avisos sin entregar con la misma clave,
	// Google entrega solo el último. Anti-spam extra para teléfonos que
	// vuelven a tener cobertura. Es una constante: no revela nada.
	CollapseKey string
}

// Kind clasifica un error de envío.
type Kind int

// Tipos de error.
const (
	// KindRetry: fallo temporal (red, 5xx de Google). Reintentar más tarde.
	KindRetry Kind = iota + 1
	// KindQuota: Google pide ir más despacio (429). Frenar TODOS los envíos.
	KindQuota
	// KindUnregistered: el token ya no existe (app desinstalada). Olvidar el teléfono.
	KindUnregistered
	// KindInvalid: el mensaje o el token son inválidos. No reintentar.
	KindInvalid
	// KindAuth: nuestras credenciales fallan. Reintentar (y avisar en logs).
	KindAuth
)

func (k Kind) String() string {
	switch k {
	case KindRetry:
		return "retry"
	case KindQuota:
		return "quota"
	case KindUnregistered:
		return "unregistered"
	case KindInvalid:
		return "invalid"
	case KindAuth:
		return "auth"
	default:
		return "unknown"
	}
}

// Error es un fallo de envío ya clasificado.
type Error struct {
	Kind       Kind
	Status     int    // código HTTP (0 si no hubo respuesta)
	Code       string // errorCode de FCM, si lo hubo
	RetryAfter time.Duration
	cause      error
}

func (e *Error) Error() string {
	msg := fmt.Sprintf("fcm: %s (http %d", e.Kind, e.Status)
	if e.Code != "" {
		msg += ", " + e.Code
	}
	msg += ")"
	if e.cause != nil {
		msg += ": " + e.cause.Error()
	}
	return msg
}

func (e *Error) Unwrap() error { return e.cause }

// Client habla con la API de FCM.
type Client struct {
	http   *http.Client
	sendTo string
}

// Config del cliente.
type Config struct {
	Endpoint  string // https://fcm.googleapis.com
	ProjectID string
	// CredentialsJSON es la cuenta de servicio de Google. nil = modo
	// desarrollo (FCM falso local, sin autenticación).
	CredentialsJSON []byte
	Timeout         time.Duration
}

// New crea el cliente. Con credenciales, cada petición lleva un token OAuth2
// de corta duración que la librería de Google renueva sola.
func New(ctx context.Context, cfg Config) (*Client, error) {
	base, err := url.Parse(strings.TrimSuffix(cfg.Endpoint, "/"))
	if err != nil || base.Host == "" {
		return nil, errors.New("fcm: endpoint inválido")
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 10 * time.Second
	}
	transport := http.DefaultTransport
	httpClient := &http.Client{Timeout: cfg.Timeout, Transport: transport}
	if cfg.CredentialsJSON != nil {
		// WithType: solo se acepta una cuenta de servicio, nunca otros tipos
		// de credencial que podrían hacer que la librería leyera ficheros o
		// llamara a URLs indicadas dentro del JSON.
		creds, err := google.CredentialsFromJSONWithType(ctx, cfg.CredentialsJSON, google.ServiceAccount, Scope)
		if err != nil {
			return nil, errors.New("fcm: credenciales de cuenta de servicio inválidas")
		}
		httpClient = &http.Client{
			Timeout:   cfg.Timeout,
			Transport: &oauth2.Transport{Source: creds.TokenSource, Base: transport},
		}
	}
	sendTo := base.String() + "/v1/projects/" + url.PathEscape(cfg.ProjectID) + "/messages:send"
	return &Client{http: httpClient, sendTo: sendTo}, nil
}

type androidConfig struct {
	Priority    string `json:"priority"`
	TTL         string `json:"ttl"`
	CollapseKey string `json:"collapse_key,omitempty"`
}

type wireMessage struct {
	Token   string            `json:"token"`
	Data    map[string]string `json:"data"`
	Android androidConfig     `json:"android"`
}

type sendRequest struct {
	Message wireMessage `json:"message"`
}

type errorBody struct {
	Error struct {
		Status  string `json:"status"`
		Details []struct {
			Type      string `json:"@type"`
			ErrorCode string `json:"errorCode"`
		} `json:"details"`
	} `json:"error"`
}

// Send entrega un mensaje. Devuelve nil o un *Error clasificado.
func (c *Client) Send(ctx context.Context, m Message) error {
	ttl := max(int64(m.TTL/time.Second), 1)
	body, err := json.Marshal(sendRequest{Message: wireMessage{
		Token: m.Token,
		Data:  m.Data,
		// HIGH: el aviso tiene que llegar al momento (la persona acaba de
		// llegar). La app SIEMPRE muestra algo al recibirlo, que es lo que
		// Android exige para no castigar los avisos de prioridad alta.
		Android: androidConfig{Priority: "HIGH", TTL: strconv.FormatInt(ttl, 10) + "s", CollapseKey: m.CollapseKey},
	}})
	if err != nil {
		return &Error{Kind: KindInvalid, cause: err}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.sendTo, bytes.NewReader(body))
	if err != nil {
		return &Error{Kind: KindInvalid, cause: err}
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		var retrieve *oauth2.RetrieveError
		if errors.As(err, &retrieve) {
			return &Error{Kind: KindAuth, cause: errors.New("no se pudo obtener el token OAuth2 de Google")}
		}
		// Ojo: el error de red puede incluir la URL, pero nunca el token
		// del teléfono (va en el cuerpo, no en la URL).
		return &Error{Kind: KindRetry, cause: err}
	}
	defer resp.Body.Close()
	// Se lee como mucho 64 KiB: una respuesta gigante no debe agotar la memoria.
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	return classify(resp.StatusCode, resp.Header.Get("Retry-After"), raw, time.Now())
}

func classify(status int, retryAfter string, raw []byte, now time.Time) *Error {
	var parsed errorBody
	_ = json.Unmarshal(raw, &parsed) // si no es JSON, se clasifica solo por el código HTTP
	code := ""
	for _, d := range parsed.Error.Details {
		if strings.HasSuffix(d.Type, "google.firebase.fcm.v1.FcmError") && d.ErrorCode != "" {
			code = d.ErrorCode
		}
	}
	e := &Error{Status: status, Code: code, RetryAfter: parseRetryAfter(retryAfter, now)}
	switch {
	case code == "UNREGISTERED" || code == "SENDER_ID_MISMATCH" || status == http.StatusNotFound:
		e.Kind = KindUnregistered
	case code == "QUOTA_EXCEEDED" || status == http.StatusTooManyRequests:
		e.Kind = KindQuota
	case code == "THIRD_PARTY_AUTH_ERROR" || status == http.StatusUnauthorized || status == http.StatusForbidden:
		e.Kind = KindAuth
	case code == "UNAVAILABLE" || code == "INTERNAL" || status >= 500:
		e.Kind = KindRetry
	default:
		e.Kind = KindInvalid
	}
	return e
}

// parseRetryAfter entiende las dos formas de la cabecera: segundos ("30")
// o una fecha HTTP. Se acota a 1 hora por si llegara un valor absurdo.
func parseRetryAfter(v string, now time.Time) time.Duration {
	v = strings.TrimSpace(v)
	if v == "" {
		return 0
	}
	var d time.Duration
	if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
		d = time.Duration(secs) * time.Second
	} else if t, err := http.ParseTime(v); err == nil {
		d = t.Sub(now)
	}
	return min(max(d, 0), time.Hour)
}
