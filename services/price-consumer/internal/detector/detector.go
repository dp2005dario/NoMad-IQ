// Package detector es el "cerebro sniper": decide si un precio es un chollo.
//
// Es una función pura: recibe datos y devuelve alertas, sin leer la base de
// datos ni Kafka. Eso la hace fácil de entender, de probar y de explicar en
// una entrevista ("dado este historial y este precio, ¿qué alerta sale?").
//
// La regla (sencilla a propósito, se puede sofisticar más adelante):
//
//  1. Precio de referencia = MEDIANA de los últimos precios de la ruta.
//     ¿Por qué mediana y no media? Si ayer hubo una tarifa error de 50 €
//     entre precios de 500 €, la media baja mucho y "esconde" la siguiente
//     oportunidad; la mediana apenas se mueve. Es robusta a valores raros.
//  2. Bajada = (referencia - actual) / referencia, en puntos básicos
//     (1 % = 100 pb). Enteros, nunca float, como con el dinero.
//  3. Bajada >= umbral de tarifa error (p. ej. 50 %)  -> ERROR_FARE.
//     Bajada >= umbral de bajada (p. ej. 20 %)         -> PRICE_DROP.
//     Precio <= objetivo del usuario                   -> TARGET_REACHED.
//     Si se cumplen varias, gana la más urgente: ERROR_FARE > TARGET_REACHED > PRICE_DROP.
//  4. Sin historial suficiente (p. ej. menos de 5 precios) no se juzga el
//     mercado: no sabemos qué es "barato" todavía. El objetivo sí se aplica.
//  5. Anti-spam: si ya avisamos a ese usuario de esa ruta hace poco con un
//     precio igual o mejor, no repetimos la alerta.
package detector

import (
	"errors"
	"fmt"
	"slices"

	"github.com/google/uuid"

	"github.com/dp2005dario/NoMad-IQ/services/price-consumer/internal/domain"
)

// Rules son los umbrales configurables del detector.
type Rules struct {
	// MinSamples: precios previos necesarios para fiarse de la referencia.
	MinSamples int
	// DropBasisPoints: bajada mínima para PRICE_DROP (2000 = 20 %).
	DropBasisPoints int32
	// ErrorFareBasisPoints: bajada mínima para ERROR_FARE (5000 = 50 %).
	ErrorFareBasisPoints int32
}

// Validate impide arrancar con umbrales sin sentido.
func (r Rules) Validate() error {
	var errs []error
	if r.MinSamples < 1 {
		errs = append(errs, fmt.Errorf("MinSamples debe ser >= 1, es %d", r.MinSamples))
	}
	if r.DropBasisPoints < 1 || r.DropBasisPoints > 10_000 {
		errs = append(errs, fmt.Errorf("DropBasisPoints debe estar entre 1 y 10000, es %d", r.DropBasisPoints))
	}
	if r.ErrorFareBasisPoints <= r.DropBasisPoints || r.ErrorFareBasisPoints > 10_000 {
		errs = append(errs, fmt.Errorf("ErrorFareBasisPoints (%d) debe ser mayor que DropBasisPoints (%d) y como mucho 10000",
			r.ErrorFareBasisPoints, r.DropBasisPoints))
	}
	return errors.Join(errs...)
}

// Input es todo lo que el detector necesita para decidir.
type Input struct {
	Observation domain.Observation
	// History: importes previos de la MISMA ruta y divisa (en cualquier orden).
	History []int64
	// Subscriptions: usuarios que vigilan esta ruta.
	Subscriptions []domain.Subscription
	// RecentlyAlerted: por usuario, el precio más bajo del que ya se le avisó
	// dentro del periodo anti-spam.
	RecentlyAlerted map[string]int64
}

// Market resume cómo está el precio actual frente al historial. Se devuelve
// también para poder registrarlo en los logs aunque nadie esté suscrito.
type Market struct {
	HasBaseline     bool
	Baseline        int64            // mediana del historial (0 si no hay)
	DropBasisPoints int32            // bajada frente a la mediana (0 si sube o no hay)
	Signal          domain.AlertType // "" si no es chollo de mercado
}

// alertNamespace es una "semilla" fija para generar IDs de alerta
// deterministas (UUID v5). Mismo evento + mismo usuario = mismo ID siempre,
// así un reprocesado no crea alertas nuevas: la base de datos lo detecta.
var alertNamespace = uuid.MustParse("6f1c9a52-7d0e-4a8e-9a43-2b6f0f3c1d77")

