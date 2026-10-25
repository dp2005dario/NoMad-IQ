// "Cerca de ti": la app pregunta al ai-orchestrator
//   GET /v1/nearby?lat=40.42&lon=-3.70
// y él saca de OpenStreetMap (gratis) el agua potable, los baños, el wifi
// gratis, dónde cargar el móvil y los sitios que ver, con una semana de caché.
//
// Igual que los cajeros: se manda el punto YA REDONDEADO a ~1 km. Las
// distancias se calculan aquí, con tu posición de verdad.
import '../../core/api_client.dart';
import '../map/geo.dart';

enum NearbyKind {
  water,
  toilets,
  wifi,
  charging,
  sight,

  /// Restaurante que, según OpenStreetMap, acepta reservas (para "Colas").
  table;

  static NearbyKind? parse(Object? raw) {
    for (final NearbyKind k in values) {
      if (k.name == raw) return k;
    }
    return null;
  }
}

class NearbySpot {
  const NearbySpot({
    required this.id,
    required this.kind,
    required this.point,
    this.name,
    this.openingHours,
    this.fee,
    this.wikidataId,
    this.website,
    this.phone,
    this.cuisine,
    this.reservationRequired = false,
  });

  final String id;
  final NearbyKind kind;
  final GeoPoint point;
  final String? name;
  final String? openingHours;

  /// ¿Cuesta dinero? null = OpenStreetMap no lo sabe.
  final bool? fee;
  final String? wikidataId;

  /// Solo restaurantes: su web (siempre https) y su teléfono para reservar.
  final Uri? website;
  final String? phone;
  final String? cuisine;

  /// true = OpenStreetMap dice que sin reserva no entras.
  final bool reservationRequired;

  static NearbySpot? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final NearbyKind? kind = NearbyKind.parse(json['kind']);
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
    final String? qid = text('wikidata_id');
    final Uri? web = Uri.tryParse(text('website') ?? '');
    final String? phone = text('phone');
    return NearbySpot(
      id: id,
      kind: kind,
      point: p,
      name: text('name'),
      openingHours: text('opening_hours'),
      fee: fee is bool ? fee : null,
      wikidataId: qid != null && RegExp(r'^Q[1-9]\d{0,11}$').hasMatch(qid)
          ? qid
          : null,
      // Solo enlaces https y teléfonos con pinta de teléfono: nada raro.
      website: web != null && web.scheme == 'https' && web.host.isNotEmpty
          ? web
          : null,
      phone: phone != null && RegExp(r'^\+?[0-9 ()./-]{6,24}$').hasMatch(phone)
          ? phone
          : null,
      cuisine: text('cuisine'),
      reservationRequired: json['reservation'] == 'required',
    );
  }
}

class NearbyList {
  const NearbyList({required this.spots, required this.attribution});

  final List<NearbySpot> spots;
  final String attribution;

  /// Los de un tipo, del más cercano al más lejano.
  List<NearbySpot> of(NearbyKind kind, GeoPoint me) =>
      spots.where((NearbySpot s) => s.kind == kind).toList()..sort(
        (NearbySpot a, NearbySpot b) =>
            a.point.distanceTo(me).compareTo(b.point.distanceTo(me)),
      );

  static NearbyList parse(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    final Object? spots = json['spots'];
    final Object? attribution = json['attribution'];
    if (spots is! List<Object?> || attribution is! String) {
      throw const ApiException(ApiError.unavailable);
    }
    return NearbyList(
      spots: <NearbySpot>[
        for (final Object? s in spots.take(400)) ?NearbySpot.parse(s),
      ],
      attribution: attribution,
    );
  }
}

class NearbyApi {
  NearbyApi(this._api);

  final ApiClient _api;

  /// Lo que hay en la zona (~3 km alrededor de tu casilla de ~1 km).
  Future<NearbyList> near(GeoPoint me) async => NearbyList.parse(
    await _api.getJson(
      '/v1/nearby',
      query: <String, String>{
        'lat': me.lat.toStringAsFixed(2),
        'lon': me.lon.toStringAsFixed(2),
      },
      public: true,
    ),
  );
}
