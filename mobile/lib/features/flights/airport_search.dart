// Buscar aeropuertos escribiendo el código, la ciudad o el país ("MAD",
// "Málaga", "aeropuerto de Málaga"). Usa la lista que la app ya lleva dentro
// (assets/geo/airports.txt), así que funciona sin Internet.
import '../route/world_data.dart';

/// Palabras que la gente escribe pero que no ayudan a encontrar nada.
const Set<String> _fillerWords = <String>{
  'aeropuerto',
  'aeroport',
  'aeroporto',
  'aeroporti',
  'airport',
  'flughafen',
  'luchthaven',
  'de',
  'del',
  'of',
  'the',
  'la',
  'el',
};

const Map<String, String> _accents = <String, String>{
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', //
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', //
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', //
  'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', //
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', //
  'ñ': 'n', 'ç': 'c', //
};

/// Minúsculas y sin tildes, para que "málaga" y "Malaga" sean iguales.
String normalizeSearch(String text) {
  final StringBuffer out = StringBuffer();
  for (final String ch in text.toLowerCase().split('')) {
    out.write(_accents[ch] ?? ch);
  }
  return out.toString().trim();
}

/// Quita "aeropuerto de", "airport"... y deja lo importante ("malaga").
String _core(String query) {
  final String norm = normalizeSearch(query);
  final List<String> words = norm
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty && !_fillerWords.contains(w))
      .toList();
  // Si solo escribió palabras de relleno, se busca tal cual.
  return words.isEmpty ? norm : words.join(' ');
}

/// Los aeropuertos que encajan con [query], los mejores primero. Menos de 2
/// letras no busca nada (saldrían cientos). Devuelve como mucho [limit].
List<Airport> searchAirports(
  Iterable<Airport> airports,
  String query, {
  int limit = 8,
}) {
  final String q = _core(query);
  if (q.length < 2) return const <Airport>[];
  final List<(int, Airport)> hits = <(int, Airport)>[];
  for (final Airport a in airports) {
    final String code = a.iata.toLowerCase();
    final String city = normalizeSearch(a.city);
    final String country = normalizeSearch(a.country);
    // Menor número = mejor encaje.
    final int? score = code == q
        ? 0
        : city == q
        ? 1
        : code.startsWith(q)
        ? 2
        : city.startsWith(q)
        ? 3
        : city.contains(q)
        ? 4
        : country.startsWith(q)
        ? 5
        : null;
    if (score != null) hits.add((score, a));
  }
  hits.sort((a, b) {
    final int byScore = a.$1.compareTo(b.$1);
    return byScore != 0 ? byScore : a.$2.city.compareTo(b.$2.city);
  });
  return <Airport>[for (final (int, Airport) h in hits.take(limit)) h.$2];
}
