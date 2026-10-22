package policy

import (
	"testing"

	geov1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/geo/v1"
)

func TestEveryZoneKindHasADecision(t *testing.T) {
	want := map[geov1.ZoneKind]Decision{
		geov1.ZoneKind_ZONE_KIND_CITY_CENTER:  {Template: TemplateZoneAudioguide},
		geov1.ZoneKind_ZONE_KIND_TOURIST_AREA: {Template: TemplateZoneAudioguide},
		geov1.ZoneKind_ZONE_KIND_AIRPORT:      {Template: TemplateAirportArrival},
		geov1.ZoneKind_ZONE_KIND_RESTRICTED:   {Template: TemplateZoneSafety, Urgent: true},
	}
	// Si alguien añade un tipo de zona nuevo al proto, este test obliga a
	// decidir qué aviso le toca (en lugar de olvidarlo en silencio).
	for value, name := range geov1.ZoneKind_name {
		kind := geov1.ZoneKind(value)
		got, ok := ForZone(kind)
		if kind == geov1.ZoneKind_ZONE_KIND_UNSPECIFIED {
			if ok {
				t.Errorf("%s no debería generar avisos", name)
			}
			continue
		}
		if !ok || got != want[kind] {
			t.Errorf("%s: ForZone = %+v, %v; se esperaba %+v", name, got, ok, want[kind])
		}
	}
}
