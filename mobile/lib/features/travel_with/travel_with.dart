// "Viajo con…" (maqueta "ViajoCon"): las normas para viajar con tu mascota o
// estando embarazada. Aquí solo están las cuentas (sin pantalla): son reglas
// generales que usan casi todas las aerolíneas europeas, y la pantalla
// siempre dice que cada aerolínea tiene las suyas.
import 'dart:convert';

import '../../core/settings.dart';

// --- Embarazo ----------------------------------------------------------------

/// Lo que suelen decir las aerolíneas según las semanas de embarazo.
enum PregnancyVerdict {
  /// Hasta la semana 28 no suelen pedir nada.
  fly,

  /// De la 28 a la 36 (32 si son gemelos) piden un certificado médico.
  certificate,

  /// Desde la 36 (32 con gemelos) la mayoría no dejan embarcar.
  dontFly,
}

/// Semana a partir de la que hace falta el certificado.
const int certificateFromWeek = 28;

/// Semana a partir de la que casi ninguna aerolínea deja volar.
int noFlyFromWeek({required bool twins}) => twins ? 32 : 36;

/// El veredicto para las semanas que tendrás el día del vuelo de VUELTA (es
/// el que cuenta: si a la vuelta ya no te dejan, el viaje no sirve).
PregnancyVerdict pregnancyVerdict(int weeks, {bool twins = false}) {
  if (weeks >= noFlyFromWeek(twins: twins)) return PregnancyVerdict.dontFly;
  if (weeks >= certificateFromWeek) return PregnancyVerdict.certificate;
  return PregnancyVerdict.fly;
}

// --- Mascota -----------------------------------------------------------------

/// Peso máximo en cabina, contando el transportín. Es lo más habitual en
/// Europa (algunas aerolíneas dejan 10 kg y otras ninguno: la pantalla lo
/// dice).
const double cabinMaxKg = 8;

/// Dónde viajaría tu mascota.
enum PetPlace {
  /// Contigo, en su transportín debajo del asiento.
  cabin,

  /// En la bodega (o como carga): hace falta reservarlo aparte.
  hold,
}

PetPlace petPlace({required double petKg, required double carrierKg}) =>
    petKg + carrierKg <= cabinMaxKg ? PetPlace.cabin : PetPlace.hold;

/// La vacuna de la rabia vale para viajar a partir de 21 días después de
/// ponerla (la primera vez).
const int rabiesWaitDays = 21;

/// ¿Estará la vacuna lista el día del vuelo?
bool rabiesReady({required DateTime vaccinated, required DateTime flight}) =>
    !flight.isBefore(vaccinated.add(const Duration(days: rabiesWaitDays)));

/// Lo que hace falta para viajar con un perro, gato o hurón por la UE.
enum PetCheck {
  microchip, // puesto ANTES de la vacuna
  rabies, // vacuna de la rabia en vigor
  passport, // pasaporte europeo para animales (lo da el veterinario)
}

/// Las casillas que ya has marcado. Viven SOLO en el móvil.
class PetChecks {
  const PetChecks(this._store);

  final SettingsStore _store;

  Set<PetCheck> done() {
    try {
      final Object? list = jsonDecode(
        _store.readData(LocalData.petChecks) ?? '[]',
      );
      if (list is! List<Object?>) return <PetCheck>{};
      return <PetCheck>{
        for (final PetCheck c in PetCheck.values)
          if (list.contains(c.name)) c,
      };
    } on FormatException {
      return <PetCheck>{};
    }
  }

  Future<void> set(PetCheck check, {required bool ready}) async {
    final Set<PetCheck> all = done();
    if (ready) {
      all.add(check);
    } else {
      all.remove(check);
    }
    await _store.writeData(
      LocalData.petChecks,
      jsonEncode(<String>[for (final PetCheck c in all) c.name]),
    );
  }
}
