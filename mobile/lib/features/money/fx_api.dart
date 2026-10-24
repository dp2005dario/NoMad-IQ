// Los tipos de cambio (pestaña Divisas): GET /v1/fx/rates.
//
// Vienen del Banco Central Europeo a través de nuestro servidor (que los
// guarda unas horas para que millones de personas no le pidan nada al BCE).
// Son públicos: los ve también quien entra como invitado.
//
// La última respuesta buena se guarda en el móvil: así Divisas funciona en
// el avión o en un país sin datos (con el aviso de qué día son).
import 'dart:convert';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/settings.dart';

class FxRates {
  const FxRates({required this.date, required this.rates});

  /// El día de los tipos (el BCE no publica en fines de semana).
  final DateTime date;

  /// Unidades de cada moneda por 1 euro.
  final Map<String, double> rates;

  List<String> get currencies => rates.keys.toList()..sort();

  bool has(String currency) => rates.containsKey(currency);

  /// Cuántas unidades de [to] vale 1 de [from].
  double rate(String from, String to) => rates[to]! / rates[from]!;

  /// [amountMinor] en [from] → unidades mínimas de [to] (redondeando).
  int convert(int amountMinor, String from, String to) {
    final double whole = amountMinor / _scale(currencyDigits(from));
    return (whole * rate(from, to) * _scale(currencyDigits(to))).round();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'base': 'EUR',
    'date':
        '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}',
    'rates': rates,
  };

  static FxRates parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? base = json['base'];
    final Object? day = json['date'];
    final Object? rates = json['rates'];
    final DateTime? date = day is String ? DateTime.tryParse(day) : null;
    if (base != 'EUR' || date == null || rates is! Map<String, Object?>) _bad();
    final Map<String, double> out = <String, double>{};
    for (final MapEntry<String, Object?> e in rates.entries) {
      final Object? v = e.value;
      if (RegExp(r'^[A-Z]{3}$').hasMatch(e.key) && v is num && v > 0) {
        out[e.key] = v.toDouble();
      }
    }
    if (out['EUR'] != 1.0 || out.length < 2) _bad();
    return FxRates(date: date, rates: out);
  }
}

double _scale(int digits) {
  double out = 1;
  for (int i = 0; i < digits; i++) {
    out *= 10;
  }
  return out;
}

/// Lo que devuelve [FxApi.load]: los tipos y si son de la copia del móvil.
class FxResult {
  const FxResult(this.rates, {required this.offline});

  final FxRates rates;

  /// true = no hubo red y son los últimos guardados.
  final bool offline;
}

class FxApi {
  const FxApi(this._api, this._prefs);

  final ApiClient _api;
  final SettingsStore _prefs;

  /// Los tipos de hoy; sin red, los últimos guardados. Si no hay ninguno,
  /// lanza el error de la red.
  Future<FxResult> load() async {
    try {
      final FxRates rates = FxRates.parse(
        await _api.getJson('/v1/fx/rates', public: true),
      );
      await _prefs.writeData(LocalData.fxRates, jsonEncode(rates.toJson()));
      return FxResult(rates, offline: false);
    } on ApiException {
      final FxRates? saved = _saved();
      if (saved == null) rethrow;
      return FxResult(saved, offline: true);
    }
  }

  FxRates? _saved() {
    final String? raw = _prefs.readData(LocalData.fxRates);
    if (raw == null) return null;
    try {
      return FxRates.parse(jsonDecode(raw));
    } on Object {
      return null; // copia rota: como si no hubiera
    }
  }
}

Never _bad() => throw const ApiException(ApiError.unavailable);
