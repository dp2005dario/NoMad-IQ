// Los aeropuertos con su nombre "de persona": "Madrid", "Tokio",
// "Nueva York"... para poder buscar un vuelo escribiendo la ciudad y no el
// código raro de tres letras (MAD, NRT, JFK).
//
// La lista ya va dentro de la maqueta de Vuelos (assets/flights/vuelos.html,
// la variable window.AP): se lee de ahí para no llevarla dos veces en la app.
// Cada fila es: [código, nombre, ciudad, país, código del país, otros
// nombres, ...]. Está ordenada por importancia: los grandes primero.
import 'dart:convert';

import 'package:flutter/services.dart';

import '../route/geo.dart';
import '../route/world_data.dart';
import '../vault/policy_search.dart' show fold;
import 'flights_page.dart' show flightsPage;

/// Un aeropuerto, como lo diría una persona.
class AirportName {
  const AirportName({
    required this.iata,
    required this.city,
    required this.country,
    required this.countryCode,
    required this.rank,
    this.aliases = const <String>[],
  });

  /// "MAD".
  final String iata;

  /// "Madrid".
  final String city;

  /// "España".
  final String country;

  /// "ES" (para la bandera).
  final String countryCode;

  /// Otros nombres de la ciudad ("London" para Londres).
  final List<String> aliases;

  /// Su puesto en la lista: 0 es el más importante.
  final int rank;

  /// La bandera del país con emojis ("ES" → 🇪🇸).
  String get flag {
    if (countryCode.length != 2) return '';
    return String.fromCharCodes(<int>[
      for (final int c in countryCode.toUpperCase().codeUnits)
        if (c >= 65 && c <= 90) 0x1F1E6 + c - 65,
    ]);
  }
}

/// Todos los aeropuertos con nombre, por código.
class AirportNames {
  AirportNames(this.all)
    : _byCode = <String, AirportName>{
        for (final AirportName a in all) a.iata: a,
      };

  /// En orden de importancia.
  final List<AirportName> all;
  final Map<String, AirportName> _byCode;

  AirportName? operator [](String iata) => _byCode[iata.toUpperCase()];

  /// Lee la lista de dentro de la maqueta. Una fila rara se salta.
  static AirportNames parseHtml(String html) {
    const String mark = 'window.AP=';
    final int at = html.indexOf(mark);
    if (at < 0) return AirportNames(const <AirportName>[]);
    final int start = at + mark.length;
    // La lista acaba en "]]" y luego ";" o "<": se busca el cierre real
    // contando corchetes (los nombres no llevan corchetes).
    int depth = 0;
    int end = start;
    for (; end < html.length; end++) {
      final int c = html.codeUnitAt(end);
      if (c == 0x5B) depth++; // [
      if (c == 0x5D) {
        depth--; // ]
        if (depth == 0) break;
      }
    }
    final Object? rows;
    try {
      rows = jsonDecode(html.substring(start, end + 1));
    } on FormatException {
      return AirportNames(const <AirportName>[]);
    }
    if (rows is! List<Object?>) return AirportNames(const <AirportName>[]);
    final List<AirportName> out = <AirportName>[];
    for (final Object? r in rows) {
      if (r is! List<Object?> || r.length < 6) continue;
      final Object? iata = r[0], city = r[2], country = r[3], cc = r[4];
      if (iata is! String || iata.length != 3) continue;
      if (city is! String || country is! String || cc is! String) continue;
      final Object? more = r[5];
      out.add(
        AirportName(
          iata: iata,
          city: city,
          country: country,
          countryCode: cc,
          rank: out.length,
          aliases: <String>[
            if (more is List<Object?>)
              for (final Object? m in more)
                if (m is String) m,
          ],
        ),
      );
    }
    return AirportNames(out);
  }

  static AirportNames? _cache;

  /// Se lee una vez y se queda en memoria.
  static Future<AirportNames> load([AssetBundle? bundle]) async {
    final AirportNames? done = _cache;
    if (done != null) return done;
    final String html = await (bundle ?? rootBundle).loadString(
      flightsPage,
      cache: false,
    );
    return _cache = parseHtml(html);
  }

  /// Busca por ciudad, país, otro nombre o código. Primero lo que EMPIEZA
  /// por lo escrito; a igualdad, el aeropuerto más importante.
  List<AirportName> search(String query, {int limit = 8}) {
    final String q = withoutAirportWords(fold(query.trim()));
    if (q.isEmpty) return const <AirportName>[];
    final List<(int, AirportName)> hits = <(int, AirportName)>[];
    for (final AirportName a in all) {
      final int score = _score(a, q);
      if (score >= 0) hits.add((score, a));
    }
    hits.sort(((int, AirportName) x, (int, AirportName) y) {
      final int byScore = x.$1.compareTo(y.$1);
      return byScore != 0 ? byScore : x.$2.rank.compareTo(y.$2.rank);
    });
    return <AirportName>[
      for (final (int, AirportName) h in hits.take(limit)) h.$2,
    ];
  }

  /// Quita las palabras que la gente añade y no son el sitio: "aeropuerto
  /// de Málaga", "malaga airport", "Flughafen München"... → "malaga".
  /// Si solo queda eso (escribiste "aeropuerto"), se deja como está.
  static String withoutAirportWords(String q) {
    final List<String> words = q.split(RegExp(r'\s+'));
    final List<String> kept = <String>[];
    for (int i = 0; i < words.length; i++) {
      if (!_airportWords.contains(words[i])) {
        kept.add(words[i]);
        continue;
      }
      // "aeropuerto DE Málaga": el "de" de detrás también sobra (pero el
      // de "Río de Janeiro" no, porque no va detrás de "aeropuerto").
      if (i + 1 < words.length && _joiners.contains(words[i + 1])) i++;
    }
    return kept.isEmpty ? q : kept.join(' ');
  }

  static const Set<String> _airportWords = <String>{
    'aeropuerto',
    'aeropuertos',
    'airport',
    'airports',
    'aeroport',
    'aeroporto',
    'aeroporti',
    'flughafen',
    'luchthaven',
    'lotnisko',
    'havalimani',
    'aeroportul',
    'letiste',
    'international',
    'internacional',
    'internazionale',
    'intl',
  };
  static const Set<String> _joiners = <String>{
    'de',
    'del',
    'of',
    'di',
    'da',
    'do',
    'du',
    'von',
    'van',
  };

  /// 0 = el código exacto; 1 = la ciudad empieza así; 2 = otro nombre
  /// empieza así; 3 = el país empieza así; 4 = lo lleva dentro; -1 = no.
  static int _score(AirportName a, String q) {
    if (q.length == 3 && a.iata.toLowerCase() == q) return 0;
    final String city = fold(a.city);
    if (city.startsWith(q)) return 1;
    for (final String alias in a.aliases) {
      if (fold(alias).startsWith(q)) return 2;
    }
    if (q.length >= 3 && fold(a.country).startsWith(q)) return 3;
    if (q.length >= 3 && city.contains(q)) return 4;
    return -1;
  }

  /// El aeropuerto "de verdad" más cerca de ti: de los que hay a menos de
  /// [km], el más importante (cerca de Madrid sale Barajas, no Torrejón).
  String? mainNear(Airports positions, LatLon here, {double km = 100}) {
    AirportName? best;
    for (final Airport p in positions.all) {
      if (distanceKm(here, p.position) > km) continue;
      final AirportName? a = this[p.iata];
      if (a != null && (best == null || a.rank < best.rank)) best = a;
    }
    return best?.iata;
  }
}
