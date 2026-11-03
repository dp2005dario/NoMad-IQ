// La hora dorada (pantalla Grupo): la luz bonita de antes de la puesta de
// sol, buena para un mirador. Se calcula en el móvil con la posición del sol
// (la "ecuación del amanecer"): sin internet y sin servicios de pago.
//
// Es una ESTIMACIÓN: el resultado se puede ir un par de minutos por el
// relieve o las nubes, y la app lo dice ("estimada").
import 'dart:math' as math;

import '../map/geo.dart';

/// La puesta de sol de [day] en [at], en hora UTC. null si ese día no se
/// pone el sol (verano o invierno polar).
DateTime? sunsetUtc(DateTime day, GeoPoint at) {
  double rad(double d) => d * math.pi / 180;
  double deg(double r) => r * 180 / math.pi;
  // Día juliano de ese día a las 00:00 UTC (el calendario de los astrónomos).
  final DateTime start = DateTime.utc(day.year, day.month, day.day);
  final double julian = start.millisecondsSinceEpoch / 86400000 + 2440587.5;
  final double n = (julian - 2451545.0 + 0.0008).ceilToDouble();
  // Mediodía solar medio en esa longitud.
  final double jStar = n - at.lon / 360;
  // Dónde está la Tierra en su órbita y cuánto se "adelanta" el sol.
  final double m = (357.5291 + 0.98560028 * jStar) % 360;
  final double c =
      1.9148 * math.sin(rad(m)) +
      0.02 * math.sin(rad(2 * m)) +
      0.0003 * math.sin(rad(3 * m));
  final double lambda = (m + c + 180 + 102.9372) % 360;
  final double transit =
      2451545.0 +
      jStar +
      0.0053 * math.sin(rad(m)) -
      0.0069 * math.sin(rad(2 * lambda));
  // Lo alto que va el sol ese día (declinación).
  final double sinDecl = math.sin(rad(lambda)) * math.sin(rad(23.4397));
  final double cosDecl = math.cos(math.asin(sinDecl));
  // -0,833°: el sol "toca" el horizonte (radio del sol + refracción).
  final double cosHour =
      (math.sin(rad(-0.833)) - math.sin(rad(at.lat)) * sinDecl) /
      (math.cos(rad(at.lat)) * cosDecl);
  if (cosHour.abs() > 1) return null;
  final double setJulian = transit + deg(math.acos(cosHour)) / 360;
  return DateTime.fromMillisecondsSinceEpoch(
    ((setJulian - 2440587.5) * 86400000).round(),
    isUtc: true,
  );
}

/// Cuándo empieza la hora dorada: media hora antes de la puesta de sol.
DateTime? goldenHour(DateTime day, GeoPoint at) =>
    sunsetUtc(day, at)?.subtract(const Duration(minutes: 30));
