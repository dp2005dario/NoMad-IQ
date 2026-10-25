// "Dormir barato": GET /v1/stays?lat&lon (público, también para invitados).
//
// El servidor devuelve ZONAS (no hoteles con precio): el propio sitio y
// estaciones de tren o metro con alojamientos alrededor. Los precios reales
// se ven en Booking.com con el botón "Ver precios" (ver stays_math.dart).
import '../../core/api_client.dart';
import '../map/geo.dart';

/// Casillas de 0,02° (~2 km), como el servidor: se manda la casilla, no el
/// punto exacto.
const double stayCellDegrees = 0.02;

(double, double) stayCellOf(GeoPoint p) => (
  double.parse(
    ((p.lat / stayCellDegrees).round() * stayCellDegrees).toStringAsFixed(2),
  ),
  double.parse(
    ((p.lon / stayCellDegrees).round() * stayCellDegrees).toStringAsFixed(2),
  ),
);

enum StayBy { walk, train }

class StayZone {
  const StayZone({
    required this.id,
    required this.point,
    required this.km,
    required this.minutes,
    required this.by,
    required this.lodgings,
    required this.budget,
    required this.examples,
    this.name,
  });

  final String id;

  /// La estación (null = junto al sitio, andando).
  final String? name;
  final GeoPoint point;
  final double km;

  /// Minutos ESTIMADOS hasta el sitio (la app lo dice).
  final int minutes;
  final StayBy by;
  final int lodgings;

  /// Albergues, pensiones y moteles (suelen ser lo más barato).
  final int budget;
  final List<String> examples;

  static StayZone? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    final Object? km = json['km'];
    final Object? minutes = json['minutes'];
    final Object? lodgings = json['lodgings'];
    final StayBy? by = switch (json['by']) {
      'walk' => StayBy.walk,
      'train' => StayBy.train,
      _ => null,
    };
    if (id is! String ||
        lat is! num ||
        lon is! num ||
        km is! num ||
        minutes is! int ||
        lodgings is! int ||
        by == null) {
      return null;
    }
    final Object? name = json['name'];
    final Object? budget = json['budget'];
    final Object? examples = json['examples'];
    return StayZone(
      id: id,
      name: name is String && name.isNotEmpty ? name : null,
      point: GeoPoint(lat.toDouble(), lon.toDouble()),
      km: km.toDouble(),
      minutes: minutes,
      by: by,
      lodgings: lodgings,
      budget: budget is int ? budget : 0,
      examples: <String>[
        if (examples is List<Object?>)
          for (final Object? e in examples.take(3))
            if (e is String) e,
      ],
    );
  }
}

class StayArea {
  const StayArea({required this.zones, required this.attribution});

  final List<StayZone> zones;
  final String attribution;

  static StayArea parse(Object? json) {
    if (json is! Map<String, Object?> || json['zones'] is! List) {
      throw const ApiException(ApiError.unavailable);
    }
    final Object? attribution = json['attribution'];
    return StayArea(
      zones: <StayZone>[
        for (final Object? z in json['zones']! as List<Object?>)
          ?StayZone.parse(z),
      ],
      attribution: attribution is String
          ? attribution
          : '© OpenStreetMap contributors',
    );
  }
}

class StaysApi {
  const StaysApi(this._api);

  final ApiClient _api;

  Future<StayArea> around(GeoPoint target) async {
    final (double lat, double lon) = stayCellOf(target);
    return StayArea.parse(
      await _api.getJson(
        '/v1/stays',
        query: <String, String>{'lat': '$lat', 'lon': '$lon'},
        public: true,
      ),
    );
  }
}
