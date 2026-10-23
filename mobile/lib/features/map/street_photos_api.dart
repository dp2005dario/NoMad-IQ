// Fotos reales de la calle (ai-orchestrator, a través de la puerta de entrada):
//   GET /v1/streetview?lat=40.417&lon=-3.704  → fotos de Mapillary cercanas
//
// Es una ruta pública (también para invitados). Por privacidad, la app manda
// el punto YA redondeado a ~100 m (3 decimales): el servidor nunca sabe el
// sitio exacto que miras. Aquí se valida todo lo que llega.
import '../../core/api_client.dart';
import 'geo.dart';

/// Una foto de la calle hecha por alguien de la comunidad de Mapillary.
class StreetPhoto {
  const StreetPhoto({
    required this.id,
    required this.point,
    required this.thumbUrl,
    required this.imageUrl,
    required this.pageUrl,
    this.capturedAt,
    this.compassAngle,
    this.isPano = false,
    this.creator,
  });

  final String id;
  final GeoPoint point;
  final Uri thumbUrl;
  final Uri imageUrl;

  /// Su página en Mapillary (autor, licencia y las fotos de alrededor).
  final Uri pageUrl;
  final DateTime? capturedAt;

  /// Hacia dónde miraba la cámara (0 = norte, 90 = este).
  final double? compassAngle;

  /// Panorámica de 360°: se mira arrastrando el dedo.
  final bool isPano;
  final String? creator;

  static StreetPhoto? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    final Uri? thumb = _https(json['thumb_url']);
    final Uri? image = _https(json['image_url']);
    final Uri? page = _https(json['page_url']);
    if (id is! String || lat is! num || lon is! num) return null;
    if (thumb == null || image == null || page == null) return null;
    final GeoPoint point = GeoPoint(lat.toDouble(), lon.toDouble());
    if (!point.isValid) return null;
    final Object? captured = json['captured_at'];
    final Object? angle = json['compass_angle'];
    final Object? creator = json['creator'];
    return StreetPhoto(
      id: id,
      point: point,
      thumbUrl: thumb,
      imageUrl: image,
      pageUrl: page,
      capturedAt: captured is String ? DateTime.tryParse(captured) : null,
      compassAngle: angle is num ? angle.toDouble() : null,
      isPano: json['is_pano'] == true,
      creator: creator is String && creator.trim().isNotEmpty ? creator : null,
    );
  }
}

class StreetPhotos {
  const StreetPhotos({
    required this.photos,
    required this.attribution,
    required this.licenseUrl,
  });

  final List<StreetPhoto> photos;

  /// Lo que pide la licencia que se vea junto a las fotos.
  final String attribution;
  final Uri? licenseUrl;

  static StreetPhotos parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? list = json['photos'];
    final Object? attribution = json['attribution'];
    if (list is! List<Object?> || attribution is! String) _bad();
    return StreetPhotos(
      photos: <StreetPhoto>[
        for (final Object? p in list)
          if (StreetPhoto.parse(p) case final StreetPhoto photo) photo,
      ],
      attribution: attribution,
      licenseUrl: _https(json['license_url']),
    );
  }
}

/// Solo enlaces https (nada de "javascript:" ni direcciones locales).
Uri? _https(Object? v) {
  if (v is! String) return null;
  final Uri? u = Uri.tryParse(v);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty ? u : null;
}

Never _bad() => throw const ApiException(ApiError.unavailable);

/// Lo que necesita la pantalla: dame fotos de la calle cerca de este punto.
/// Devuelve null si el servidor no tiene el servicio activado.
typedef StreetPhotoLoader = Future<StreetPhotos?> Function(GeoPoint point);

/// El punto redondeado a ~100 m (3 decimales), que es lo único que sale del
/// móvil. Dos puntos de la misma manzana dan la misma casilla.
GeoPoint streetCell(GeoPoint p) => GeoPoint(
  (p.lat * 1000).roundToDouble() / 1000,
  (p.lon * 1000).roundToDouble() / 1000,
);

class StreetPhotosApi {
  StreetPhotosApi(this._api);

  final ApiClient _api;
  final Map<String, Future<StreetPhotos?>> _memo =
      <String, Future<StreetPhotos?>>{};

  /// Las fotos de la casilla. Se recuerdan mientras la app está abierta;
  /// los fallos NO (se reintenta la próxima vez).
  Future<StreetPhotos?> near(GeoPoint point) {
    final GeoPoint cell = streetCell(point);
    final String lat = cell.lat.toStringAsFixed(3);
    final String lon = cell.lon.toStringAsFixed(3);
    final String key = '$lat,$lon';
    return _memo[key] ??= _fetch(lat, lon).catchError((Object e) {
      _memo.remove(key);
      throw e;
    });
  }

  Future<StreetPhotos?> _fetch(String lat, String lon) async {
    try {
      final Object? json = await _api.getJson(
        '/v1/streetview',
        query: <String, String>{'lat': lat, 'lon': lon},
        public: true,
      );
      return StreetPhotos.parse(json);
    } on ApiException catch (e) {
      // 404: este servidor no tiene las fotos de calle activadas.
      if (e.error == ApiError.notFound) return null;
      rethrow;
    }
  }
}
