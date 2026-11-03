// «¿Qué os apetece?» (pantalla Grupo): GET /v1/cravings?lat&lon&kind.
//
// El servidor pregunta a OpenStreetMap por los sitios de un antojo (tapas,
// pescado, vegetariano, café o vistas) alrededor de la casilla de ~1 km que
// mandamos (nunca el punto exacto). Solo llegan nombre, sitio y horario: sin
// reseñas, sin "lo más popular" y sin precios (eso no es gratis).
import '../../core/api_client.dart';
import '../map/geo.dart';

/// Los antojos de la maqueta, en su orden.
enum Craving { tapas, fish, veggie, cafe, views }

/// "A un paseo": la app solo enseña lo que está a 1 km o menos.
const double cravingRadiusM = 1000;

/// Andando, unos 80 metros por minuto (paso tranquilo de turista).
int walkMinutes(double meters) => (meters / 80).ceil().clamp(1, 999);

class CravingSpot {
  const CravingSpot({
    required this.id,
    required this.name,
    required this.point,
    this.openingHours,
    this.cuisine,
  });

  /// "n123": el sitio en OpenStreetMap.
  final String id;
  final String name;
  final GeoPoint point;
  final String? openingHours;
  final String? cuisine;

  static CravingSpot? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? name = json['name'];
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    if (id is! String || name is! String || name.isEmpty) return null;
    if (lat is! num || lon is! num || lat.abs() > 90 || lon.abs() > 180) {
      return null;
    }
    String? text(String key) {
      final Object? v = json[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    return CravingSpot(
      id: id,
      name: name,
      point: GeoPoint(lat.toDouble(), lon.toDouble()),
      openingHours: text('opening_hours'),
      cuisine: text('cuisine'),
    );
  }
}

class CravingsApi {
  const CravingsApi(this._api);

  final ApiClient _api;

  /// Los sitios de [kind] cerca de [at] (lista vacía si no hay).
  Future<List<CravingSpot>> near(GeoPoint at, Craving kind) async {
    final Object? json = await _api.getJson(
      '/v1/cravings',
      query: <String, String>{
        // La casilla de ~1 km, como "Cerca de ti": no el punto exacto.
        'lat': at.lat.toStringAsFixed(2),
        'lon': at.lon.toStringAsFixed(2),
        'kind': kind.name,
      },
      public: true,
    );
    if (json is! Map<String, Object?> || json['spots'] is! List) {
      throw const ApiException(ApiError.unavailable);
    }
    return <CravingSpot>[
      for (final Object? s in json['spots']! as List<Object?>)
        ?CravingSpot.parse(s),
    ];
  }
}
