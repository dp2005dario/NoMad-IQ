// Modo coche: la app pregunta al ai-orchestrator
//   GET /v1/drive?lat=40.65&lon=14.50
// y él saca de OpenStreetMap (gratis) gasolineras, aparcamientos, cargadores
// eléctricos y zonas de tráfico limitado (ZTL, ZBE...) en ~16 km alrededor.
//
// Se manda el punto YA REDONDEADO a la casilla de ~5 km: en coche basta, y
// el servidor nunca sabe por qué calle vas. Las distancias se calculan aquí.
import '../../core/api_client.dart';
import '../map/geo.dart';

/// Tamaño de la casilla (igual que el servidor: drive/domain.py).
const double driveCellDegrees = 0.05;

enum DriveKind {
  fuel,
  parking,
  ev,
  lez;

  static DriveKind? parse(Object? raw) {
    for (final DriveKind k in values) {
      if (k.name == raw) return k;
    }
    return null;
  }
}

/// El centro de la casilla de ~5 km donde cae [p].
GeoPoint driveCellOf(GeoPoint p) {
  double snap(double v) => double.parse(
    ((v / driveCellDegrees).round() * driveCellDegrees).toStringAsFixed(2),
  );
  return GeoPoint(snap(p.lat), snap(p.lon));
}

class DriveSpot {
  const DriveSpot({
    required this.id,
    required this.kind,
    required this.point,
    this.name,
    this.brand,
    this.openingHours,
    this.fee,
    this.capacity,
    this.website,
  });

  final String id;
  final DriveKind kind;
  final GeoPoint point;
  final String? name;

  /// "Repsol", "Enel X"...
  final String? brand;
  final String? openingHours;
  final bool? fee;

  /// Plazas totales (no libres: eso no lo sabe nadie gratis).
  final int? capacity;

  /// La web oficial de una zona ZTL/ZBE (solo https).
  final Uri? website;

  String? get label => name ?? brand;

  static DriveSpot? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final DriveKind? kind = DriveKind.parse(json['kind']);
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    if (id is! String ||
        !RegExp(r'^[nwr][1-9][0-9]{0,15}$').hasMatch(id) ||
        kind == null ||
        lat is! num ||
        lon is! num) {
      return null;
    }
    final GeoPoint p = GeoPoint(lat.toDouble(), lon.toDouble());
    if (!p.isValid) return null;
    String? text(String key) {
      final Object? v = json[key];
      return v is String && v.trim().isNotEmpty ? v : null;
    }

    final Object? fee = json['fee'];
    final Object? capacity = json['capacity'];
    final Uri? web = Uri.tryParse(text('website') ?? '');
    return DriveSpot(
      id: id,
      kind: kind,
      point: p,
      name: text('name'),
      brand: text('brand'),
      openingHours: text('opening_hours'),
      fee: fee is bool ? fee : null,
      capacity: capacity is int && capacity > 0 ? capacity : null,
      website: web != null && web.scheme == 'https' && web.host.isNotEmpty
          ? web
          : null,
    );
  }
}

class DriveArea {
  const DriveArea({
    required this.cell,
    required this.spots,
    required this.attribution,
  });

  final GeoPoint cell;
  final List<DriveSpot> spots;
  final String attribution;

  /// Los de un tipo, del más cercano al más lejano.
  List<DriveSpot> of(DriveKind kind, GeoPoint me) =>
      spots.where((DriveSpot s) => s.kind == kind).toList()..sort(
        (DriveSpot a, DriveSpot b) =>
            a.point.distanceTo(me).compareTo(b.point.distanceTo(me)),
      );

  static DriveArea parse(GeoPoint cell, Object? json) {
    if (json is! Map<String, Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    final Object? spots = json['spots'];
    final Object? attribution = json['attribution'];
    if (spots is! List<Object?> || attribution is! String) {
      throw const ApiException(ApiError.unavailable);
    }
    return DriveArea(
      cell: cell,
      spots: <DriveSpot>[
        for (final Object? s in spots.take(500)) ?DriveSpot.parse(s),
      ],
      attribution: attribution,
    );
  }
}

class DriveApi {
  DriveApi(this._api);

  final ApiClient _api;

  /// Lo que hay en ~16 km alrededor de la casilla de [me].
  Future<DriveArea> around(GeoPoint me) async {
    final GeoPoint cell = driveCellOf(me);
    return DriveArea.parse(
      cell,
      await _api.getJson(
        '/v1/drive',
        query: <String, String>{
          'lat': cell.lat.toStringAsFixed(2),
          'lon': cell.lon.toStringAsFixed(2),
        },
        public: true,
      ),
    );
  }
}
