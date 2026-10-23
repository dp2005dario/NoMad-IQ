// Piezas básicas del mapa: un punto, un rectángulo y una zona (con su forma).
// Todo es Dart puro (sin pantallas ni red), así se prueba fácil y rápido.
import 'dart:math' as math;

/// Un punto en la Tierra. Latitud: norte/sur (-90..90). Longitud: este/oeste
/// (-180..180). Ojo: GeoJSON los escribe al revés, [longitud, latitud].
class GeoPoint {
  const GeoPoint(this.lat, this.lon);

  final double lat;
  final double lon;

  bool get isValid =>
      lat.isFinite &&
      lon.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lon >= -180 &&
      lon <= 180;

  /// Distancia en metros (fórmula del haversine: la Tierra como esfera).
  /// Para distancias de una ciudad el error es de centímetros.
  double distanceTo(GeoPoint other) {
    const double earthRadius = 6371000;
    double rad(double deg) => deg * math.pi / 180;
    final double dLat = rad(other.lat - lat);
    final double dLon = rad(other.lon - lon);
    final double a =
        math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(lat)) *
            math.cos(rad(other.lat)) *
            math.pow(math.sin(dLon / 2), 2);
    return 2 * earthRadius * math.asin(math.min(1, math.sqrt(a)));
  }

  @override
  bool operator ==(Object other) =>
      other is GeoPoint && other.lat == lat && other.lon == lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() => 'GeoPoint($lat, $lon)';
}

/// El rectángulo de mapa que se ve en pantalla ("bbox").
class GeoBox {
  const GeoBox({
    required this.minLon,
    required this.minLat,
    required this.maxLon,
    required this.maxLat,
  });

  final double minLon;
  final double minLat;
  final double maxLon;
  final double maxLat;

  /// El servidor no da zonas de rectángulos de más de 2° de lado (unos
  /// 220 km): con el mapa tan alejado no se distinguirían.
  static const double maxSpanDeg = 2.0;

  double get lonSpan => maxLon - minLon;
  double get latSpan => maxLat - minLat;

  bool get isValid =>
      minLon.isFinite &&
      minLat.isFinite &&
      maxLon.isFinite &&
      maxLat.isFinite &&
      minLon >= -180 &&
      maxLon <= 180 &&
      minLat >= -90 &&
      maxLat <= 90 &&
      minLon < maxLon &&
      minLat < maxLat;

  /// ¿Se le pueden pedir zonas al servidor?
  bool get fitsServerLimit =>
      isValid && lonSpan <= maxSpanDeg && latSpan <= maxSpanDeg;

  GeoPoint get center => GeoPoint((minLat + maxLat) / 2, (minLon + maxLon) / 2);

  bool contains(GeoPoint p) =>
      p.lat >= minLat && p.lat <= maxLat && p.lon >= minLon && p.lon <= maxLon;

  bool containsBox(GeoBox other) =>
      other.minLon >= minLon &&
      other.maxLon <= maxLon &&
      other.minLat >= minLat &&
      other.maxLat <= maxLat;

  /// El mismo centro, [factor] veces más grande, sin pasarse del límite del
  /// servidor ni de los bordes del mundo. Pedimos un poco más de lo que se ve
  /// para que al mover un poco el mapa no haya que volver a preguntar.
  GeoBox grow(double factor) {
    final double halfLon = math.min(lonSpan * factor, maxSpanDeg) / 2;
    final double halfLat = math.min(latSpan * factor, maxSpanDeg) / 2;
    final GeoPoint c = center;
    return GeoBox(
      minLon: math.max(-180, c.lon - halfLon),
      minLat: math.max(-90, c.lat - halfLat),
      maxLon: math.min(180, c.lon + halfLon),
      maxLat: math.min(90, c.lat + halfLat),
    );
  }

  /// Formato que entiende el servidor: "minLon,minLat,maxLon,maxLat".
  String toQuery() => <double>[
    minLon,
    minLat,
    maxLon,
    maxLat,
  ].map((double v) => v.toStringAsFixed(5)).join(',');

  @override
  String toString() => 'GeoBox(${toQuery()})';
}

/// Tipos de zona del geo-engine. Solo el centro de ciudad y las zonas
/// turísticas tienen audioguía; aeropuertos y zonas restringidas, no.
enum ZoneKind {
  cityCenter('city_center'),
  touristArea('tourist_area'),
  airport('airport'),
  restricted('restricted');

  const ZoneKind(this.wire);

  /// Cómo se escribe en el JSON del servidor.
  final String wire;

  bool get hasAudioguide =>
      this == ZoneKind.cityCenter || this == ZoneKind.touristArea;

  static ZoneKind? fromWire(Object? value) {
    for (final ZoneKind kind in ZoneKind.values) {
      if (kind.wire == value) return kind;
    }
    return null;
  }
}

/// Un anillo es una línea cerrada de puntos (el borde de un polígono).
typedef Ring = List<GeoPoint>;

/// Un polígono: el primer anillo es el borde de fuera; los demás, "agujeros".
typedef Polygon = List<Ring>;

