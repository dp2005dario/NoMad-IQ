// Matemáticas de la Tierra para la Ruta del vuelo.
//
// Un avión no vuela en línea recta sobre un mapa plano: sigue el camino más
// corto sobre la esfera, el "círculo máximo" (por eso Madrid → Tokio pasa por
// Rusia). Aquí está la fórmula para medir esa distancia (haversine) y para
// saber dónde está el avión a mitad de camino (interpolación esférica).
import 'dart:math' as math;

/// Un punto del planeta en grados.
class LatLon {
  const LatLon(this.lat, this.lon);

  final double lat;
  final double lon;

  @override
  String toString() => 'LatLon($lat, $lon)';
}

/// Radio medio de la Tierra en kilómetros.
const double earthRadiusKm = 6371.0;

double _rad(double deg) => deg * math.pi / 180;
double _deg(double rad) => rad * 180 / math.pi;

/// Distancia en km por el camino más corto (fórmula del haversine).
double distanceKm(LatLon a, LatLon b) {
  final double dLat = _rad(b.lat - a.lat);
  final double dLon = _rad(b.lon - a.lon);
  final double h =
      math.pow(math.sin(dLat / 2), 2).toDouble() +
      math.cos(_rad(a.lat)) *
          math.cos(_rad(b.lat)) *
          math.pow(math.sin(dLon / 2), 2).toDouble();
  return 2 * earthRadiusKm * math.asin(math.min(1, math.sqrt(h)));
}

/// El punto que está a una fracción [f] (0 = salida, 1 = llegada) del camino
/// más corto entre [a] y [b] ("slerp": interpolación sobre la esfera).
LatLon intermediate(LatLon a, LatLon b, double f) {
  final double d = distanceKm(a, b) / earthRadiusKm; // ángulo en radianes
  if (d < 1e-9) return a;
  final double sa = math.sin((1 - f) * d) / math.sin(d);
  final double sb = math.sin(f * d) / math.sin(d);
  final double la1 = _rad(a.lat), lo1 = _rad(a.lon);
  final double la2 = _rad(b.lat), lo2 = _rad(b.lon);
  final double x =
      sa * math.cos(la1) * math.cos(lo1) + sb * math.cos(la2) * math.cos(lo2);
  final double y =
      sa * math.cos(la1) * math.sin(lo1) + sb * math.cos(la2) * math.sin(lo2);
  final double z = sa * math.sin(la1) + sb * math.sin(la2);
  return LatLon(
    _deg(math.atan2(z, math.sqrt(x * x + y * y))),
    _deg(math.atan2(y, x)),
  );
}

/// El camino entero como [steps]+1 puntos. Las longitudes van "desenrolladas":
/// si la ruta cruza el meridiano 180 (Tokio → Los Ángeles), en vez de saltar
/// de 179° a −179° sigue a 181°, para que la línea no cruce todo el mapa.
List<LatLon> greatCircle(LatLon a, LatLon b, {int steps = 128}) {
  final List<LatLon> out = <LatLon>[];
  double? prev;
  for (int i = 0; i <= steps; i++) {
    final LatLon p = intermediate(a, b, i / steps);
    double lon = p.lon;
    if (prev != null) {
      while (lon - prev > 180) {
        lon -= 360;
      }
      while (lon - prev < -180) {
        lon += 360;
      }
    }
    prev = lon;
    out.add(LatLon(p.lat, lon));
  }
  return out;
}

/// Tiempo de vuelo aproximado: unos 30 min de despegue y aterrizaje más
/// crucero a ~830 km/h (lo que suelen tardar los vuelos comerciales).
Duration estimatedFlightTime(double km) =>
    Duration(minutes: 30 + (km / 830 * 60).round());
