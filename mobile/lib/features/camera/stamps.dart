// Los sellos del Pasaporte: cada monumento que reconoces con la cámara te
// da un sello con la fecha. Se guardan SOLO en el móvil.
import 'dart:convert';

import '../../core/settings.dart';

class Stamp {
  const Stamp({
    required this.qid,
    required this.name,
    required this.date,
    this.lat,
    this.lon,
    this.year,
    this.description,
  });

  final String qid;
  final String name;
  final DateTime date;

  /// Dónde está el monumento (para la página del país y "Ver en el mapa").
  /// Los sellos antiguos no lo tienen: van a "Otros lugares".
  final double? lat;
  final double? lon;

  /// Año de construcción: decide lo rara que es la carta.
  final int? year;

  /// Una frase sobre el monumento ("catedral gótica de Burgos").
  final String? description;

  Map<String, Object?> toJson() => <String, Object?>{
    'qid': qid,
    'name': name,
    'date': date.toUtc().toIso8601String(),
    if (lat != null) 'lat': lat,
    if (lon != null) 'lon': lon,
    if (year != null) 'year': year,
    if (description != null) 'description': description,
  };

  static Stamp? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? qid = json['qid'];
    final Object? name = json['name'];
    final DateTime? date = DateTime.tryParse('${json['date']}');
    if (qid is! String || name is! String || date == null) return null;
    // Los extras son opcionales: si faltan o vienen raros, se ignoran.
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    final Object? year = json['year'];
    final Object? description = json['description'];
    return Stamp(
      qid: qid,
      name: name,
      date: date,
      lat: lat is num ? lat.toDouble() : null,
      lon: lon is num ? lon.toDouble() : null,
      year: year is int ? year : null,
      description: description is String ? description : null,
    );
  }
}

/// Lee y guarda los sellos. Un monumento da UN sello (el primero).
class StampBook {
  const StampBook(this._store);

  final SettingsStore _store;

  List<Stamp> all() {
    try {
      final Object? list = jsonDecode(_store.readStamps() ?? '[]');
      if (list is! List<Object?>) return <Stamp>[];
      return list.map(Stamp.tryParse).whereType<Stamp>().toList();
    } on FormatException {
      return <Stamp>[];
    }
  }

  bool has(String qid) => all().any((Stamp s) => s.qid == qid);

  /// Añade el sello si no lo tenías. Devuelve false si ya estaba.
  Future<bool> add(Stamp stamp) async {
    final List<Stamp> stamps = all();
    if (stamps.any((Stamp s) => s.qid == stamp.qid)) return false;
    stamps.add(stamp);
    await _store.writeStamps(
      jsonEncode(stamps.map((Stamp s) => s.toJson()).toList()),
    );
    return true;
  }
}