// AlertID calcula el ID determinista de la alerta de un usuario para un evento.
func AlertID(eventID, userID string) string {
	return uuid.NewSHA1(alertNamespace, []byte(eventID+"|"+userID)).String()
}

// AnalyzeMarket compara el precio actual con la mediana del historial.
func (r Rules) AnalyzeMarket(current int64, history []int64) Market {
	if len(history) < r.MinSamples || len(history) == 0 {
		return Market{}
	}
	baseline := Median(history)
	m := Market{HasBaseline: true, Baseline: baseline, DropBasisPoints: DropBasisPoints(baseline, current)}
	switch {
	case m.DropBasisPoints >= r.ErrorFareBasisPoints:
		m.Signal = domain.AlertErrorFare
	case m.DropBasisPoints >= r.DropBasisPoints:
		m.Signal = domain.AlertPriceDrop
	}
	return m
}

// Evaluate devuelve las alertas (como mucho una por usuario) y el análisis
// de mercado. No tiene efectos secundarios.
func (r Rules) Evaluate(in Input) ([]domain.Alert, Market) {
	obs := in.Observation
	current := obs.Price.AmountMinor
	market := r.AnalyzeMarket(current, in.History)

	var alerts []domain.Alert
	for _, sub := range in.Subscriptions {
		alertType, reference, drop, ok := r.decide(obs.Price, market, sub)
		if !ok {
			continue
		}
		// Anti-spam: solo se repite si el precio MEJORA lo ya avisado.
		if last, seen := in.RecentlyAlerted[sub.UserID]; seen && current >= last {
			continue
		}
		alerts = append(alerts, domain.Alert{
			ID:              AlertID(obs.EventID, sub.UserID),
			EventID:         obs.EventID,
			UserID:          sub.UserID,
			RouteKey:        obs.RouteKey(),
			Type:            alertType,
			Reference:       domain.Money{Currency: obs.Price.Currency, AmountMinor: reference},
			Current:         obs.Price,
			DropBasisPoints: drop,
			ObservedAt:      obs.ObservedAt,
		})
	}
	return alerts, market
}

// decide elige el tipo de alerta para una suscripción según la prioridad.
func (r Rules) decide(price domain.Money, market Market, sub domain.Subscription) (domain.AlertType, int64, int32, bool) {
	if market.Signal == domain.AlertErrorFare {
		return domain.AlertErrorFare, market.Baseline, market.DropBasisPoints, true
	}
	// El objetivo solo se compara si está en la misma divisa: comparar
	// 450 EUR con 450 USD sería un error silencioso.
	if t := sub.Target; t != nil && t.Currency == price.Currency && price.AmountMinor <= t.AmountMinor {
		return domain.AlertTargetReached, t.AmountMinor, DropBasisPoints(t.AmountMinor, price.AmountMinor), true
	}
	if market.Signal == domain.AlertPriceDrop {
		return domain.AlertPriceDrop, market.Baseline, market.DropBasisPoints, true
	}
	return "", 0, 0, false
}

// Median devuelve la mediana (con varios valores centrales, la media entera
// de los dos del medio). No modifica el slice recibido.
func Median(values []int64) int64 {
	if len(values) == 0 {
		return 0
	}
	sorted := slices.Clone(values) // copia: no tocar los datos de quien llama
	slices.Sort(sorted)
	mid := len(sorted) / 2
	if len(sorted)%2 == 1 {
		return sorted[mid]
	}
	// a + (b-a)/2 en vez de (a+b)/2: evita desbordar int64 con números enormes.
	return sorted[mid-1] + (sorted[mid]-sorted[mid-1])/2
}

// DropBasisPoints calcula cuánto más barato es current que reference, en
// puntos básicos (0..10000). Si current no es más barato, devuelve 0.
func DropBasisPoints(reference, current int64) int32 {
	if reference <= 0 || current >= reference {
		return 0
	}
	if current < 0 {
		current = 0
	}
	// Se divide antes de multiplicar cuando hay riesgo de desbordamiento.
	diff := reference - current
	var bp int64
	if diff > (1<<63-1)/10_000 {
		bp = diff / (reference / 10_000)
	} else {
		bp = diff * 10_000 / reference
	}
	return int32(min(bp, 10_000))
}