/// Una zona del mapa (Puerta del Sol, el aeropuerto de Barajas...).
class Zone {
  const Zone({
    required this.id,
    required this.slug,
    required this.name,
    required this.kind,
    required this.polygons,
  });

  final String id;
  final String slug;
  final String name;
  final ZoneKind kind;

  /// Una zona puede tener varias partes separadas (MultiPolygon).
  final List<Polygon> polygons;

  /// Lee una zona del GeoJSON del servidor. Si algo no cuadra devuelve null:
  /// una zona rota no debe tumbar el mapa entero, simplemente no se pinta.
  static Zone? fromFeature(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? props = json['properties'];
    final Object? geometry = json['geometry'];
    if (id is! String || id.isEmpty) return null;
    if (props is! Map<String, Object?> || geometry is! Map<String, Object?>) {
      return null;
    }
    final Object? slug = props['slug'];
    final Object? name = props['name'];
    final ZoneKind? kind = ZoneKind.fromWire(props['kind']);
    if (slug is! String || name is! String || kind == null) return null;
    if (geometry['type'] != 'MultiPolygon') return null;
    final List<Polygon>? polygons = _polygons(geometry['coordinates']);
    if (polygons == null || polygons.isEmpty) return null;
    return Zone(id: id, slug: slug, name: name, kind: kind, polygons: polygons);
  }

  /// ¿Está el punto dentro de la zona (y fuera de sus agujeros)?
  bool contains(GeoPoint p) {
    for (final Polygon polygon in polygons) {
      if (!_inRing(p, polygon.first)) continue;
      final bool inHole = polygon.skip(1).any((Ring hole) => _inRing(p, hole));
      if (!inHole) return true;
    }
    return false;
  }

  /// El rectángulo que la envuelve.
  GeoBox get bounds {
    double minLon = 180, minLat = 90, maxLon = -180, maxLat = -90;
    for (final Polygon polygon in polygons) {
      for (final GeoPoint p in polygon.first) {
        minLon = math.min(minLon, p.lon);
        maxLon = math.max(maxLon, p.lon);
        minLat = math.min(minLat, p.lat);
        maxLat = math.max(maxLat, p.lat);
      }
    }
    return GeoBox(
      minLon: minLon,
      minLat: minLat,
      maxLon: maxLon,
      maxLat: maxLat,
    );
  }

  /// La zona en GeoJSON para dibujarla en el mapa. Lleva el id ARRIBA
  /// (MapLibre en Android/iOS lo exige ahí) y propiedades sencillas que usa
  /// el estilo del mapa para elegir colores.
  Map<String, Object?> toFeature({bool selected = false}) => <String, Object?>{
    'type': 'Feature',
    'id': id,
    'geometry': <String, Object?>{
      'type': 'MultiPolygon',
      'coordinates': <Object?>[
        for (final Polygon polygon in polygons)
          <Object?>[
            for (final Ring ring in polygon)
              <Object?>[
                for (final GeoPoint p in ring) <double>[p.lon, p.lat],
              ],
          ],
      ],
    },
    'properties': <String, Object?>{
      'name': name,
      'kind': kind.wire,
      'selected': selected,
    },
  };

  // Algoritmo del "rayo": desde el punto se traza una línea hacia el este y
  // se cuentan los bordes que cruza. Impar = dentro, par = fuera.
  static bool _inRing(GeoPoint p, Ring ring) {
    bool inside = false;
    for (int i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final GeoPoint a = ring[i];
      final GeoPoint b = ring[j];
      final bool crosses =
          (a.lat > p.lat) != (b.lat > p.lat) &&
          p.lon < (b.lon - a.lon) * (p.lat - a.lat) / (b.lat - a.lat) + a.lon;
      if (crosses) inside = !inside;
    }
    return inside;
  }

  static List<Polygon>? _polygons(Object? coordinates) {
    if (coordinates is! List<Object?>) return null;
    final List<Polygon> polygons = <Polygon>[];
    for (final Object? polygon in coordinates) {
      if (polygon is! List<Object?> || polygon.isEmpty) return null;
      final Polygon rings = <Ring>[];
      for (final Object? ring in polygon) {
        if (ring is! List<Object?> || ring.length < 4) return null;
        final Ring points = <GeoPoint>[];
        for (final Object? pair in ring) {
          if (pair is! List<Object?> || pair.length < 2) return null;
          final Object? lon = pair[0];
          final Object? lat = pair[1];
          if (lon is! num || lat is! num) return null;
          final GeoPoint p = GeoPoint(lat.toDouble(), lon.toDouble());
          if (!p.isValid) return null;
          points.add(p);
        }
        rings.add(points);
      }
      polygons.add(rings);
    }
    return polygons;
  }
}

/// Una posición del GPS, tal como la manda la app al servidor.
class PositionFix {
  const PositionFix({
    required this.point,
    required this.accuracyM,
    required this.recordedAt,
  });

  final GeoPoint point;

  /// Radio de error del GPS en metros (8 = "estás en un círculo de 8 m").
  final double accuracyM;
  final DateTime recordedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'lat': point.lat,
    'lon': point.lon,
    'accuracy_m': accuracyM,
    'recorded_at_ms': recordedAt.millisecondsSinceEpoch,
  };
}
