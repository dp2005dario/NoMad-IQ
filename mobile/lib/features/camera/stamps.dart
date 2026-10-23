// Los sellos del Pasaporte: cada monumento que reconoces con la cámara te
// da un sello con la fecha. Se guardan SOLO en el móvil.
import 'dart:convert';

import '../../core/settings.dart';

class Stamp {
  const Stamp({required this.qid, required this.name, required this.date});

  final String qid;
  final String name;
  final DateTime date;

  Map<String, Object?> toJson() => <String, Object?>{
    'qid': qid,
    'name': name,
    'date': date.toUtc().toIso8601String(),
  };

  static Stamp? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? qid = json['qid'];
    final Object? name = json['name'];
    final DateTime? date = DateTime.tryParse('${json['date']}');
    if (qid is! String || name is! String || date == null) return null;
    return Stamp(qid: qid, name: name, date: date);
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
  Future<bool> add(String qid, String name, DateTime when) async {
    final List<Stamp> stamps = all();
    if (stamps.any((Stamp s) => s.qid == qid)) return false;
    stamps.add(Stamp(qid: qid, name: name, date: when));
    await _store.writeStamps(
      jsonEncode(stamps.map((Stamp s) => s.toJson()).toList()),
    );
    return true;
  }
}
