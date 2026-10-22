package pseudonym

import (
	"strings"
	"testing"
)

// Misma clave (00 01 02 ... 1f) y mismo resultado que el test del geo-engine
// (seudonimo_estable_y_compatible_con_el_notifier): si Go y Rust dejaran de
// calcular igual, este test o el suyo fallaría.
func TestRecipientMatchesTheGeoEngine(t *testing.T) {
	key := make([]byte, 32)
	for i := range key {
		key[i] = byte(i)
	}
	p, err := New(key)
	if err != nil {
		t.Fatal(err)
	}
	got := p.Recipient("ana")
	if want := "L3EwJq7E81uOwDP3QpkOd8aLg_sQhE63kbas17KB9rk"; got != want {
		t.Fatalf("Recipient(ana) = %s, se esperaba %s", got, want)
	}
	if !Valid(got) {
		t.Fatal("un seudónimo recién calculado debe ser válido")
	}
	if p.Recipient("anb") == got {
		t.Fatal("dos personas distintas no pueden compartir seudónimo")
	}
}

func TestShortKeysAndMalformedRecipientsAreRejected(t *testing.T) {
	if _, err := New(make([]byte, 16)); err == nil {
		t.Fatal("una clave de 16 bytes debe rechazarse")
	}
	for _, bad := range []string{"", "abc", strings.Repeat("A", 42), strings.Repeat("A", 44), strings.Repeat("+", 43), strings.Repeat("A", 42) + "B"} {
		if Valid(bad) {
			t.Errorf("Valid(%q) debería ser false", bad)
		}
	}
}
