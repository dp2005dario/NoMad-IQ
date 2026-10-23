//go:build integration

// Package e2e prueba la capa de notificaciones de PUNTA A PUNTA contra los
// contenedores reales (geo-engine, notifier, fcm-fake, Kafka, PostgreSQL y
// Redis), haciendo de "teléfono":
//
//  1. Genera sus claves y se registra en la API del notifier.
//  2. Publica posiciones GPS en Kafka (como haría la app).
//  3. Comprueba que al FCM falso llega UN aviso, cifrado, que solo este
//     teléfono sabe abrir, y que dice la zona correcta.
//  4. Entra en otra zona enseguida: el enfriamiento anti-spam lo calla.
//  5. Un teléfono "desinstalado" (FCM responde UNREGISTERED) se olvida.
//
// Se lanza con "make up-apps" en marcha:
//
//	NOTIFIER_E2E=1 KAFKA_BROKERS=localhost:29092 go test -tags integration -count=1 ./internal/e2e/
package e2e

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/twmb/franz-go/pkg/kgo"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	commonv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/common/v1"
	flightsv1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/flights/v1"
	geov1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/geo/v1"

	"github.com/dp2005dario/NoMad-IQ/services/notifier/internal/sealbox"
)

const (
	apiURL    = "http://127.0.0.1:8089"
	fcmURL    = "http://127.0.0.1:8099"
	healthURL = "http://127.0.0.1:8090"
)

type phone struct {
	user, deviceID, token string
	priv                  []byte
}

func newPhone(t *testing.T, tokenPrefix string) phone {
	t.Helper()
	pub, priv, err := sealbox.GenerateDeviceKeys()
	if err != nil {
		t.Fatal(err)
	}
	p := phone{user: "e2e-push-" + uuid.NewString(), deviceID: uuid.NewString(), token: tokenPrefix + uuid.NewString(), priv: priv}
	body, _ := json.Marshal(map[string]string{"platform": "android", "fcm_token": p.token, "public_key": base64.RawURLEncoding.EncodeToString(pub)})
	req, _ := http.NewRequest(http.MethodPut, apiURL+"/v1/devices/"+p.deviceID, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-User-ID", p.user)
	req.Header.Set("X-User-Roles", "USER")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("registro del teléfono: HTTP %d", resp.StatusCode)
	}
	return p
}

// walk publica dos posiciones en el mismo sitio separadas 20 s (marcas del
// GPS): la histéresis del geo-engine exige 15 s dentro para confirmar la entrada.
func walk(t *testing.T, cl *kgo.Client, user string, lat, lon float64, at time.Time) {
	t.Helper()
	for _, ts := range []time.Time{at.Add(-20 * time.Second), at} {
		value, err := proto.Marshal(&geov1.UserPositionReported{
			Metadata:                 &commonv1.EventMetadata{EventId: uuid.NewString(), OccurredAt: timestamppb.New(ts), Producer: "e2e-test"},
			UserId:                   user,
			Position:                 &geov1.LatLng{Latitude: lat, Longitude: lon},
			HorizontalAccuracyMeters: 8,
			PreferredLanguage:        "es-ES",
		})
		if err != nil {
			t.Fatal(err)
		}
		if err := cl.ProduceSync(context.Background(), &kgo.Record{Topic: "geo.user-positions.v1", Key: []byte(user), Value: value}).FirstErr(); err != nil {
			t.Fatal(err)
		}
	}
}

type received struct {
	Token string            `json:"token"`
	Data  map[string]string `json:"data"`
}

