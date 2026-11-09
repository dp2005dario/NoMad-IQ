// "Viajo con mi perro" (maqueta 49 "ViajoCon"): las normas para viajar con
// tu perro. Aquí solo están las cuentas y lo que se guarda (sin pantalla):
// son reglas generales que usan casi todas las aerolíneas europeas, y la
// pantalla siempre dice que cada aerolínea tiene las suyas.
import 'dart:convert';

import '../../core/settings.dart';

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

/// El nombre y la foto de tu perro. Viven SOLO en el móvil (nada se sube).
class DogProfile {
  const DogProfile({this.name, this.photoPath});

  /// null = aún no le has puesto nombre (la pantalla dice "tu perro").
  final String? name;

  /// Ruta de la foto dentro de la carpeta privada de la app.
  final String? photoPath;

  /// Como mucho 30 letras: es un nombre, no una redacción.
  static const int maxName = 30;

  /// Lee lo guardado. Datos rotos = perfil vacío (nunca falla).
  static DogProfile load(SettingsStore store) {
    try {
      final Object? raw = jsonDecode(
        store.readData(LocalData.dogProfile) ?? '{}',
      );
      if (raw is! Map<String, Object?>) return const DogProfile();
      final Object? name = raw['name'];
      final Object? photo = raw['photo'];
      return DogProfile(
        name: name is String ? cleanName(name) : null,
        photoPath: photo is String && photo.isNotEmpty ? photo : null,
      );
    } on FormatException {
      return const DogProfile();
    }
  }

  /// Quita espacios de más y corta a [maxName]. Vacío = null.
  static String? cleanName(String raw) {
    final String clean = raw.trim().split(RegExp(r'\s+')).join(' ');
    if (clean.isEmpty) return null;
    return clean.length > maxName ? clean.substring(0, maxName) : clean;
  }

  Future<void> save(SettingsStore store) => store.writeData(
    LocalData.dogProfile,
    jsonEncode(<String, String>{'name': ?name, 'photo': ?photoPath}),
  );

  DogProfile withName(String raw) =>
      DogProfile(name: cleanName(raw), photoPath: photoPath);

  DogProfile withPhoto(String? path) => DogProfile(name: name, photoPath: path);
}

/// La maleta de tu perro (como en la maqueta). Lo que ya has metido se
/// guarda SOLO en el móvil.
const List<String> dogBagItems = <String>[
  'Correa y arnés',
  'Bozal (si lo piden)',
  'Bebedero plegable',
  'Bolsas',
  'Su comida',
  'Cartilla y pasaporte',
];

class DogBag {
  const DogBag(this._store);

  final SettingsStore _store;

  /// Las cosas ya metidas (por su número en [dogBagItems]).
  Set<int> packed() {
    try {
      final Object? list = jsonDecode(
        _store.readData(LocalData.dogBag) ?? '[]',
      );
      if (list is! List<Object?>) return <int>{};
      return <int>{
        for (final Object? i in list)
          if (i is int && i >= 0 && i < dogBagItems.length) i,
      };
    } on FormatException {
      return <int>{};
    }
  }

  /// Mete o saca una cosa.
  Future<Set<int>> toggle(int item) async {
    final Set<int> all = packed();
    if (!all.remove(item) && item >= 0 && item < dogBagItems.length) {
      all.add(item);
    }
    await _store.writeData(
      LocalData.dogBag,
      jsonEncode((all.toList()..sort())),
    );
    return all;
  }
}
