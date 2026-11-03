// Modo fácil (maqueta "Facil"): una Inicio con letras grandes y solo lo
// importante, pensada para personas mayores o para quien no se lleva bien
// con el móvil. Aquí están los datos y las cuentas, sin pantalla.
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/settings.dart';

/// ¿Está puesto el Modo fácil? Es un "avisador": cuando cambia, Inicio se
/// vuelve a dibujar sola en el modo nuevo.
class EasyMode extends ValueNotifier<bool> {
  EasyMode(this._store) : super(_store.readData(LocalData.easyMode) == '1');

  final SettingsStore _store;

  Future<void> set(bool on) async {
    value = on;
    await _store.writeData(LocalData.easyMode, on ? '1' : null);
  }
}

/// El viaje que enseña el Modo fácil. Lo puede rellenar la propia persona o
/// alguien de su familia con su móvil. Vive SOLO en este teléfono.
class EasyTrip {
  const EasyTrip({
    this.departure,
    this.from,
    this.to,
    this.gate,
    this.hotelName,
    this.hotelAddress,
    this.help,
  });

  /// Día y hora de salida del vuelo (hora del sitio de donde sales).
  final DateTime? departure;
  final String? from;
  final String? to;
  final String? gate;
  final String? hotelName;
  final String? hotelAddress;

  /// La ayuda del aeropuerto que ya pediste: 0 = silla de ruedas, 1 = que te
  /// acompañen andando, 2 = solo la maleta. null = aún no la has pedido.
  final int? help;

  /// El mismo viaje con otra ayuda pedida (o ninguna si [help] es null).
  EasyTrip withHelp(int? help) => EasyTrip(
    departure: departure,
    from: from,
    to: to,
    gate: gate,
    hotelName: hotelName,
    hotelAddress: hotelAddress,
    help: help,
  );

  bool get hasFlight => departure != null && from != null && to != null;
  bool get isEmpty => !hasFlight && hotelAddress == null;

  Map<String, Object?> toJson() => <String, Object?>{
    if (departure != null) 'departure': departure!.toIso8601String(),
    'from': ?from,
    'to': ?to,
    'gate': ?gate,
    'hotel_name': ?hotelName,
    'hotel_address': ?hotelAddress,
    'help': ?help,
  };

  static EasyTrip parse(Object? json) {
    if (json is! Map<String, Object?>) return const EasyTrip();
    String? text(String key, {int max = 200}) {
      final Object? v = json[key];
      if (v is! String) return null;
      final String s = v.trim();
      return s.isEmpty || s.length > max ? null : s;
    }

    String? iata(String key) {
      final String? v = text(key, max: 3)?.toUpperCase();
      return v != null && RegExp(r'^[A-Z]{3}$').hasMatch(v) ? v : null;
    }

    final String? dep = text('departure', max: 40);
    return EasyTrip(
      departure: dep == null ? null : DateTime.tryParse(dep),
      from: iata('from'),
      to: iata('to'),
      gate: text('gate', max: 8),
      hotelName: text('hotel_name'),
      hotelAddress: text('hotel_address', max: 300),
      help: switch (json['help']) {
        final int h when h >= 0 && h <= 2 => h,
        _ => null,
      },
    );
  }
}

EasyTrip loadEasyTrip(SettingsStore store) {
  try {
    return EasyTrip.parse(
      jsonDecode(store.readData(LocalData.easyTrip) ?? '{}'),
    );
  } on FormatException {
    return const EasyTrip();
  }
}

Future<void> saveEasyTrip(SettingsStore store, EasyTrip trip) =>
    store.writeData(
      LocalData.easyTrip,
      trip.isEmpty ? null : jsonEncode(trip.toJson()),
    );

/// Cuánto antes del vuelo hay que salir de casa: 2 horas en el aeropuerto
/// (lo que piden casi todas las aerolíneas) y 1 hora para llegar. Es un
/// consejo prudente, no una cuenta exacta del tráfico.
const Duration leaveBefore = Duration(hours: 3);

DateTime leaveHomeAt(DateTime departure) => departure.subtract(leaveBefore);

/// El enlace "llévame a esta dirección": Google Maps lo entiende en todos los
/// Android (y si no está instalado, se abre en el navegador). Es gratis y no
/// necesita ninguna clave.
/// [walking] = true: la ruta andando (el botón "Ir andando · te guío").
Uri directionsTo(String address, {bool walking = false}) =>
    Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'destination': address,
      'travelmode': walking ? 'walking' : 'transit',
    });
