// Los datos de Visado, que van DENTRO de la app (assets/geo):
//   - visas.txt: qué necesita cada pasaporte para entrar en cada país
//     (passportindex.org, licencia MIT; ver tool/build_visa_data.py).
//   - country_names.txt: el nombre de cada país en cada idioma de la app.
// Sin servidor: funciona sin conexión, cuesta 0 € aunque la usen millones y
// nadie se entera de a qué país piensas viajar.
import 'package:flutter/services.dart';

/// Lo que te piden para entrar.
enum EntryRule {
  /// No necesitas nada (como mucho, un formulario de llegada).
  free,

  /// Te dan el visado al llegar (a veces pagando en el aeropuerto).
  onArrival,

  /// Autorización electrónica: ESTA, eTA, ETA... Se pide en una web oficial
  /// en minutos y suele llegar en horas.
  eta,

  /// Visado electrónico: también por Internet, pero con más papeles y días.
  eVisa,

  /// Visado de los de siempre: cita en la embajada o el consulado.
  embassy,

  /// Ahora mismo no dejan entrar con ese pasaporte.
  refused,

  /// No tenemos el dato.
  unknown,
}

class EntryRequirement {
  const EntryRequirement(this.rule, [this.days]);

  final EntryRule rule;

  /// Cuántos días te puedes quedar, si se sabe.
  final int? days;

  static const EntryRequirement unknown = EntryRequirement(EntryRule.unknown);

  /// "F90" → sin visado, 90 días. Formato en tool/build_visa_data.py.
  static EntryRequirement parse(String cell) {
    if (cell.isEmpty) return unknown;
    final EntryRule? rule = switch (cell[0]) {
      'F' => EntryRule.free,
      'A' => EntryRule.onArrival,
      'T' => EntryRule.eta,
      'E' => EntryRule.eVisa,
      'R' => EntryRule.embassy,
      'N' => EntryRule.refused,
      _ => null,
    };
    if (rule == null) return unknown;
    return EntryRequirement(rule, int.tryParse(cell.substring(1)));
  }

  /// ¿Hay que hacer algo por Internet antes de salir?
  bool get applyOnline => rule == EntryRule.eta || rule == EntryRule.eVisa;
}

/// La tabla pasaporte × destino.
class VisaTable {
  VisaTable._(this.updated, this._dest, this._rows);

  /// Cuándo se sacaron los datos ("2026-02-17").
  final String updated;
  final Map<String, int> _dest;
  final Map<String, List<String>> _rows;

  /// Los pasaportes que conocemos.
  Iterable<String> get passports => _rows.keys;

  EntryRequirement lookup(String passport, String destination) {
    final List<String>? row = _rows[passport.toUpperCase()];
    final int? i = _dest[destination.toUpperCase()];
    if (row == null || i == null || i >= row.length) {
      return EntryRequirement.unknown;
    }
    return EntryRequirement.parse(row[i]);
  }

  static VisaTable parse(String text) {
    final List<String> lines = text.split('\n');
    String updated = '';
    final Map<String, int> dest = <String, int>{};
    final Map<String, List<String>> rows = <String, List<String>>{};
    final RegExp iso = RegExp(r'^[A-Z]{2}$');
    for (final String line in lines) {
      if (line.startsWith('#')) {
        updated = RegExp(r'\d{4}-\d{2}-\d{2}').firstMatch(line)?[0] ?? '';
      } else if (dest.isEmpty && line.isNotEmpty && !line.contains('|')) {
        final List<String> codes = line.split(' ');
        for (int i = 0; i < codes.length; i++) {
          if (iso.hasMatch(codes[i])) dest[codes[i]] = i;
        }
      } else if (line.split('|') case [final String p, final String cells]
          when iso.hasMatch(p)) {
        rows[p] = cells.split(',');
      }
    }
    return VisaTable._(updated, dest, rows);
  }

  static Future<VisaTable>? _loading;

  static Future<VisaTable> load([AssetBundle? bundle]) =>
      _loading ??= (bundle ?? rootBundle)
          .loadString('assets/geo/visas.txt')
          .then(parse)
          .catchError((Object e) {
            _loading = null;
            throw e;
          });
}

/// Los nombres de los países en el idioma de la app ("US" → "Estados Unidos").
class CountryNames {
  CountryNames._(this._langs, this._names, this._iso3);

  final Map<String, int> _langs;
  final Map<String, List<String>> _names;
  final Map<String, String> _iso3;

  /// Todos los códigos de dos letras que conocemos.
  Iterable<String> get codes => _names.keys;

  /// El nombre en [language] (o en inglés, o el propio código).
  String name(String code, String language) {
    final List<String>? row = _names[code.toUpperCase()];
    if (row == null) return code;
    final int i = _langs[language] ?? 0;
    final String n = i < row.length ? row[i] : '';
    return n.isNotEmpty
        ? n
        : (row.isNotEmpty && row[0].isNotEmpty)
        ? row[0]
        : code;
  }

  /// "ESP" (como viene en el pasaporte) → "ES".
  String? fromIso3(String iso3) => _iso3[iso3.toUpperCase()];

  static CountryNames parse(String text) {
    final List<String> lines = text.split('\n');
    final Map<String, int> langs = <String, int>{};
    final Map<String, List<String>> names = <String, List<String>>{};
    final Map<String, String> iso3 = <String, String>{};
    if (lines.isEmpty) return CountryNames._(langs, names, iso3);
    // Primera línea: "iso3 en ar de...". El inglés va siempre primero.
    final List<String> head = lines.first.split(' ');
    for (int i = 1; i < head.length; i++) {
      langs[head[i]] = i - 1;
    }
    for (final String line in lines.skip(1)) {
      final List<String> parts = line.split('|');
      if (parts.length < 3 || !RegExp(r'^[A-Z]{2}$').hasMatch(parts[0])) {
        continue;
      }
      names[parts[0]] = parts.sublist(2);
      if (RegExp(r'^[A-Z]{3}$').hasMatch(parts[1])) iso3[parts[1]] = parts[0];
    }
    // En los pasaportes alemanes pone "D", no "DEU" (es la norma OACI).
    iso3['D'] = 'DE';
    return CountryNames._(langs, names, iso3);
  }

  static Future<CountryNames>? _loading;

  static Future<CountryNames> load([AssetBundle? bundle]) =>
      _loading ??= (bundle ?? rootBundle)
          .loadString('assets/geo/country_names.txt')
          .then(parse)
          .catchError((Object e) {
            _loading = null;
            throw e;
          });
}

/// Las dos tablas juntas, que es lo que necesita la pantalla.
class VisaData {
  const VisaData(this.table, this.names);

  final VisaTable table;
  final CountryNames names;
}

/// Las tablas que van dentro de la app (en los tests se pasan otras).
Future<VisaData> bundledVisaData() async {
  final (VisaTable table, CountryNames names) = await (
    VisaTable.load(),
    CountryNames.load(),
  ).wait;
  return VisaData(table, names);
}
