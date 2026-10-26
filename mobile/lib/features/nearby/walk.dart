// "Tengo 2 horas": un paseo que sale de donde estás, pasa por sitios que ver
// y vuelve a tiempo. Todo se calcula en el móvil (sin servidor ni coste).
//
// Cómo: el "vecino más cercano". Desde donde estás, vas al sitio que ver más
// cercano; desde allí, al siguiente más cercano... y solo lo añades si aún
// te da tiempo a verlo Y a volver al punto de salida. Es como ir cogiendo
// cerezas de las ramas más bajas: no es la ruta perfecta, pero es buena,
// instantánea y nunca te deja lejos cuando se acaba el tiempo.
import '../map/geo.dart';
import 'nearby_api.dart';

/// Andando de paseo (más despacio que con prisa): unos 75 m por minuto.
const double walkMetersPerMinute = 75;

/// Las calles no van en línea recta: se cuenta un 30 % más de camino.
const double streetDetour = 1.3;

/// Lo que se queda uno en cada sitio (mirar, fotos).
const int minutesPerStop = 15;

/// Como mucho estas paradas (Google Maps admite 9 puntos intermedios).
const int maxStops = 8;

class WalkStop {
  const WalkStop({required this.spot, required this.walkMinutes});

  final NearbySpot spot;

  /// Minutos andando desde la parada anterior (o desde la salida).
  final int walkMinutes;
}

class WalkPlan {
  const WalkPlan({
    required this.start,
    required this.stops,
    required this.backMinutes,
    required this.totalMinutes,
  });

  final GeoPoint start;
  final List<WalkStop> stops;

  /// Minutos de la última parada de vuelta a la salida.
  final int backMinutes;
  final int totalMinutes;

  /// El paseo en Google Maps andando (gratis y sin clave: es un enlace).
  Uri get mapsUrl {
    String at(GeoPoint p) =>
        '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}';
    return Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'origin': at(start),
      'destination': at(start),
      'waypoints': stops.map((WalkStop s) => at(s.spot.point)).join('|'),
      'travelmode': 'walking',
    });
  }
}

int _walk(GeoPoint a, GeoPoint b) =>
    (a.distanceTo(b) * streetDetour / walkMetersPerMinute).ceil();

/// El paseo para [minutes] minutos desde [start] con los sitios [sights].
WalkPlan planWalk(GeoPoint start, List<NearbySpot> sights, int minutes) {
  final List<NearbySpot> left = List<NearbySpot>.of(sights);
  final List<WalkStop> stops = <WalkStop>[];
  GeoPoint here = start;
  int used = 0;
  while (left.isNotEmpty && stops.length < maxStops) {
    left.sort(
      (NearbySpot a, NearbySpot b) =>
          here.distanceTo(a.point).compareTo(here.distanceTo(b.point)),
    );
    final NearbySpot next = left.removeAt(0);
    final int go = _walk(here, next.point);
    final int back = _walk(next.point, start);
    // ¿Me da tiempo a ir, verlo y volver? Si no, aquí acaba el paseo (los
    // demás están más lejos de esta parada: mejor volver con margen).
    if (used + go + minutesPerStop + back > minutes) break;
    stops.add(WalkStop(spot: next, walkMinutes: go));
    used += go + minutesPerStop;
    here = next.point;
  }
  final int back = stops.isEmpty ? 0 : _walk(here, start);
  return WalkPlan(
    start: start,
    stops: stops,
    backMinutes: back,
    totalMinutes: used + back,
  );
}
