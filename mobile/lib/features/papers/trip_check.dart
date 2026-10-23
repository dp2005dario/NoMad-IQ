// "Antes de salir": se revisan los papeles de la Bóveda para un viaje.
//
// Todo pasa en el móvil: la Bóveda se abre con tu huella y se miran solo
// las fechas de caducidad de tus documentos.
import '../vault/vault.dart';

/// Muchos países (Japón, Tailandia, EE. UU. para algunos...) piden que el
/// pasaporte siga valiendo 6 meses DESPUÉS de salir del país. Se usa lo
/// más exigente para no llevarse un susto en el aeropuerto.
const int passportMarginMonths = 6;

enum CheckState { ok, warning, missing }

class TripChecks {
  const TripChecks({
    required this.passport,
    required this.insurance,
    this.passportExpires,
  });

  final CheckState passport;
  final CheckState insurance;
  final DateTime? passportExpires;

  int get issues => <CheckState>[
    passport,
    insurance,
  ].where((CheckState s) => s != CheckState.ok).length;
}

TripChecks checkTrip(List<VaultDoc> docs, DateTime returnDay) {
  final DateTime needUntil = DateTime(
    returnDay.year,
    returnDay.month + passportMarginMonths,
    returnDay.day,
  );
  // De varios pasaportes (doble nacionalidad), el que más dura.
  DateTime? best;
  bool anyPassport = false;
  for (final VaultDoc d in docs) {
    if (d.kind != DocKind.passport) continue;
    anyPassport = true;
    final DateTime? e = d.expires;
    if (e != null && (best == null || e.isAfter(best))) best = e;
  }
  final CheckState passport = !anyPassport
      ? CheckState.missing
      : best == null || best.isBefore(needUntil)
      ? CheckState.warning
      : CheckState.ok;

  bool insured = false;
  bool anyInsurance = false;
  for (final VaultDoc d in docs) {
    if (d.kind != DocKind.insurance) continue;
    anyInsurance = true;
    final DateTime? e = d.expires;
    if (e == null || !e.isBefore(returnDay)) insured = true;
  }
  return TripChecks(
    passport: passport,
    insurance: insured
        ? CheckState.ok
        : anyInsurance
        ? CheckState.warning
        : CheckState.missing,
    passportExpires: best,
  );
}

/// Permisos de entrada electrónicos más comunes y su web OFICIAL (nunca
/// intermediarios que cobran de más). Si tu pasaporte lo necesita depende de
/// tu nacionalidad: la web oficial lo dice.
const Map<String, (String, String)> entryPermits = <String, (String, String)>{
  'US': ('ESTA', 'https://esta.cbp.dhs.gov/'),
  'CA': (
    'eTA',
    'https://www.canada.ca/en/immigration-refugees-citizenship/services/visit-canada/eta.html',
  ),
  'GB': (
    'ETA',
    'https://www.gov.uk/guidance/apply-for-an-electronic-travel-authorisation-eta',
  ),
  'AU': (
    'ETA',
    'https://immi.homeaffairs.gov.au/visas/getting-a-visa/visa-listing/electronic-travel-authority-601',
  ),
  'NZ': (
    'NZeTA',
    'https://www.immigration.govt.nz/new-zealand-visas/visas/visa/nzeta',
  ),
  'KR': ('K-ETA', 'https://www.k-eta.go.kr/'),
  'IN': ('e-Visa', 'https://indianvisaonline.gov.in/evisa/'),
  'LK': ('ETA', 'https://www.eta.gov.lk/'),
};
