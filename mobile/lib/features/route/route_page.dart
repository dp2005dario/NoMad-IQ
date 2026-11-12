// Lo que la app le da a la página de la "Ruta del vuelo" (la maqueta, en
// assets/route/ruta.html).
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';
import 'dart:typed_data';

import '../map/map_style.dart';
import 'geo.dart';
import 'world_data.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String routePage = 'assets/route/ruta.html';
const String routeMarker = '/*ECLIPTA*/{}';

/// El mapa de verdad (MapLibre, el mismo motor del Mapa de la app, para
/// web) va dentro de la app y se mete en la página aquí.
const String routeMapLib = 'assets/route/maplibre-gl.js';
const String routeLibMarker = '/*MAPLIBRE*/';
const String routeMapMarker = '/*ROUTEMAP*/{}';

/// La página con la librería del mapa y el mapa ([map]: el estilo y la
/// tierra). Se hace una vez; luego [routePageWith] mete los datos.
String routePageWithMap(String page, String lib, Map<String, Object?> map) =>
    page
        .replaceFirst(
          routeMapMarker,
          jsonEncode(map).replaceAll('<', r'\u003c'),
        )
        // La librería no lleva "</script" (lo comprueba un test).
        .replaceFirst(routeLibMarker, lib);

/// El estilo del mapa de la Ruta: el mismo de noche del Mapa de la app
/// (calles, edificios en 3D, nombres en tu idioma), sin los dibujitos que
/// solo tiene la app nativa (árboles, iconos), con el globo terráqueo y
/// con la tierra de los datos de la app debajo: si no hay Internet para
/// las teselas, igual se ven los continentes.
Map<String, Object?> routeMapStyle({
  required Uri tilesUrl,
  required String glyphsUrl,
  required String language,
}) {
  final Map<String, Object?> style = buildMapStyle(
    look: MapLook.night,
    language: language,
    tilesUrl: tilesUrl,
    glyphsUrl: glyphsUrl,
  );
  final Map<String, Object?> sources = <String, Object?>{
    'openmaptiles': (style['sources']! as Map<String, Object?>)['openmaptiles'],
    'land': <String, Object?>{
      'type': 'geojson',
      'data': <String, Object?>{'type': 'FeatureCollection', 'features': []},
    },
  };
  bool usesImages(Map<String, Object?> layer) {
    final Object? paint = layer['paint'];
    final Object? layout = layer['layout'];
    return (paint is Map && paint.containsKey('fill-pattern')) ||
        (layout is Map && layout.containsKey('icon-image'));
  }

  final List<Object?> layers = <Object?>[
    // El mar (el fondo) y la tierra de la app encima.
    <String, Object?>{
      'id': 'background',
      'type': 'background',
      'paint': <String, Object?>{'background-color': '#0A1A2B'},
    },
    <String, Object?>{
      'id': 'land',
      'type': 'fill',
      'source': 'land',
      'maxzoom': 7,
      'paint': <String, Object?>{'fill-color': '#22403A'},
    },
    for (final Object? l in style['layers']! as List<Object?>)
      if (l is Map<String, Object?> &&
          l['id'] != 'background' &&
          (l['source'] == null || l['source'] == 'openmaptiles') &&
          !usesImages(l))
        l,
  ];
  return <String, Object?>{
    ...style,
    'sources': sources,
    'layers': layers,
    'projection': <String, Object?>{'type': 'globe'},
    // El brillo azul de la atmósfera alrededor del globo.
    'sky': <String, Object?>{
      'sky-color': '#0B2747',
      'horizon-color': '#2E6BA8',
      'fog-color': '#0B1217',
      'atmosphere-blend': <Object?>[
        'interpolate',
        <Object?>['linear'],
        <Object?>['zoom'],
        0,
        1,
        5,
        1,
        7,
        0,
      ],
    },
  };
}

/// La tierra (los contornos de assets/geo/world.bin) en GeoJSON, más
/// ligera: como mucho ~160 puntos por contorno y sin islotes diminutos.
Map<String, Object?> landGeoJson(WorldShapes shapes) {
  final List<Object?> polys = <Object?>[];
  for (final Float32List ring in shapes.rings) {
    final int n = ring.length ~/ 2;
    if (n < 4) continue;
    double minX = 999, maxX = -999, minY = 999, maxY = -999;
    for (int i = 0; i < n; i++) {
      final double x = ring[i * 2], y = ring[i * 2 + 1];
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
    if ((maxX - minX) * (maxY - minY) < 1) continue;
    final int step = n > 70 ? (n / 70).ceil() : 1;
    final List<List<double>> pts = <List<double>>[
      for (int i = 0; i < n; i += step)
        <double>[
          double.parse(ring[i * 2].toStringAsFixed(1)),
          double.parse(ring[i * 2 + 1].toStringAsFixed(1)),
        ],
    ];
    if (pts.length < 3) continue;
    pts.add(pts.first);
    polys.add(<Object?>[pts]);
  }
  return <String, Object?>{
    'type': 'Feature',
    'properties': <String, Object?>{},
    'geometry': <String, Object?>{'type': 'MultiPolygon', 'coordinates': polys},
  };
}

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
