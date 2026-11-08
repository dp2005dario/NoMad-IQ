// Lo que la app le da a la página de "Modo coche" (la maqueta, en
// assets/drive/coche.html): la flecha hacia el sitio, las etiquetas del mapa
// y las tarjetas de cada modo.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import '../airport/airport_guide.dart' show bearingTo;
import '../map/geo.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String drivePage = 'assets/drive/coche.html';
const String driveMarker = '/*ECLIPTA*/{}';

/// Hacia dónde queda un sitio: la flecha de la página ("left", "right",
/// "ahead" o "back") y las palabras ("a tu izquierda", "hacia el norte"...).
///
/// No es la ruta por carretera (eso lo hace Google Maps al tocar "Ir"): es
/// hacia dónde queda en línea recta. Con [heading] (hacia dónde vas, en
/// grados) se dice respecto a ti; sin él, con los puntos cardinales.
(String, String) directionTo(GeoPoint me, GeoPoint to, double? heading) {
  final double bearing = bearingTo(me, to);
  if (heading == null) {
    const List<String> names = <String>[
      'hacia el norte',
      'hacia el noreste',
      'hacia el este',
      'hacia el sureste',
      'hacia el sur',
      'hacia el suroeste',
      'hacia el oeste',
      'hacia el noroeste',
    ];
    return ('ahead', names[((bearing % 360) / 45).round() % 8]);
  }
  // De -180 a 180: negativo es a la izquierda.
  final double r = ((bearing - heading) % 360 + 540) % 360 - 180;
  if (r.abs() <= 30) return ('ahead', 'todo recto');
  if (r.abs() >= 150) return ('back', 'detrás de ti');
  return r < 0 ? ('left', 'a tu izquierda') : ('right', 'a tu derecha');
}

/// Hacia dónde vas, si te has movido lo bastante entre [before] y [now]
/// (con el coche parado, el GPS "baila" y no vale).
double? headingOf(GeoPoint? before, GeoPoint now) =>
    before == null || before.distanceTo(now) < 25
    ? null
    : bearingTo(before, now);

/// La página lista para enseñar.
String drivePageWith(String page, Map<String, Object?> data) =>
    // "<" como <: ningún dato puede cerrar el script.
    page.replaceFirst(driveMarker, jsonEncode(data).replaceAll('<', r'<'));

/// Lo que se le manda a la página sin recargarla.
String drivePushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'<')})';
