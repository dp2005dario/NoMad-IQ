// Las cuentas de "Antes de salir" (sin pantalla, fácil de probar): qué pasa
// con tus datos móviles allí, qué llevar en la maleta y cuánto contamina el
// vuelo. Todo se calcula en el móvil con datos fijos que lleva la app.
import 'dart:convert';

import '../../core/settings.dart';
import '../flights/climate_api.dart';
import 'plugs.dart';

/// Cómo quedan tus datos móviles en el destino.
enum RoamingStatus {
  /// Mismo "roaming como en casa" (UE/EEE desde una tarifa europea).
  free,

  /// Fuera: conviene una eSIM o un plan de datos de viaje.
  abroad,

  /// No sabemos de qué país sales: no se dice nada.
  unknown,
}

RoamingStatus roamingFor({String? homeCountry, String? destination}) {
  if (homeCountry == null || destination == null) return RoamingStatus.unknown;
  final bool home = freeRoamingEea.contains(homeCountry.toUpperCase());
  final bool there = freeRoamingEea.contains(destination.toUpperCase());
  if (!home) return RoamingStatus.abroad;
  return there ? RoamingStatus.free : RoamingStatus.abroad;
}

/// Un apunte de la lista de la maleta: qué llevar y por qué.
class PackItem {
  const PackItem(this.id, this.kind, {this.detail = ''});

  /// Clave para recordar si ya lo has marcado (no se traduce).
  final String id;
  final PackKind kind;

  /// Un dato que va dentro del texto ("A/B", "11").
  final String detail;
}

/// Los tipos de apunte que conoce la app (el texto lo pone la pantalla, en
/// tu idioma).
enum PackKind {
  adapter, // adaptador de enchufe
  transformer, // transformador de tensión
  umbrella, // paraguas: mes lluvioso
  coat, // abrigo: mes frío
  sunscreen, // crema solar: mes de calor
  esim, // datos móviles fuera de la UE
  offline, // descargar la ciudad para usarla sin datos
  passport, // el pasaforte caduca pronto (lo dice la Bóveda)
  insurance, // sin seguro de viaje
}

/// Qué conviene meter en la maleta para ese viaje.
///
/// [homePower] y [therePower] son el enchufe de casa y el de allí; [climate]
/// es el clima medio del mes del viaje (si se sabe).
List<PackItem> packingFor({
  Power? homePower,
  Power? therePower,
  MonthClimate? climate,
  RoamingStatus roaming = RoamingStatus.unknown,
  bool passportSoon = false,
  bool noInsurance = false,
}) {
  final List<PackItem> items = <PackItem>[
    if (passportSoon) const PackItem('passport', PackKind.passport),
    if (noInsurance) const PackItem('insurance', PackKind.insurance),
  ];
  if (homePower != null && therePower != null) {
    if (therePower.needsAdapterFrom(homePower)) {
      items.add(
        PackItem('adapter', PackKind.adapter, detail: therePower.plugs),
      );
    }
    if (therePower.needsTransformerFrom(homePower)) {
      items.add(
        PackItem(
          'transformer',
          PackKind.transformer,
          detail: '${therePower.volts}',
        ),
      );
    }
  }
  if (climate != null) {
    if (climate.rainyDays >= 8) {
      items.add(
        PackItem('umbrella', PackKind.umbrella, detail: '${climate.rainyDays}'),
      );
    }
    if (climate.tempC <= 10) {
      items.add(
        PackItem('coat', PackKind.coat, detail: '${climate.tempC.round()}'),
      );
    }
    if (climate.tempMaxC >= 28) {
      items.add(
        PackItem(
          'sunscreen',
          PackKind.sunscreen,
          detail: '${climate.tempMaxC.round()}',
        ),
      );
    }
  }
  if (roaming == RoamingStatus.abroad) {
    items.add(const PackItem('esim', PackKind.esim));
  }
  items.add(const PackItem('offline', PackKind.offline));
  return items;
}

/// Lo que llevas marcado de la maleta. Vive SOLO en el móvil.
class PackList {
  const PackList(this._store);

  final SettingsStore _store;

  Set<String> done() {
    try {
      final Object? list = jsonDecode(
        _store.readData(LocalData.packing) ?? '[]',
      );
      if (list is! List<Object?>) return <String>{};
      return <String>{
        for (final Object? id in list) ?(id is String ? id : null),
      };
    } on FormatException {
      return <String>{};
    }
  }

  Future<void> setDone(String id, {required bool ready}) async {
    final Set<String> all = done();
    if (ready) {
      all.add(id);
    } else {
      all.remove(id);
    }
    await _store.writeData(LocalData.packing, jsonEncode(all.toList()));
  }
}

/// Cuánto llevas listo, de 0 a 1 (lo que enseña el círculo de arriba).
double readiness(List<PackItem> items, Set<String> done) {
  if (items.isEmpty) return 1;
  final int ready = items.where((PackItem i) => done.contains(i.id)).length;
  return ready / items.length;
}
