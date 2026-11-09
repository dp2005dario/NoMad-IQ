// Lo que la app le da a la página de Divisas (la maqueta "Cambio de
// moneda", en assets/money/divisas.html): los tipos de cambio del Banco
// Central Europeo, de qué día son y las fotos de los billetes y monedas de
// las dos monedas elegidas (las de assets/divisas, ver currency_photos.dart).
//
// Las fotos van dentro de la página como "data:" (el WebView no lee los
// assets de la app). Para no cargar las 12 monedas de golpe, solo se mandan
// las de las monedas que eliges. Dart puro: se prueba sin WebView.
import 'dart:convert';

import '../../core/money.dart';
import 'currency_photos.dart';
import 'fx_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String fxPage = 'assets/money/divisas.html';
const String fxMarker = '/*ECLIPTA*/{}';

/// Las monedas de la maqueta (en su orden).
const List<String> fxCodes = <String>[
  'EUR',
  'GBP',
  'USD',
  'JPY',
  'CHF',
  'MXN',
  'CAD',
  'AUD',
  'CNY',
  'THB',
  'TRY',
  'MAD',
];

/// La moneda que gira en cada divisa (su valor, como en la maqueta).
const Map<String, num> spinCoins = <String, num>{
  'EUR': 2,
  'GBP': 1,
  'USD': 0.25,
  'JPY': 500,
  'CHF': 5,
  'MXN': 10,
  'CAD': 1,
  'AUD': 2,
  'CNY': 1,
  'THB': 10,
  'TRY': 1,
  'MAD': 10,
};

/// El valor como lo escribe la página ("0.5", "2", "500").
String valueKey(int minor, int digits) {
  int div = 1;
  for (int i = 0; i < digits; i++) {
    div *= 10;
  }
  if (minor % div == 0) return '${minor ~/ div}';
  // 5 / 100 = 0.05 (sin ceros de más).
  return (minor / div).toString();
}

/// Las fotos que hay de una divisa (rutas de assets): la moneda que gira
/// ("s"), los billetes ("n") y las monedas ("m"), por su valor.
Map<String, Object?>? photoAssets(String code) {
  final Set<int> notes = notePhotos[code] ?? const <int>{};
  final Set<int> coins = coinPhotos[code] ?? const <int>{};
  if (notes.isEmpty && coins.isEmpty) return null;
  final int digits = currencyDigits(code);
  final Map<String, String> m = <String, String>{
    for (final int c in coins) valueKey(c, digits): coinPhoto(code, c)!,
  };
  final num? spin = spinCoins[code];
  return <String, Object?>{
    if (spin != null && m.containsKey(_numKey(spin))) 's': m[_numKey(spin)],
    'n': <String, String>{for (final int v in notes) '$v': notePhoto(code, v)!},
    'm': m,
  };
}

String _numKey(num v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

/// "7-11-2026" (el día de los tipos, como lo escribía la maqueta).
String fxDay(DateTime d) => '${d.day}-${d.month}-${d.year}';

/// Todo lo que necesita la página. [ph] son las fotos ya convertidas a
/// "data:" de las monedas que se ven.
Map<String, Object?> fxPageData({
  required String from,
  required String to,
  FxResult? fx,
  bool failed = false,
  Map<String, Object?> ph = const <String, Object?>{},
}) => <String, Object?>{
  'from': from,
  'to': to,
  'rates': <String, double>{
    if (fx != null)
      for (final String c in fxCodes)
        if (fx.rates.rates[c] case final double r) c: r,
  },
  'day': fx == null ? '' : fxDay(fx.rates.date),
  'offline': fx?.offline ?? false,
  'failed': failed && fx == null,
  'ph': ph,
};

/// La página lista para enseñar.
String fxPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(fxMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String fxPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
