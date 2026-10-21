package detector

import (
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

// Reglas usadas en todos los tests: 5 precios mínimos, bajada 20 %, error 50 %.
var rules = Rules{MinSamples: 5, DropBasisPoints: 2000, ErrorFareBasisPoints: 5000}

// Historial típico: la mediana es 50000 (500,00 €).
var history = []int64{48000, 52000, 50000, 49000, 51000}

func obs(amount int64) domain.Observation {
	return domain.Observation{
		EventID:     "0192f0a0-0000-7000-8000-000000000001",
		Origin:      "MAD",
		Destination: "NRT",
		Departure:   domain.Date{Year: 2026, Month: time.December, Day: 1},
		Cabin:       domain.CabinEconomy,
		Price:       domain.Money{Currency: "EUR", AmountMinor: amount},
		Provider:    "simulated",
		ObservedAt:  time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC),
	}
}

func sub(user string, target *domain.Money) domain.Subscription {
	return domain.Subscription{UserID: user, RouteKey: "MAD-NRT:2026-12-01:ECONOMY", Target: target}
}

func TestMedian(t *testing.T) {
	cases := []struct {
		in   []int64
		want int64
	}{
		{nil, 0},
		{[]int64{7}, 7},
		{[]int64{3, 1, 2}, 2},
		{[]int64{4, 1, 3, 2}, 2}, // (2+3)/2 = 2 en enteros
		{[]int64{100, 100, 1}, 100},
	}
	for _, c := range cases {
		if got := Median(c.in); got != c.want {
			t.Errorf("Median(%v) = %d, quería %d", c.in, got, c.want)
		}
	}
	// La mediana no debe reordenar el slice original.
	in := []int64{3, 1, 2}
	Median(in)
	if in[0] != 3 || in[1] != 1 || in[2] != 2 {
		t.Errorf("Median modificó su entrada: %v", in)
	}
}

func TestDropBasisPoints(t *testing.T) {
	cases := []struct {
		ref, cur int64
		want     int32
	}{
		{50000, 40000, 2000},     // 20 %
		{50000, 15000, 7000},     // 70 %
		{50000, 50000, 0},        // igual
		{50000, 60000, 0},        // sube: no es bajada
		{0, 100, 0},              // referencia inválida
		{50000, 0, 10000},        // gratis = 100 %
		{3, 2, 3333},             // redondeo hacia abajo
		{1 << 62, 1 << 61, 5000}, // números enormes sin desbordar
	}
	for _, c := range cases {
		if got := DropBasisPoints(c.ref, c.cur); got != c.want {
			t.Errorf("DropBasisPoints(%d, %d) = %d, quería %d", c.ref, c.cur, got, c.want)
		}
	}
}

func TestRulesValidate(t *testing.T) {
	if err := rules.Validate(); err != nil {
		t.Fatalf("reglas válidas rechazadas: %v", err)
	}
	bad := []Rules{
		{MinSamples: 0, DropBasisPoints: 2000, ErrorFareBasisPoints: 5000},
		{MinSamples: 5, DropBasisPoints: 0, ErrorFareBasisPoints: 5000},
		{MinSamples: 5, DropBasisPoints: 5000, ErrorFareBasisPoints: 5000}, // error debe ser > bajada
		{MinSamples: 5, DropBasisPoints: 2000, ErrorFareBasisPoints: 10001},
	}
	for _, r := range bad {
		if err := r.Validate(); err == nil {
			t.Errorf("Validate(%+v) debería fallar", r)
		}
	}
}

