// Buscar un sitio por su nombre o su dirección ("Hotel Avenida Palace,
// Lisboa"): GET /v1/geocode. Lo busca el servidor en OpenStreetMap
// (Nominatim) y solo con cuenta, para no pasarse del límite de uso gratis
// (1 búsqueda por segundo).
//
// Nominatim encuentra lo que está en el mapa, no adivina: si el nombre está
// mal escrito o el hotel no está en OpenStreetMap, sale vacío. Por eso la app
// siempre te enseña lo que encontró para que TÚ elijas el bueno.
import '../../core/api_client.dart';
import 'geo.dart';

class GeoPlace {
  const GeoPlace({
    required this.name,
    required this.address,
    required this.point,
  });

  /// "Avenida Palace".
  final String name;

  /// "Rua 1º de Dezembro 123, Lisboa, Portugal".
  final String address;
  final GeoPoint point;

  static GeoPlace? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? name = json['name'];
    final Object? address = json['address'];
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    if (name is! String || address is! String) return null;
    if (lat is! num || lon is! num) return null;
    if (lat.abs() > 90 || lon.abs() > 180) return null;
    return GeoPlace(
      name: name,
      address: address,
      point: GeoPoint(lat.toDouble(), lon.toDouble()),
    );
  }
}

class GeocodeApi {
  const GeocodeApi(this._api);

  final ApiClient _api;

  /// Busca [query], mejor cerca de [near] (la ciudad del viaje).
  Future<List<GeoPlace>> search(String query, {GeoPoint? near}) async {
    final Object? json = await _api.getJson(
      '/v1/geocode',
      query: <String, String>{
        'q': query.trim(),
        if (near != null) 'lat': near.lat.toStringAsFixed(4),
        if (near != null) 'lon': near.lon.toStringAsFixed(4),
      },
    );
    if (json is! Map<String, Object?> || json['items'] is! List) {
      throw const ApiException(ApiError.unavailable);
    }
    return <GeoPlace>[
      for (final Object? p in (json['items']! as List<Object?>).take(10))
        ?GeoPlace.parse(p),
    ];
  }
}
