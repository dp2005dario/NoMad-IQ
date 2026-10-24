// "Mis viajes copiados": los viajes que has copiado (ya adaptados a tu
// presupuesto) viven SOLO en este móvil. El servidor solo sabe que lo
// copiaste (para el "copiado N veces"), no cómo lo dejaste.
import 'dart:convert';

import '../../core/settings.dart';
import '../money/expenses_api.dart';
import 'shared_trip_api.dart';

class CopiedTrip {
  const CopiedTrip({
    required this.code,
    required this.title,
    required this.destination,
    required this.days,
    required this.currency,
    required this.lines,
    required this.copiedAt,
  });

  final String code;
  final String title;
  final String destination;
  final int days;
  final String currency;
  final List<TripLine> lines;
  final DateTime copiedAt;

  int get totalMinor => linesTotal(lines);

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'title': title,
    'destination': destination,
    'days': days,
    'currency': currency,
    'lines': <Object?>[for (final TripLine l in lines) l.toJson()],
    'copied_at': copiedAt.toUtc().toIso8601String(),
  };

  static CopiedTrip? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? code = json['code'];
    final Object? title = json['title'];
    final Object? destination = json['destination'];
    final Object? days = json['days'];
    final Object? currency = json['currency'];
    final Object? lines = json['lines'];
    final DateTime? at = DateTime.tryParse('${json['copied_at']}');
    if (code is! String ||
        title is! String ||
        destination is! String ||
        days is! int ||
        currency is! String ||
        lines is! List<Object?> ||
        at == null) {
      return null;
    }
    return CopiedTrip(
      code: code,
      title: title,
      destination: destination,
      days: days,
      currency: currency,
      lines: <TripLine>[for (final Object? l in lines) ?TripLine.parse(l)],
      copiedAt: at,
    );
  }
}

/// Como mucho 30 viajes copiados (los más nuevos primero).
const int maxCopiedTrips = 30;

class CopiedTrips {
  const CopiedTrips(this._store);

  final SettingsStore _store;

  List<CopiedTrip> all() {
    try {
      final Object? list = jsonDecode(
        _store.readData(LocalData.copiedTrips) ?? '[]',
      );
      if (list is! List<Object?>) return <CopiedTrip>[];
      return <CopiedTrip>[for (final Object? j in list) ?CopiedTrip.parse(j)];
    } on FormatException {
      return <CopiedTrip>[];
    }
  }

  /// Guarda [trip] el primero. Si ya habías copiado ese código, lo sustituye
  /// (por ejemplo, con otro presupuesto).
  Future<void> add(CopiedTrip trip) => _write(<CopiedTrip>[
    trip,
    for (final CopiedTrip t in all())
      if (t.code != trip.code) t,
  ]);

  Future<void> remove(String code) => _write(<CopiedTrip>[
    for (final CopiedTrip t in all())
      if (t.code != code) t,
  ]);

  Future<void> _write(List<CopiedTrip> trips) => _store.writeData(
    LocalData.copiedTrips,
    jsonEncode(<Object?>[
      for (final CopiedTrip t in trips.take(maxCopiedTrips)) t.toJson(),
    ]),
  );
}

/// Las líneas de un bote de Gastos para empezar a compartirlo: los gastos
/// más grandes primero (hasta 30) y con el tipo "otro" para que la persona
/// lo cambie. No se manda nada hasta que pulse Compartir.
List<TripLine> linesFromExpenses(ExpenseGroup group) {
  final List<Expense> sorted = <Expense>[...group.expenses]
    ..sort((Expense a, Expense b) => b.amountMinor.compareTo(a.amountMinor));
  return <TripLine>[
    for (final Expense e in sorted.take(30))
      TripLine(
        kind: guessKind(e.title),
        title: e.title.length > 80 ? e.title.substring(0, 80) : e.title,
        priceMinor: e.amountMinor,
      ),
  ];
}

/// Adivina el tipo por palabras típicas (en varios idiomas). Si no, "otro".
TripKind guessKind(String title) {
  final String t = title.toLowerCase();
  bool has(List<String> words) => words.any(t.contains);
  if (has(<String>[
    'vuelo',
    'flight',
    'vol ',
    'flug',
    'volo',
    'voo',
    'avión',
  ])) {
    return TripKind.flight;
  }
  if (has(<String>['hotel', 'hostal', 'hostel', 'airbnb', 'apartamento'])) {
    return TripKind.stay;
  }
  if (has(<String>['tren', 'train', 'bus', 'metro', 'taxi', 'uber', 'pass'])) {
    return TripKind.transport;
  }
  if (has(<String>['cena', 'comida', 'dinner', 'lunch', 'restaurante'])) {
    return TripKind.food;
  }
  if (has(<String>['museo', 'museum', 'entrada', 'ticket', 'excursión'])) {
    return TripKind.activity;
  }
  return TripKind.other;
}
