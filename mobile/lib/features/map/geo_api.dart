// Las dos llamadas del mapa al geo-engine (a través de la puerta de entrada):
//   GET  /v1/zones?bbox=...   → las zonas que se ven en pantalla (GeoJSON)
//   POST /v1/positions        → un lote de posiciones del GPS
import '../../core/api_client.dart';
import 'geo.dart';

/// Lo que devuelve una consulta de zonas.
class ZonePage {
  const ZonePage({required this.zones, required this.truncated});

  final List<Zone> zones;

  /// true si había más de las que caben en una respuesta (300): hay que
  /// acercar el mapa para verlas todas.
  final bool truncated;
}

class GeoApi {
  GeoApi(this._api);

  final ApiClient _api;

  /// Máximo de posiciones por lote que acepta el servidor.
  static const int maxBatch = 50;

  Future<ZonePage> zones(GeoBox box) async {
    if (!box.fitsServerLimit) {
      throw const ApiException(ApiError.invalidInput);
    }
    final Object? json = await _api.getJson(
      '/v1/zones',
      query: <String, String>{'bbox': box.toQuery()},
    );
    if (json is! Map<String, Object?> || json['features'] is! List<Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    final List<Zone> zones = <Zone>[
      for (final Object? feature in json['features']! as List<Object?>)
        ?Zone.fromFeature(feature),
    ];
    return ZonePage(zones: zones, truncated: json['truncated'] == true);
  }

  /// Manda un lote. Devuelve cuántas posiciones aceptó el servidor.
  /// [language] es el idioma de la app ("es"): con él, la audioguía que
  /// prepare el servidor al entrar en una zona sale en tu idioma.
  Future<int> sendPositions(String language, List<PositionFix> fixes) async {
    if (fixes.isEmpty) return 0;
    if (fixes.length > maxBatch) {
      throw const ApiException(ApiError.invalidInput);
    }
    final Object? json = await _api.postJson('/v1/positions', <String, Object?>{
      'language': language,
      'positions': <Object?>[for (final PositionFix f in fixes) f.toJson()],
    });
    final Object? accepted = json is Map<String, Object?>
        ? json['accepted']
        : null;
    if (accepted is! int) throw const ApiException(ApiError.unavailable);
    return accepted;
  }
}
