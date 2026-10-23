// Package policy decide QUÉ aviso corresponde a cada tipo de zona.
//
// Es la parte "de negocio" del notifier y no depende de nada externo, así
// que se prueba en microsegundos. Reglas:
//
//   - Centro de ciudad o zona turística → "zone_audioguide": "Estás en X,
//     ¿escuchas la audioguía?". Normal: respeta el enfriamiento anti-spam.
//   - Aeropuerto → "airport_arrival": "Bienvenido, aquí tienes tu eSIM...".
//   - Zona restringida → "zone_safety": aviso de seguridad. URGENTE: se
//     salta el enfriamiento (callar un aviso de seguridad porque hace 10
//     minutos enviamos uno de turismo sería un error), aunque tampoco se
//     repite la misma zona en el mismo día.
package policy

import (
	geov1 "github.com/dp2005dario/NoMad-IQ/gen/go/nomadiq/geo/v1"
)

// Template es el tipo de aviso. El texto lo pone la app en el idioma del
// usuario: al notifier (y a Google) solo les llega el tipo, cifrado.
type Template string

// Plantillas conocidas por la app.
const (
	TemplateZoneAudioguide Template = "zone_audioguide"
	TemplateAirportArrival Template = "airport_arrival"
	TemplateZoneSafety     Template = "zone_safety"
	// TemplateFareAlert: un vuelo que vigilas ha bajado de precio (no es de
	// zona: lo decide el price-consumer, ver intake/fares.go).
	TemplateFareAlert Template = "fare_alert"
)

// Decision es lo que hay que hacer con una entrada a zona.
type Decision struct {
	Template Template
	// Urgent se salta el enfriamiento por persona (pero no la repetición de zona).
	Urgent bool
}

// ForZone devuelve la decisión para un tipo de zona, o false si ese tipo
// no genera avisos.
func ForZone(kind geov1.ZoneKind) (Decision, bool) {
	switch kind {
	case geov1.ZoneKind_ZONE_KIND_CITY_CENTER, geov1.ZoneKind_ZONE_KIND_TOURIST_AREA:
		return Decision{Template: TemplateZoneAudioguide}, true
	case geov1.ZoneKind_ZONE_KIND_AIRPORT:
		return Decision{Template: TemplateAirportArrival}, true
	case geov1.ZoneKind_ZONE_KIND_RESTRICTED:
		return Decision{Template: TemplateZoneSafety, Urgent: true}, true
	default:
		return Decision{}, false
	}
}
