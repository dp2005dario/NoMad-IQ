// Tests del proveedor simulado.

package provider

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/dp2005dario/NoMad-IQ/services/flight-ingestor/internal/domain"
)

// El precio inventado debe pasar las mismas validaciones que uno real.
func TestSimulatedQuoteIsValid(t *testing.T) {
	spec, err := domain.ParseWatchKey("MAD-NRT:2026-12-01:ECONOMY")
	if err != nil {
		t.Fatal(err)
	}
	p := NewSimulated(42, 0, 0)
	quotes, err := p.Quote(context.Background(), spec)
	if err != nil {
		t.Fatal(err)
	}
	if len(quotes) != 1 {
		t.Fatalf("se esperaba 1 precio, hay %d", len(quotes))
	}
	if err := quotes[0].Price.Validate("price"); err != nil {
		t.Fatalf("precio inválido: %v", err)
	}
}

// Con 1 s de latencia simulada y un contexto que expira a los 10 ms, Quote debe
// rendirse enseguida con DeadlineExceeded en lugar de esperar el segundo entero.
func TestSimulatedRespectsCancellation(t *testing.T) {
	spec, _ := domain.ParseWatchKey("MAD-NRT:2026-12-01:ECONOMY")
	p := NewSimulated(1, time.Second, 0)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()

	start := time.Now()
	_, err := p.Quote(ctx, spec)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("se esperaba DeadlineExceeded, error = %v", err)
	}
	if time.Since(start) > 500*time.Millisecond {
		t.Fatal("Quote no respetó la cancelación del contexto")
	}
}

// Con ErrorFareRate=1 siempre sale "tarifa error": debe costar menos de la
// mitad que el precio normal de la misma ruta (misma semilla = mismo azar).
func TestSimulatedErrorFare(t *testing.T) {
	spec, _ := domain.ParseWatchKey("MAD-NRT:2026-12-01:ECONOMY")
	normal, _ := NewSimulated(7, 0, 0).Quote(context.Background(), spec)
	cheap, _ := NewSimulated(7, 0, 1).Quote(context.Background(), spec)
	if cheap[0].Price.AmountMinor >= normal[0].Price.AmountMinor/2 {
		t.Fatalf("la tarifa error (%d) debería ser muy inferior a la normal (%d)",
			cheap[0].Price.AmountMinor, normal[0].Price.AmountMinor)
	}
}
