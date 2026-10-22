package api

import (
	"context"
	"encoding/base64"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

type fakeRegistry struct {
	devices map[string]Registration
	err     error
}

func (f *fakeRegistry) RegisterDevice(_ context.Context, r Registration) error {
	if f.err != nil {
		return f.err
	}
	if old, ok := f.devices[r.DeviceID]; ok && old.Recipient != r.Recipient {
		return ErrDeviceOwnedByOther
	}
	f.devices[r.DeviceID] = r
	return nil
}

func (f *fakeRegistry) DeleteDevice(_ context.Context, recipient, id string) error {
	if f.devices[id].Recipient == recipient {
		delete(f.devices, id)
	}
	return nil
}

type prefix struct{}

func (prefix) Recipient(u string) string { return "seudo-" + u }

const deviceA = "/v1/devices/3b241101-e2bb-4255-8caf-4136c566a962"

func call(t *testing.T, h http.Handler, method, path, user, roles, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if user != "" {
		req.Header.Set(HeaderUserID, user)
	}
	if roles != "" {
		req.Header.Set(HeaderUserRoles, roles)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

func validBody(t *testing.T) string {
	t.Helper()
	pub, _, err := sealbox.GenerateDeviceKeys()
	if err != nil {
		t.Fatal(err)
	}
	return `{"platform":"android","fcm_token":"tok:123","public_key":"` + base64.RawURLEncoding.EncodeToString(pub) + `"}`
}

func TestRegisterStoresOnlyThePseudonym(t *testing.T) {
	reg := &fakeRegistry{devices: map[string]Registration{}}
	h := Handler(reg, prefix{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if rec := call(t, h, http.MethodPut, deviceA, "ana", "USER", validBody(t)); rec.Code != http.StatusNoContent {
		t.Fatalf("registro: %d %s", rec.Code, rec.Body)
	}
	got := reg.devices["3b241101-e2bb-4255-8caf-4136c566a962"]
	if got.Recipient != "seudo-ana" || got.FCMToken != "tok:123" || len(got.PublicKey) != 32 {
		t.Fatalf("registro guardado: %+v", got)
	}
	// Otra persona no puede quedarse con ese device_id.
	if rec := call(t, h, http.MethodPut, deviceA, "eva", "USER", validBody(t)); rec.Code != http.StatusConflict {
		t.Fatalf("secuestro de device_id: %d", rec.Code)
	}
	// Ni borrarlo: responde 204 (no revela nada) pero no lo borra.
	if rec := call(t, h, http.MethodDelete, deviceA, "eva", "USER", ""); rec.Code != http.StatusNoContent || len(reg.devices) != 1 {
		t.Fatalf("borrado ajeno: %d, %d", rec.Code, len(reg.devices))
	}
	if rec := call(t, h, http.MethodDelete, deviceA, "ana", "USER", ""); rec.Code != http.StatusNoContent || len(reg.devices) != 0 {
		t.Fatalf("borrado propio: %d, %d", rec.Code, len(reg.devices))
	}
}

func TestIdentityAndInputAreValidated(t *testing.T) {
	reg := &fakeRegistry{devices: map[string]Registration{}}
	h := Handler(reg, prefix{}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	body := validBody(t)
	cases := []struct {
		name, path, user, roles, body string
		want                          int
	}{
		{"sin identidad", deviceA, "", "USER", body, 401},
		{"sin rol", deviceA, "ana", "ADMIN", body, 403},
		{"rol raro", deviceA, "ana", "user", body, 401},
		{"id no uuid", "/v1/devices/abc", "ana", "USER", body, 400},
		{"uuid v1", "/v1/devices/a8098c1a-f86e-11da-bd1a-00112444be1e", "ana", "USER", body, 400},
		{"campo de más", deviceA, "ana", "USER", strings.Replace(body, `"platform"`, `"x":1,"platform"`, 1), 400},
		{"ios", deviceA, "ana", "USER", strings.Replace(body, "android", "ios", 1), 422},
		{"token con espacios", deviceA, "ana", "USER", strings.Replace(body, "tok:123", "tok 123", 1), 422},
		{"clave débil", deviceA, "ana", "USER", `{"platform":"android","fcm_token":"t","public_key":"` + base64.RawURLEncoding.EncodeToString(make([]byte, 32)) + `"}`, 422},
		{"dos JSON", deviceA, "ana", "USER", body + body, 400},
	}
	for _, tc := range cases {
		if rec := call(t, h, http.MethodPut, tc.path, tc.user, tc.roles, tc.body); rec.Code != tc.want {
			t.Errorf("%s: %d, se esperaba %d (%s)", tc.name, rec.Code, tc.want, rec.Body)
		}
	}
	if len(reg.devices) != 0 {
		t.Fatal("ninguna de esas peticiones debía registrar nada")
	}
	reg.err = errors.New("postgres caído")
	if rec := call(t, h, http.MethodPut, deviceA, "ana", "USER", body); rec.Code != 503 || strings.Contains(rec.Body.String(), "postgres") {
		t.Fatalf("error interno: %d %s", rec.Code, rec.Body)
	}
}
