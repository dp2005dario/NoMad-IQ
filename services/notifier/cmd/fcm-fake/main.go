// Comando fcm-fake: un Firebase Cloud Messaging FALSO para desarrollo y CI.
//
// Para probar el notifier de punta a punta sin cuenta de Google ni teléfono:
// imita la API HTTP v1 (POST /v1/projects/{p}/messages:send), guarda en
// memoria lo que recibe y deja consultarlo (GET /messages?token=...).
//
// Simula también los errores que más importan:
//   - Un token que empieza por "gone-" responde 404 UNREGISTERED (app
//     desinstalada): el notifier debe olvidar ese teléfono.
//   - Un token que empieza por "busy-" responde 429 con Retry-After: 1 la
//     primera vez y 200 después: el notifier debe frenar y reintentar.
//
// NUNCA se usa en producción: el notifier solo acepta un FCM por http con
// FCM_INSECURE_DEV=true.
package main

import (
	"encoding/json"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

type received struct {
	Token      string            `json:"token"`
	Data       map[string]string `json:"data"`
	Android    map[string]any    `json:"android"`
	ReceivedAt time.Time         `json:"received_at"`
}

type fake struct {
	mu       sync.Mutex
	messages []received
	busySeen map[string]bool
	next     int
}

const keep = 1000

func main() {
	addr := flag.String("addr", ":8099", "dirección en la que escuchar")
	healthcheck := flag.Bool("healthcheck", false, "consulta /healthz de este proceso (HEALTHCHECK del contenedor, que no tiene curl)")
	flag.Parse()
	if *healthcheck {
		client := http.Client{Timeout: 3 * time.Second}
		resp, err := client.Get("http://127.0.0.1" + *addr + "/healthz")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}
	f := &fake{busySeen: map[string]bool{}}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/projects/{project}/messages:send", f.send)
	mux.HandleFunc("GET /messages", f.list)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })
	srv := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	slog.Info("FCM falso escuchando", slog.String("addr", *addr))
	if err := srv.ListenAndServe(); err != nil {
		slog.Error("fcm-fake", slog.Any("error", err))
		os.Exit(1)
	}
}

func fcmError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{
		"code": status, "status": code,
		"details": []map[string]string{{"@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError", "errorCode": code}},
	}})
}

func (f *fake) send(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Message received `json:"message"`
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	if err := dec.Decode(&body); err != nil || body.Message.Token == "" || body.Message.Data["p"] == "" {
		fcmError(w, http.StatusBadRequest, "INVALID_ARGUMENT")
		return
	}
	token := body.Message.Token
	f.mu.Lock()
	defer f.mu.Unlock()
	switch {
	case strings.HasPrefix(token, "gone-"):
		fcmError(w, http.StatusNotFound, "UNREGISTERED")
		return
	case strings.HasPrefix(token, "busy-") && !f.busySeen[token]:
		f.busySeen[token] = true
		w.Header().Set("Retry-After", "1")
		fcmError(w, http.StatusTooManyRequests, "QUOTA_EXCEEDED")
		return
	}
	body.Message.ReceivedAt = time.Now().UTC()
	f.messages = append(f.messages, body.Message)
	if len(f.messages) > keep {
		f.messages = f.messages[len(f.messages)-keep:]
	}
	f.next++
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]string{"name": "projects/" + r.PathValue("project") + "/messages/" + strconv.Itoa(f.next)})
}

func (f *fake) list(w http.ResponseWriter, r *http.Request) {
	token := r.URL.Query().Get("token")
	f.mu.Lock()
	out := make([]received, 0)
	for _, m := range f.messages {
		if token == "" || m.Token == token {
			out = append(out, m)
		}
	}
	f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}
