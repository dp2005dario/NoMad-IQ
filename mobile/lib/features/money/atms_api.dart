// Cajeros cercanos: la app pregunta al ai-orchestrator
//   GET /v1/atms?lat=35.66&lon=139.70
// y él los saca de OpenStreetMap (gratis), con caché de un día.
//
// La app manda el punto YA REDONDEADO a ~1 km (dos decimales): el servidor
// nunca sabe en qué portal estás. Las distancias se calculan aquí, en el
// móvil, con tu posición de verdad.
import '../../core/api_client.dart';
import '../map/geo.dart';

/// Un cajero, tal y como lo describe OpenStreetMap.
class Atm {
  const Atm({
    required this.id,
    required this.point,
    this.name,
    this.operator,
    this.openingHours,
    this.open24h = false,
    this.fee,
    this.inBank = false,
    this.currencies = const <String>[],
  });

  /// "n123" (un punto del mapa) o "w456" (un edificio).
  final String id;
  final GeoPoint point;
  final String? name;

  /// El banco o la red que lo lleva ("Seven Bank", "Japan Post Bank").
  final String? operator;

  /// El horario tal cual lo escribe OSM ("Mo-Fr 08:00-21:00").
  final String? openingHours;
  final bool open24h;

  /// ¿Cobra comisión? null = OSM no lo sabe.
  final bool? fee;

  /// El cajero de dentro de una oficina (suele cerrar con la oficina).
  final bool inBank;
  final List<String> currencies;

  /// El nombre que se enseña: el del cartel, si no el del banco.
  String? get label => name ?? operator;

  /// Su página en OpenStreetMap (para verlo en el mapa del navegador).
  Uri get mapUrl {
    final String lat = point.lat.toStringAsFixed(5);
    final String lon = point.lon.toStringAsFixed(5);
    return Uri.https('www.openstreetmap.org', '/', <String, String>{
      'mlat': lat,
      'mlon': lon,
    }).replace(fragment: 'map=18/$lat/$lon');
  }

  static Atm? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    if (id is! String ||
        !RegExp(r'^[nwr][1-9][0-9]{0,15}$').hasMatch(id) ||
        lat is! num ||
        lon is! num ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      return null;
    }
    final Object? fee = json['fee'];
    final Object? currencies = json['currencies'];
    return Atm(
      id: id,
      point: GeoPoint(lat.toDouble(), lon.toDouble()),
      name: _text(json['name']),
      operator: _text(json['operator']),
      openingHours: _text(json['opening_hours']),
      open24h: json['open_24h'] == true,
      fee: fee is bool ? fee : null,
      inBank: json['in_bank'] == true,
      currencies: <String>[
        if (currencies is List<Object?>)
          for (final Object? c in currencies)
            if (c is String && RegExp(r'^[A-Z]{3}$').hasMatch(c)) c,
      ],
    );
  }
}

/// La respuesta: los cajeros y a quién hay que citar (licencia de OSM).
class AtmList {
  const AtmList({required this.atms, required this.attribution});

  final List<Atm> atms;
  final String attribution;

  /// Los más cercanos primero; a igualdad, los que no cobran comisión.
  List<Atm> sortedFrom(GeoPoint me) => List<Atm>.of(atms)
    ..sort((Atm a, Atm b) {
      final int byDistance = a.point
          .distanceTo(me)
          .compareTo(b.point.distanceTo(me));
      return byDistance != 0 ? byDistance : _feeRank(a) - _feeRank(b);
    });

  static int _feeRank(Atm a) => a.fee == false
      ? 0
      : a.fee == null
      ? 1
      : 2;

  static AtmList parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? atms = json['atms'];
    final Object? attribution = json['attribution'];
    if (atms is! List<Object?> || attribution is! String) _bad();
    return AtmList(
      atms: <Atm>[
        for (final Object? a in atms)
          if (Atm.parse(a) case final Atm atm) atm,
      ],
      attribution: attribution,
    );
  }
}

class AtmsApi {
  AtmsApi(this._api);

  final ApiClient _api;

  /// Cajeros de la zona (~3 km alrededor de tu casilla de ~1 km).
  Future<AtmList> near(GeoPoint me) async => AtmList.parse(
    await _api.getJson(
      '/v1/atms',
      query: <String, String>{
        'lat': me.lat.toStringAsFixed(2),
        'lon': me.lon.toStringAsFixed(2),
      },
      public: true,
    ),
  );
}

String? _text(Object? v) =>
    v is String && v.trim().isNotEmpty ? v.trim() : null;

Never _bad() => throw const ApiException(ApiError.unavailable);
