// Datos fijos de cada país para "Antes de salir" (las tarjetas "<país> en
// 30 segundos"): por qué lado se conduce, sus monedas y sus idiomas
// oficiales, con el nombre de cada idioma y moneda en los 25 idiomas de la
// app.
//
// Van dentro de la app (assets/geo/country_facts.txt y fact_names.txt), así
// funcionan sin Internet. Salen de REST Countries (licencia MPL-2.0) y de
// CLDR de Unicode; cómo se regeneran: tool/build_country_facts.py.
// Si un país no está, la tarjeta no sale (mejor nada que inventar).
import 'package:flutter/services.dart';

/// Las fuentes, para enseñarlas junto a cada tarjeta.
const String restCountriesSource = 'REST Countries';
const String cldrSource = 'CLDR (Unicode)';
const String ianaSource = 'IANA (husos horarios)';
const String iecSource = 'IEC World Plugs (vía Wikipedia)';
const String emergencyWikiSource = 'Wikipedia (números de emergencia)';
const String passportIndexSource = 'Passport Index';
const String ecbSource = 'BCE (tipos de cambio)';

/// Los idiomas de la app en el mismo orden que las columnas de
/// fact_names.txt.
const List<String> _appLangs = <String>[
  'es', 'en', 'ar', 'bn', 'de', 'fa', 'fil', 'fr', 'hi', 'id', 'it', 'ja', //
  'ko', 'ms', 'nl', 'pl', 'pt', 'ro', 'ru', 'th', 'tr', 'uk', 'ur', 'vi', //
  'zh',
];

/// Lo que se sabe de un país.
class CountryFact {
  const CountryFact({
    required this.drivesLeft,
    required this.currencies,
    required this.languages,
  });

  /// true = por la izquierda, false = por la derecha, null = no se sabe.
  final bool? drivesLeft;

  /// Códigos ISO de sus monedas ("JPY").
  final List<String> currencies;

  /// Códigos de sus idiomas oficiales ("ja").
  final List<String> languages;
}

class CountryFacts {
  CountryFacts._(this._facts, this._langNames, this._curNames, this._symbols);

  final Map<String, CountryFact> _facts;
  final Map<String, List<String>> _langNames;
  final Map<String, List<String>> _curNames;
  final Map<String, String> _symbols;

  CountryFact? operator [](String iso2) => _facts[iso2.toUpperCase()];

  String _pick(List<String>? row, String lang, String fallback) {
    if (row == null) return fallback;
    final int i = _appLangs.indexOf(lang);
    final String n = i >= 0 && i < row.length ? row[i] : '';
    if (n.isNotEmpty) return n;
    return row.length > 1 && row[1].isNotEmpty ? row[1] : fallback;
  }

  /// "japonés" (en tu idioma).
  String languageName(String code, String lang) =>
      _pick(_langNames[code], lang, code);

  /// "yen japonés".
  String currencyName(String code, String lang) =>
      _pick(_curNames[code], lang, code);

  /// "¥" (o el código si no tiene símbolo).
  String symbol(String code) {
    final String s = _symbols[code] ?? '';
    return s.isEmpty ? code : s;
  }

  static CountryFacts parse(String facts, String names) {
    final Map<String, CountryFact> byCountry = <String, CountryFact>{};
    for (final String line in facts.split('\n')) {
      final List<String> f = line.split('|');
      if (f.length < 4 || f[0].length != 2) continue;
      List<String> list(String s) =>
          s.isEmpty ? const <String>[] : s.split(',');
      byCountry[f[0]] = CountryFact(
        drivesLeft: f[1] == 'L' ? true : (f[1] == 'R' ? false : null),
        currencies: list(f[2]),
        languages: list(f[3]),
      );
    }
    final Map<String, List<String>> langs = <String, List<String>>{};
    final Map<String, List<String>> curs = <String, List<String>>{};
    final Map<String, String> symbols = <String, String>{};
    for (final String line in names.split('\n')) {
      final List<String> f = line.split('|');
      if (f.length < 3) continue;
      if (f[0] == 'L') {
        langs[f[1]] = f.sublist(2);
      } else if (f[0] == 'C' && f.length > 3) {
        symbols[f[1]] = f[2];
        curs[f[1]] = f.sublist(3);
      }
    }
    return CountryFacts._(byCountry, langs, curs, symbols);
  }

  static Future<CountryFacts>? _loading;

  /// Se lee una vez y se guarda.
  static Future<CountryFacts> load([AssetBundle? bundle]) =>
      _loading ??= () async {
        final AssetBundle b = bundle ?? rootBundle;
        return parse(
          await b.loadString('assets/geo/country_facts.txt'),
          await b.loadString('assets/geo/fact_names.txt'),
        );
      }();
}

/// "+8 h", "−1 h", "+5:30 h" o null si es la misma hora.
String? hoursDiff(Duration there, Duration here) {
  final int min = (there - here).inMinutes;
  if (min == 0) return null;
  final String sign = min > 0 ? '+' : '−';
  final int h = min.abs() ~/ 60;
  final int m = min.abs() % 60;
  return m == 0 ? '$sign$h h' : '$sign$h:${m.toString().padLeft(2, '0')} h';
}