func messagesFor(t *testing.T, token string) []received {
	t.Helper()
	resp, err := http.Get(fcmURL + "/messages?token=" + token)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out []received
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

func waitFor(t *testing.T, what string, timeout time.Duration, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("no ocurrió a tiempo: %s", what)
}

func senderStats(t *testing.T) map[string]float64 {
	t.Helper()
	resp, err := http.Get(healthURL + "/readyz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var body struct {
		Sender map[string]float64 `json:"sender"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	return body.Sender
}

func TestPushNotificationEndToEnd(t *testing.T) {
	if os.Getenv("NOTIFIER_E2E") == "" {
		t.Skip("NOTIFIER_E2E no definido: necesita make up-apps")
	}
	brokers := os.Getenv("KAFKA_BROKERS")
	if brokers == "" {
		brokers = "localhost:29092"
	}
	cl, err := kgo.NewClient(kgo.SeedBrokers(brokers))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()

	// --- 1-3. Llega a Sol: un aviso cifrado que solo este teléfono abre ---
	ana := newPhone(t, "e2e-tok-")
	now := time.Now()
	walk(t, cl, ana.user, 40.4168, -3.7038, now) // Puerta del Sol, dentro de madrid-centro
	waitFor(t, "el aviso de madrid-centro en el FCM falso", 60*time.Second, func() bool { return len(messagesFor(t, ana.token)) > 0 })
	msgs := messagesFor(t, ana.token)
	if len(msgs) != 1 || msgs[0].Data["v"] != "1" {
		t.Fatalf("se esperaba 1 aviso v1, llegaron %+v", msgs)
	}
	envelope, err := base64.RawURLEncoding.DecodeString(msgs[0].Data["p"])
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(envelope, []byte("madrid")) || bytes.Contains(envelope, []byte("zone")) {
		t.Fatal("Google (el FCM falso) no puede ver el contenido del aviso")
	}
	plain, err := sealbox.OpenOnDevice(ana.priv, envelope, []byte(ana.deviceID))
	if err != nil {
		t.Fatalf("el teléfono no pudo descifrar su aviso: %v", err)
	}
	var notice map[string]any
	if err := json.Unmarshal(plain, &notice); err != nil {
		t.Fatal(err)
	}
	if notice["type"] != "zone_audioguide" || notice["zone_kind"] != "CITY_CENTER" || notice["lang"] != "es" {
		t.Fatalf("aviso inesperado: %v", notice)
	}
	fmt.Printf("aviso descifrado por el teléfono: %s\n", plain)

	// --- 4. Diez segundos después, en la Sagrada Familia: enfriamiento ---
	walk(t, cl, ana.user, 41.4036, 2.1744, time.Now())
	time.Sleep(8 * time.Second)
	if n := len(messagesFor(t, ana.token)); n != 1 {
		t.Fatalf("el enfriamiento debía callar el segundo aviso: hay %d", n)
	}

	// --- 5. Un teléfono desinstalado se olvida ---
	before := senderStats(t)["Forgotten"]
	gone := newPhone(t, "gone-")
	walk(t, cl, gone.user, 40.4168, -3.7038, time.Now())
	waitFor(t, "que el notifier olvide el teléfono desinstalado", 60*time.Second, func() bool { return senderStats(t)["Forgotten"] > before })

	// Y darse de baja funciona (204, idempotente).
	req, _ := http.NewRequest(http.MethodDelete, apiURL+"/v1/devices/"+ana.deviceID, nil)
	req.Header.Set("X-User-ID", ana.user)
	req.Header.Set("X-User-Roles", "USER")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("baja: HTTP %d", resp.StatusCode)
	}
}

// TestFareAlertPushEndToEnd publica una alerta de precio en
// flights.fare-alerts.v1 (lo que haría el price-consumer) y comprueba que al
// teléfono le llega UN aviso cifrado "fare_alert", aunque Kafka la entregue dos veces.
func TestFareAlertPushEndToEnd(t *testing.T) {
	if os.Getenv("NOTIFIER_E2E") == "" {
		t.Skip("NOTIFIER_E2E no definido: necesita make up-apps")
	}
	brokers := os.Getenv("KAFKA_BROKERS")
	if brokers == "" {
		brokers = "localhost:29092"
	}
	cl, err := kgo.NewClient(kgo.SeedBrokers(brokers))
	if err != nil {
		t.Fatal(err)
	}
	defer cl.Close()

	leo := newPhone(t, "e2e-fare-")
	alertID := uuid.NewString()
	value, err := proto.Marshal(&flightsv1.FareAlertTriggered{
		Metadata:        &commonv1.EventMetadata{EventId: alertID, OccurredAt: timestamppb.Now(), Producer: "e2e-test"},
		AlertId:         alertID,
		UserId:          leo.user,
		AlertType:       flightsv1.FareAlertType_FARE_ALERT_TYPE_ERROR_FARE,
		Route:           &flightsv1.Route{OriginIata: "MAD", DestinationIata: "NRT"},
		DepartureDate:   &commonv1.Date{Year: int32(time.Now().Year() + 1), Month: 3, Day: 15},
		Cabin:           flightsv1.CabinClass_CABIN_CLASS_ECONOMY,
		ReferencePrice:  &commonv1.Money{CurrencyCode: "EUR", AmountMinor: 90000},
		CurrentPrice:    &commonv1.Money{CurrencyCode: "EUR", AmountMinor: 31500},
		DropBasisPoints: 6500,
	})
	if err != nil {
		t.Fatal(err)
	}
	rec := &kgo.Record{Topic: "flights.fare-alerts.v1", Key: []byte(leo.user), Value: value, Headers: []kgo.RecordHeader{
		{Key: "content-type", Value: []byte("application/x-protobuf")},
		{Key: "ce_type", Value: []byte("nomadiq.flights.v1.FareAlertTriggered")},
	}}
	// Dos veces, como tras un reinicio del price-consumer.
	for range 2 {
		if err := cl.ProduceSync(context.Background(), rec).FirstErr(); err != nil {
			t.Fatal(err)
		}
	}
	waitFor(t, "la alerta de precio en el FCM falso", 60*time.Second, func() bool { return len(messagesFor(t, leo.token)) > 0 })
	time.Sleep(5 * time.Second) // margen para ver si llega una segunda
	msgs := messagesFor(t, leo.token)
	if len(msgs) != 1 {
		t.Fatalf("se esperaba 1 aviso, llegaron %d", len(msgs))
	}
	envelope, err := base64.RawURLEncoding.DecodeString(msgs[0].Data["p"])
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(envelope, []byte("NRT")) || bytes.Contains(envelope, []byte(leo.user)) {
		t.Fatal("Google (el FCM falso) no puede ver la ruta ni el usuario")
	}
	plain, err := sealbox.OpenOnDevice(leo.priv, envelope, []byte(leo.deviceID))
	if err != nil {
		t.Fatalf("el teléfono no pudo descifrar su alerta: %v", err)
	}
	var notice map[string]any
	if err := json.Unmarshal(plain, &notice); err != nil {
		t.Fatal(err)
	}
	if notice["type"] != "fare_alert" || notice["alert_id"] != alertID || notice["alert_type"] != "error_fare" || notice["destination"] != "NRT" {
		t.Fatalf("alerta inesperada: %s", plain)
	}
	fmt.Printf("alerta de precio descifrada por el teléfono: %s\n", plain)
}
