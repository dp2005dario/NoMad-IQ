// Guía del aeropuerto (maqueta "Aeropuerto"): cómo llegar a tu puerta, al
// baño o a un café dentro de la terminal.
//
// Los sitios (puertas, baños, cafés...) salen de OpenStreetMap a través del
// ai-orchestrator:  GET /v1/airports/MAD/spots  (público, un mes de caché en
// el servidor). Pedimos el aeropuerto entero, NO tu posición: el servidor no
// sabe dónde estás. La flecha y la distancia se calculan aquí, en el móvil,
// con el GPS y la brújula.
import 'dart:math' as math;

import '../../core/api_client.dart';
import '../map/geo.dart';

/// Lo que se puede buscar dentro del aeropuerto.
enum SpotKind {
  gate,
  toilets,
  cafe,
  food,
  pharmacy,
  atm,
  water,
  info,
  charging,
  lounge,
  // Las salidas del aeropuerto (pantalla Moverte).
  train,
  metro,
  tram,
  bus,
  taxi;

  static SpotKind? parse(Object? raw) {
    for (final SpotKind k in values) {
      if (k.name == raw) return k;
    }
    return null;
  }
}

class AirportSpot {
  const AirportSpot({
    required this.id,
    required this.kind,
    required this.point,
    this.ref,
    this.name,
    this.level,
  });

  final String id;
  final SpotKind kind;
  final GeoPoint point;

  /// El número de puerta ("K42").
  final String? ref;
  final String? name;

  /// La planta ("1", "-1"), si OpenStreetMap la sabe.
  final String? level;

  static AirportSpot? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final SpotKind? kind = SpotKind.parse(json['kind']);
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    if (id is! String || kind == null || lat is! num || lon is! num) {
      return null;
    }
    final GeoPoint p = GeoPoint(lat.toDouble(), lon.toDouble());
    if (!p.isValid) return null;
    String? text(String key) {
      final Object? v = json[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    return AirportSpot(
      id: id,
      kind: kind,
      point: p,
      ref: text('ref'),
      name: text('name'),
      level: text('level'),
    );
  }
}

class AirportGuide {
  const AirportGuide({
    required this.iata,
    required this.center,
    required this.spots,
    required this.attribution,
  });

  final String iata;
  final GeoPoint center;
  final List<AirportSpot> spots;
  final String attribution;

  /// La puerta con ese número ("k42", "K 42" y "K42" son la misma).
  AirportSpot? gate(String ref) {
    String clean(String s) => s.replaceAll(RegExp(r'\s'), '').toUpperCase();
    final String want = clean(ref);
    for (final AirportSpot s in spots) {
      if (s.kind == SpotKind.gate && clean(s.ref ?? '') == want) return s;
    }
    return null;
  }

  /// El sitio de ese tipo más cercano a [here].
  AirportSpot? nearest(SpotKind kind, GeoPoint here) {
    AirportSpot? best;
    double bestM = double.infinity;
    for (final AirportSpot s in spots) {
      if (s.kind != kind) continue;
      final double m = here.distanceTo(s.point);
      if (m < bestM) {
        bestM = m;
        best = s;
      }
    }
    return best;
  }

  static AirportGuide parse(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    final Object? iata = json['iata'];
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    final Object? spots = json['spots'];
    final Object? attribution = json['attribution'];
    if (iata is! String || lat is! num || lon is! num || spots is! List) {
      throw const ApiException(ApiError.unavailable);
    }
    return AirportGuide(
      iata: iata,
      center: GeoPoint(lat.toDouble(), lon.toDouble()),
      spots: <AirportSpot>[
        for (final Object? s in spots.take(800)) ?AirportSpot.parse(s),
      ],
      attribution: attribution is String
          ? attribution
          : '© OpenStreetMap contributors',
    );
  }
}

class AirportGuideApi {
  AirportGuideApi(this._api);

  final ApiClient _api;
  final Map<String, AirportGuide> _memo = <String, AirportGuide>{};

  /// La guía de un aeropuerto (se recuerda mientras la app está abierta).
  Future<AirportGuide> get(String iata) async {
    final String code = iata.toUpperCase();
    final AirportGuide? known = _memo[code];
    if (known != null) return known;
    final AirportGuide g = AirportGuide.parse(
      await _api.getJson(
        '/v1/airports/${Uri.encodeComponent(code)}/spots',
        public: true,
      ),
    );
    return _memo[code] = g;
  }
}

/// Rumbo de [from] a [to] en grados (0 = norte, 90 = este).
double bearingTo(GeoPoint from, GeoPoint to) {
  double rad(double d) => d * math.pi / 180;
  final double y = math.sin(rad(to.lon - from.lon)) * math.cos(rad(to.lat));
  final double x =
      math.cos(rad(from.lat)) * math.sin(rad(to.lat)) -
      math.sin(rad(from.lat)) *
          math.cos(rad(to.lat)) *
          math.cos(rad(to.lon - from.lon));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Hacia dónde girar: el ángulo entre a dónde miras y a dónde está el sitio.
enum Turn { straight, left, right, back }

/// [relative]: grados del sitio respecto a donde miras (-180..180).
Turn turnFor(double relative) {
  final double a = ((relative + 540) % 360) - 180;
  if (a.abs() <= 30) return Turn.straight;
  if (a.abs() >= 150) return Turn.back;
  return a < 0 ? Turn.left : Turn.right;
}

/// Minutos andando (unos 75 m por minuto, con maleta y gente).
int walkMinutes(double meters) => (meters / 75).ceil().clamp(1, 120);

/// Lo que Flyra te dice abajo: un giro, seguir recto o que ya has llegado.
enum Cue { straight, left, right, back, arrived }

/// A menos de 15 m se da por llegado (el GPS dentro de un edificio no da
/// para más precisión).
Cue cueFor(double meters, double relative) => meters < 15
    ? Cue.arrived
    : switch (turnFor(relative)) {
        Turn.straight => Cue.straight,
        Turn.left => Cue.left,
        Turn.right => Cue.right,
        Turn.back => Cue.back,
      };

/// Decide CUÁNDO decir en voz alta (y vibrar) un giro. La brújula tiembla
/// mucho: si Flyra hablara con cada temblor no pararía. Por eso:
///   - la primera indicación se dice enseguida;
///   - un cambio solo se dice si dura [steady] sin volver atrás;
///   - entre dos avisos pasan al menos [gap] (salvo "ya has llegado").
class TurnAnnouncer {
  TurnAnnouncer({
    this.steady = const Duration(milliseconds: 1200),
    this.gap = const Duration(seconds: 3),
  });

  final Duration steady;
  final Duration gap;

  Cue? _said;
  Cue? _pending;
  DateTime? _since;
  DateTime? _lastSaid;

  /// Lo que hay que decir ahora, o null si toca callarse.
  Cue? update(Cue cue, DateTime now) {
    if (cue != _pending) {
      _pending = cue;
      _since = now;
    }
    if (cue == _said) return null;
    final DateTime? last = _lastSaid;
    if (last != null) {
      if (now.difference(_since!) < steady) return null;
      if (cue != Cue.arrived && now.difference(last) < gap) return null;
    }
    _said = cue;
    _lastSaid = now;
    return cue;
  }

  /// Al cambiar de destino se empieza de cero (la primera vuelve a ser
  /// inmediata).
  void reset() {
    _said = null;
    _pending = null;
    _since = null;
    _lastSaid = null;
  }
}