func TestEvaluate(t *testing.T) {
	target := &domain.Money{Currency: "EUR", AmountMinor: 45000}
	cases := []struct {
		name       string
		price      int64
		history    []int64
		subs       []domain.Subscription
		recent     map[string]int64
		wantType   domain.AlertType // "" = sin alerta
		wantRef    int64
		wantDropBP int32
		wantSignal domain.AlertType
	}{
		{name: "precio normal no alerta", price: 49000, history: history,
			subs: []domain.Subscription{sub("ana", nil)}},
		{name: "bajada del 20 % exacto", price: 40000, history: history,
			subs: []domain.Subscription{sub("ana", nil)}, wantType: domain.AlertPriceDrop,
			wantRef: 50000, wantDropBP: 2000, wantSignal: domain.AlertPriceDrop},
		{name: "bajada del 19,98 % no llega", price: 40010, history: history,
			subs: []domain.Subscription{sub("ana", nil)}},
		{name: "tarifa error", price: 15000, history: history,
			subs: []domain.Subscription{sub("ana", nil)}, wantType: domain.AlertErrorFare,
			wantRef: 50000, wantDropBP: 7000, wantSignal: domain.AlertErrorFare},
		{name: "tarifa error gana al objetivo", price: 15000, history: history,
			subs: []domain.Subscription{sub("ana", target)}, wantType: domain.AlertErrorFare,
			wantRef: 50000, wantDropBP: 7000, wantSignal: domain.AlertErrorFare},
		{name: "objetivo alcanzado sin bajada de mercado", price: 45000, history: history,
			subs: []domain.Subscription{sub("ana", target)}, wantType: domain.AlertTargetReached,
			wantRef: 45000, wantDropBP: 0},
		{name: "objetivo gana a bajada normal", price: 40000, history: history,
			subs: []domain.Subscription{sub("ana", target)}, wantType: domain.AlertTargetReached,
			wantRef: 45000, wantDropBP: 1111, wantSignal: domain.AlertPriceDrop},
		{name: "objetivo en otra divisa se ignora", price: 30000, history: nil,
			subs: []domain.Subscription{sub("ana", &domain.Money{Currency: "USD", AmountMinor: 45000})}},
		{name: "sin historial suficiente no se juzga el mercado", price: 1000, history: history[:4],
			subs: []domain.Subscription{sub("ana", nil)}},
		{name: "sin historial el objetivo sí funciona", price: 30000, history: nil,
			subs: []domain.Subscription{sub("ana", target)}, wantType: domain.AlertTargetReached,
			wantRef: 45000, wantDropBP: 3333},
		{name: "anti-spam: mismo precio ya avisado", price: 15000, history: history,
			subs: []domain.Subscription{sub("ana", nil)}, recent: map[string]int64{"ana": 15000},
			wantSignal: domain.AlertErrorFare},
		{name: "anti-spam: precio aún mejor sí avisa", price: 14000, history: history,
			subs: []domain.Subscription{sub("ana", nil)}, recent: map[string]int64{"ana": 15000},
			wantType: domain.AlertErrorFare, wantRef: 50000, wantDropBP: 7200, wantSignal: domain.AlertErrorFare},
		{name: "chollo sin suscriptores: análisis sí, alertas no", price: 15000, history: history,
			wantSignal: domain.AlertErrorFare},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			alerts, market := rules.Evaluate(Input{
				Observation: obs(c.price), History: c.history, Subscriptions: c.subs, RecentlyAlerted: c.recent,
			})
			if market.Signal != c.wantSignal {
				t.Errorf("señal de mercado = %q, quería %q", market.Signal, c.wantSignal)
			}
			if c.wantType == "" {
				if len(alerts) != 0 {
					t.Fatalf("no esperaba alertas, obtuve %+v", alerts)
				}
				return
			}
			if len(alerts) != 1 {
				t.Fatalf("esperaba 1 alerta, obtuve %d", len(alerts))
			}
			a := alerts[0]
			if a.Type != c.wantType || a.Reference.AmountMinor != c.wantRef || a.DropBasisPoints != c.wantDropBP {
				t.Errorf("alerta = {%s ref=%d drop=%d}, quería {%s ref=%d drop=%d}",
					a.Type, a.Reference.AmountMinor, a.DropBasisPoints, c.wantType, c.wantRef, c.wantDropBP)
			}
			if a.RouteKey != "MAD-NRT:2026-12-01:ECONOMY" || a.UserID != "ana" || a.Current.AmountMinor != c.price {
				t.Errorf("datos de la alerta incorrectos: %+v", a)
			}
		})
	}
}

func TestEvaluateOneAlertPerUserAndDeterministicIDs(t *testing.T) {
	in := Input{Observation: obs(15000), History: history,
		Subscriptions: []domain.Subscription{sub("ana", nil), sub("luis", nil)}}
	first, _ := rules.Evaluate(in)
	second, _ := rules.Evaluate(in)
	if len(first) != 2 {
		t.Fatalf("esperaba una alerta por usuario (2), obtuve %d", len(first))
	}
	if first[0].ID == first[1].ID {
		t.Error("dos usuarios no pueden compartir ID de alerta")
	}
	for i := range first {
		if first[i].ID != second[i].ID {
			t.Errorf("el ID debe ser determinista: %s != %s", first[i].ID, second[i].ID)
		}
	}
}
