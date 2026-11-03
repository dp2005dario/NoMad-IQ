// Antes de salir: el pasaporte con margen y el seguro vigente, mirando lo
// que tienes en la Bóveda.
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/trip/trip_check.dart';
import 'package:eclipta/features/vault/vault.dart';

VaultDoc doc(DocKind kind, DateTime? expires) => VaultDoc(
  id: '0' * 32,
  kind: kind,
  title: kind.name,
  mime: 'image/jpeg',
  added: DateTime(2026),
  expires: expires,
);

void main() {
  group('antes de salir', () {
    final DateTime back = DateTime(2027, 3, 20);

    test('pasaporte con 6 meses de margen y seguro vigente', () {
      final TripChecks ok = checkTrip(<VaultDoc>[
        doc(DocKind.passport, DateTime(2030)),
        doc(DocKind.insurance, DateTime(2027, 12)),
      ], back);
      expect(ok.issues, 0);
      final TripChecks bad = checkTrip(<VaultDoc>[
        doc(DocKind.passport, DateTime(2027, 6)),
        doc(DocKind.insurance, DateTime(2027, 3, 1)),
      ], back);
      expect(bad.passport, CheckState.warning);
      expect(bad.insurance, CheckState.warning);
      expect(checkTrip(<VaultDoc>[], back).passport, CheckState.missing);
      // Con dos pasaportes vale el que más dura.
      expect(
        checkTrip(<VaultDoc>[
          doc(DocKind.passport, DateTime(2027, 4)),
          doc(DocKind.passport, DateTime(2031)),
        ], back).passport,
        CheckState.ok,
      );
    });
  });
}
