// Las cuentas del Pasaporte (sin pantalla, fácil de probar): de una lista de
// sellos sale un "librito" con una página por país, y cada sello es un cromo
// con su rareza.
import '../camera/stamps.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/geo.dart';
import '../route/world_data.dart';
import '../sos/where_am_i.dart';

/// Lo rara que es una carta. Como en los cromos del colegio, pero aquí
/// manda la edad del monumento: cuanto más antiguo, más difícil de tener.
enum Rarity { legendary, epic, rare, common }

Rarity rarityOf(int? year) => switch (year) {
  null => Rarity.common, // no sabemos la edad: común
  < 1000 => Rarity.legendary, // Coliseo, pirámides...
  < 1600 => Rarity.epic, // catedrales góticas, castillos...
  < 1900 => Rarity.rare,
  _ => Rarity.common,
};

/// Una página del librito: un país (o "Otros lugares" si no se sabe).
class PassportPage {
  const PassportPage({
    this.country,
    required this.cities,
    required this.stamps,
  });

  /// Código ISO de dos letras ("JP"); null = "Otros lugares".
  final String? country;

  /// Las ciudades de los sellos, sin repetir ("Tokyo · Kyoto").
  final List<String> cities;

  /// Los sellos de la página, el más nuevo primero.
  final List<Stamp> stamps;
}

/// "JP" -> 🇯🇵. Las banderas son dos "letras regionales" seguidas: el móvil
/// las junta y dibuja la bandera. Así no hace falta ninguna imagen.
String flagOf(String iso) {
  const int base = 0x1F1E6 - 0x41; // 'A' -> 🇦
  final String up = iso.toUpperCase();
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(up)) return '🏳️';
  return String.fromCharCodes(up.codeUnits.map((int c) => base + c));
}

/// Reparte los sellos en páginas. El país sale del aeropuerto más cercano
/// (como en el SOS: sin Internet). Primero la página del sello más nuevo;
/// "Otros lugares" siempre al final.
List<PassportPage> pagesOf(
  List<Stamp> stamps, {
  Iterable<Airport> airports = const <Airport>[],
  CountryCodes? codes,
}) {
  final List<Stamp> newest = List<Stamp>.of(stamps)
    ..sort((Stamp a, Stamp b) => b.date.compareTo(a.date));
  // El orden de inserción de un Map es el de aparición: el país del sello
  // más nuevo queda el primero.
  final Map<String?, List<Stamp>> byCountry = <String?, List<Stamp>>{};
  final Map<String?, List<String>> cities = <String?, List<String>>{};
  for (final Stamp s in newest) {
    Airport? near;
    if (s.lat != null && s.lon != null) {
      near = nearestAirport(airports, LatLon(s.lat!, s.lon!));
    }
    final String? country = near == null ? null : codes?[near.country];
    (byCountry[country] ??= <Stamp>[]).add(s);
    final List<String> list = cities[country] ??= <String>[];
    if (near != null && !list.contains(near.city)) list.add(near.city);
  }
  final List<PassportPage> pages = <PassportPage>[
    for (final MapEntry<String?, List<Stamp>> e in byCountry.entries)
      if (e.key != null)
        PassportPage(country: e.key, cities: cities[e.key]!, stamps: e.value),
  ];
  final List<Stamp>? elsewhere = byCountry[null];
  if (elsewhere != null) {
    pages.add(PassportPage(cities: const <String>[], stamps: elsewhere));
  }
  return pages;
}

/// El sitio en OpenStreetMap (gratis y sin cuenta), para "Ver en el mapa".
Uri osmLink(double lat, double lon) => Uri.https(
  'www.openstreetmap.org',
  '/',
  <String, String>{'mlat': '$lat', 'mlon': '$lon'},
).replace(fragment: 'map=17/$lat/$lon');
