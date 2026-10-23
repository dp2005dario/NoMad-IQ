package api

// Forma exacta del JSON que recibe la app. Se separa de los tipos de domain
// a propósito: podemos cambiar el modelo interno sin romper la app.

import (
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

// moneyJSON: importe en la unidad mínima (céntimos), nunca con decimales.
type moneyJSON struct {
	AmountMinor int64  `json:"amount_minor"`
	Currency    string `json:"currency"`
}

type routeJSON struct {
	RouteKey      string `json:"route_key"`
	Origin        string `json:"origin"`
	Destination   string `json:"destination"`
	DepartureDate string `json:"departure_date"`
	ReturnDate    string `json:"return_date,omitempty"`
	Cabin         string `json:"cabin"`
}

type fareJSON struct {
	routeJSON
	Price      moneyJSON `json:"price"`
	Carrier    string    `json:"carrier,omitempty"`
	BookingURL string    `json:"booking_url,omitempty"`
	ObservedAt time.Time `json:"observed_at"`
}

type dealJSON struct {
	fareJSON
	UsualMinor      int64 `json:"usual_minor"`
	DropBasisPoints int32 `json:"drop_bp"`
}

type watchJSON struct {
	routeJSON
	Target    *moneyJSON `json:"target"`
	CreatedAt time.Time  `json:"created_at"`
	Latest    *fareJSON  `json:"latest"`
}

type pointJSON struct {
	Date     string `json:"date"`
	MinMinor int64  `json:"min_minor"`
}

type alertJSON struct {
	AlertID string `json:"alert_id"`
	Type    string `json:"type"`
	routeJSON
	Reference       moneyJSON `json:"reference"`
	Current         moneyJSON `json:"current"`
	DropBasisPoints int32     `json:"drop_bp"`
	BookingURL      string    `json:"booking_url,omitempty"`
	ObservedAt      time.Time `json:"observed_at"`
}

func toRoute(s domain.RouteSpec) routeJSON {
	r := routeJSON{
		RouteKey:      s.Key(),
		Origin:        s.Origin,
		Destination:   s.Destination,
		DepartureDate: s.Departure.String(),
		Cabin:         string(s.Cabin),
	}
	if s.Return != nil {
		r.ReturnDate = s.Return.String()
	}
	return r
}

func toFare(f domain.Fare) fareJSON {
	return fareJSON{
		routeJSON:  toRoute(f.Spec),
		Price:      moneyJSON{AmountMinor: f.Price.AmountMinor, Currency: f.Price.Currency},
		Carrier:    f.CarrierIATA,
		BookingURL: safeLink(f.DeepLink),
		ObservedAt: f.ObservedAt,
	}
}

func toMoney(m *domain.Money) *moneyJSON {
	if m == nil {
		return nil
	}
	return &moneyJSON{AmountMinor: m.AmountMinor, Currency: m.Currency}
}
