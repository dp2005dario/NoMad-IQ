// "¿En qué país estoy?" sin Internet: se busca el aeropuerto más cercano
// (la app ya lleva ~5.500 dentro, para la Ruta del vuelo) y se usa su país.
// Cerca de una frontera puede fallar por pocos km; para elegir el número de
// emergencias basta (y el 112 funciona casi en todas partes de todos modos).
import 'package:flutter/services.dart';

import '../map/geo.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/geo.dart';
import '../route/world_data.dart';

/// Más lejos que esto del aeropuerto más cercano (en medio del mar...), no
/// nos atrevemos a decir el país.
const double maxGuessKm = 400;

class Whereabouts {
  const Whereabouts({this.country, this.city});

  /// Código ISO de dos letras ("JP"); null = no se sabe.
  final String? country;

  /// La ciudad del aeropuerto más cercano ("Tokyo").
  final String? city;
}

Airport? nearestAirport(Iterable<Airport> airports, LatLon here) {
  Airport? best;
  double bestKm = double.infinity;
  for (final Airport a in airports) {
    final double km = distanceKm(here, a.position);
    if (km < bestKm) {
      bestKm = km;
      best = a;
    }
  }
  return bestKm <= maxGuessKm ? best : null;
}

Future<Whereabouts> whereabouts(GeoPoint here, [AssetBundle? bundle]) async {
  try {
    final WorldData world = await WorldData.load(bundle);
    final CountryCodes codes = await CountryCodes.load(bundle);
    final Airport? a = nearestAirport(
      world.airports.all,
      LatLon(here.lat, here.lon),
    );
    if (a == null) return const Whereabouts();
    return Whereabouts(country: codes[a.country], city: a.city);
  } on Object {
    return const Whereabouts(); // sin datos: se usará el 112
  }
}
