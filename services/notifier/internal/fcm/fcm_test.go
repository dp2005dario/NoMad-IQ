package fcm

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestSendBuildsTheV1Request(t *testing.T) {
	var got map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/v1/projects/nomadiq-dev/messages:send" {
			t.Errorf("petición inesperada: %s %s", r.Method, r.URL.Path)
		}
		body, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(body, &got)
		_, _ = w.Write([]byte(`{"name":"projects/nomadiq-dev/messages/1"}`))
	}))
	defer srv.Close()
	c, err := New(context.Background(), Config{Endpoint: srv.URL, ProjectID: "nomadiq-dev"})
	if err != nil {
		t.Fatal(err)
	}
	err = c.Send(context.Background(), Message{Token: "tok", Data: map[string]string{"v": "1", "p": "abc"}, TTL: 10 * time.Minute, CollapseKey: "nomadiq-zone"})
	if err != nil {
		t.Fatal(err)
	}
	msg := got["message"].(map[string]any)
	android := msg["android"].(map[string]any)
	if msg["token"] != "tok" || android["ttl"] != "600s" || android["priority"] != "HIGH" || android["collapse_key"] != "nomadiq-zone" {
		t.Fatalf("cuerpo inesperado: %v", got)
	}
	if _, hasNotification := msg["notification"]; hasNotification {
		t.Fatal("solo mensajes de datos: el texto lo pone la app")
	}
}

func TestErrorsAreClassified(t *testing.T) {
	now := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	fcmErr := func(code string) []byte {
		return []byte(`{"error":{"status":"X","details":[{"@type":"type.googleapis.com/google.firebase.fcm.v1.FcmError","errorCode":"` + code + `"}]}}`)
	}
	cases := []struct {
		name   string
		status int
		retry  string
		body   []byte
		kind   Kind
		after  time.Duration
	}{
		{"desinstalada", 404, "", fcmErr("UNREGISTERED"), KindUnregistered, 0},
		{"otro remitente", 403, "", fcmErr("SENDER_ID_MISMATCH"), KindUnregistered, 0},
		{"cuota", 429, "30", fcmErr("QUOTA_EXCEEDED"), KindQuota, 30 * time.Second},
		{"cuota con fecha", 429, now.Add(2 * time.Minute).Format(http.TimeFormat), nil, KindQuota, 2 * time.Minute},
		{"caída de google", 503, "", fcmErr("UNAVAILABLE"), KindRetry, 0},
		{"error interno", 500, "", []byte("<html>"), KindRetry, 0},
		{"credenciales", 401, "", nil, KindAuth, 0},
		{"mensaje inválido", 400, "", fcmErr("INVALID_ARGUMENT"), KindInvalid, 0},
		{"retry-after absurdo", 503, "999999", nil, KindRetry, time.Hour},
	}
	for _, tc := range cases {
		e := classify(tc.status, tc.retry, tc.body, now)
		if e.Kind != tc.kind || e.RetryAfter != tc.after {
			t.Errorf("%s: %s/%s, se esperaba %s/%s", tc.name, e.Kind, e.RetryAfter, tc.kind, tc.after)
		}
	}
}

func TestNetworkErrorsAreRetried(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	srv.Close() // nadie escucha: error de red
	c, err := New(context.Background(), Config{Endpoint: srv.URL, ProjectID: "nomadiq-dev", Timeout: time.Second})
	if err != nil {
		t.Fatal(err)
	}
	var e *Error
	if err := c.Send(context.Background(), Message{Token: "t"}); !errors.As(err, &e) || e.Kind != KindRetry {
		t.Fatalf("se esperaba KindRetry, llegó %v", err)
	}
}

func TestBadCredentialsAreRejectedAtStartup(t *testing.T) {
	_, err := New(context.Background(), Config{Endpoint: "https://fcm.googleapis.com", ProjectID: "p", CredentialsJSON: []byte(`{"type":"external_account"}`)})
	if err == nil {
		t.Fatal("solo se aceptan cuentas de servicio")
	}
}
