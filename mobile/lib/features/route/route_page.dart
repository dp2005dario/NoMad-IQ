// Lo que la app le da a la página de la "Ruta del vuelo" (la maqueta, en
// assets/route/ruta.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';
import 'dart:typed_data';

import 'geo.dart';
import 'world_data.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String routePage = 'assets/route/ruta.html';
const String routeMarker = '/*ECLIPTA*/{}';

/// Un punto en el mapa de la maqueta: 1 grado = 1 punto
/// (x = longitud + 180, y = 90 − latitud).
List<double> mapPoint(LatLon p) => <double>[
  double.parse((p.lon + 180).toStringAsFixed(2)),
  double.parse((90 - p.lat).toStringAsFixed(2)),
];

/// El camino para la página: como mucho [max] puntos (el de la app tiene
/// 129 y no hacen falta tantos para una línea).
List<List<double>> mapPath(List<LatLon> route, {int max = 48}) {
  if (route.length <= max) {
    return <List<double>>[for (final LatLon p in route) mapPoint(p)];
  }
  return <List<double>>[
    for (int i = 0; i < max; i++)
      mapPoint(route[(i * (route.length - 1) / (max - 1)).round()]),
  ];
}

/// ¿Está [p] en tierra? (dentro de algún contorno del mapa de la app).
bool onLand(WorldShapes shapes, LatLon p) {
  for (final Float32List ring in shapes.rings) {
    // Regla par-impar: cuántas veces cruza una línea hacia el este.
    bool inside = false;
    final int n = ring.length ~/ 2;
    for (int i = 0, j = n - 1; i < n; j = i++) {
      final double xi = ring[i * 2], yi = ring[i * 2 + 1];
      final double xj = ring[j * 2], yj = ring[j * 2 + 1];
      if ((yi > p.lat) != (yj > p.lat) &&
          p.lon < (xj - xi) * (p.lat - yi) / (yj - yi) + xi) {
        inside = !inside;
      }
    }
    if (inside) return true;
  }
  return false;
}

/// Por dónde pasa el avión, por tramos: (desde qué parte del vuelo, texto).
/// [over] dice el texto de un punto del camino (país o mar).
List<(double, String)> regionsAlong(
  List<LatLon> route,
  String Function(LatLon p) over, {
  required String leaving,
  required String arriving,
  int steps = 16,
}) {
  final List<(double, String)> out = <(double, String)>[(0, leaving)];
  if (route.length < 2) return out;
  for (int i = 1; i < steps; i++) {
    final double at = i / steps;
    if (at > 0.92) break;
    final LatLon p = route[(at * (route.length - 1)).round()];
    final String label = over(p);
    if (label != out.last.$2) out.add((at, label));
  }
  out.add((0.94, arriving));
  return out;
}

/// La página lista para enseñar.
String routePageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(routeMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String routePushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
