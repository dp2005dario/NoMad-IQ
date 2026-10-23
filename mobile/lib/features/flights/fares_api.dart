// Las llamadas de Vuelos al price-consumer (a través de la puerta):
//   GET    /v1/fares/deals?origin=MAD      → chollos de hoy desde un aeropuerto
//   GET    /v1/fares/watches               → las rutas que vigilas
//   PUT    /v1/fares/watches/{ruta}        → vigilar (con precio objetivo opcional)
//   DELETE /v1/fares/watches/{ruta}        → dejar de vigilar
//   GET    /v1/fares/history/{ruta}        → precio mínimo de cada día (gráfica)
//   GET    /v1/fares/alerts                → tus últimos avisos de precio
//
// Una "ruta" es una clave como "MAD-NRT:2026-12-15:ECONOMY" (origen, destino,
// fecha de ida, fecha de vuelta opcional y cabina). Aquí se valida TODO lo que
// llega: si el servidor manda algo raro, mejor un error que una pantalla rota.
import '../../core/api_client.dart';

/// Dinero en "unidades mínimas" (31500 EUR = 315,00 €), como lo manda el servidor.
class Money {
  const Money(this.amountMinor, this.currency);

  final int amountMinor;
  final String currency;

  static Money parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? amount = json['amount_minor'];
    final Object? currency = json['currency'];
    if (amount is! int || amount < 0 || currency is! String) _bad();
    if (!_code3.hasMatch(currency)) _bad();
    return Money(amount, currency);
  }
}

final RegExp _code3 = RegExp(r'^[A-Z]{3}$');

/// Una ruta concreta: de dónde a dónde, qué día y en qué cabina.
class FareRoute {
  const FareRoute({
    required this.key,
    required this.origin,
    required this.destination,
    required this.departure,
    required this.cabin,
    this.returnDate,
  });

  final String key;
  final String origin;
  final String destination;
  final DateTime departure;
  final DateTime? returnDate;

  /// ECONOMY, PREMIUM_ECONOMY, BUSINESS o FIRST.
  final String cabin;

  static final RegExp _date = RegExp(r'^\d{4}-\d{2}-\d{2}$');
  static const Set<String> cabins = <String>{
    'ECONOMY',
    'PREMIUM_ECONOMY',
    'BUSINESS',
    'FIRST',
  };

  static DateTime? _day(Object? raw) =>
      raw is String && _date.hasMatch(raw) ? DateTime.tryParse(raw) : null;

  static FareRoute parse(Map<String, Object?> json) {
    final Object? key = json['route_key'];
    final Object? origin = json['origin'];
    final Object? destination = json['destination'];
    final Object? cabin = json['cabin'];
    final DateTime? departure = _day(json['departure_date']);
    final Object? rawReturn = json['return_date'];
    final DateTime? back = _day(rawReturn);
    if (key is! String ||
        key.length > 64 ||
        origin is! String ||
        !_code3.hasMatch(origin) ||
        destination is! String ||
        !_code3.hasMatch(destination) ||
        cabin is! String ||
        !cabins.contains(cabin) ||
        departure == null ||
        (rawReturn != null && rawReturn != '' && back == null)) {
      _bad();
    }
    return FareRoute(
      key: key,
      origin: origin,
      destination: destination,
      departure: departure,
      returnDate: back,
      cabin: cabin,
    );
  }

  /// Lee una clave "MAD-NRT:2026-12-15[:2026-12-22]:ECONOMY" (la de la
  /// dirección de la pantalla de detalle). null si no tiene esa forma.
  static FareRoute? fromKey(String key) {
    final List<String> parts = key.split(':');
    if (parts.length < 3 || parts.length > 4) return null;
    final List<String> airports = parts.first.split('-');
    if (airports.length != 2) return null;
    try {
      return parse(<String, Object?>{
        'route_key': key,
        'origin': airports[0],
        'destination': airports[1],
        'departure_date': parts[1],
        'return_date': parts.length == 4 ? parts[2] : null,
        'cabin': parts.last,
      });
    } on ApiException {
      return null;
    }
  }

  /// La clave de una ruta de solo ida en turista (lo que se pide al vigilar
  /// un chollo desde la app).
  static String keyFor(
    String origin,
    String destination,
    DateTime departure, {
    DateTime? returnDate,
    String cabin = 'ECONOMY',
  }) {
    String d(DateTime t) =>
        '${t.year.toString().padLeft(4, '0')}-'
        '${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
    return <String>[
      '$origin-$destination',
      d(departure),
      if (returnDate != null) d(returnDate),
      cabin,
    ].join(':');
  }
}

/// Un precio visto para una ruta.
class Fare {
  const Fare({
    required this.route,
    required this.price,
    required this.observedAt,
    this.carrier = '',
    this.bookingUrl,
  });

  final FareRoute route;
  final Money price;
  final String carrier;

  /// Dónde se reserva (con nuestra comisión de afiliado). Solo https.
  final Uri? bookingUrl;
  final DateTime observedAt;

  static Fare parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? carrier = json['carrier'];
    final DateTime? observed = json['observed_at'] is String
        ? DateTime.tryParse(json['observed_at']! as String)
        : null;
    if (observed == null) _bad();
    return Fare(
      route: FareRoute.parse(json),
      price: Money.parse(json['price']),
      carrier: carrier is String && carrier.length <= 3 ? carrier : '',
      bookingUrl: safeBookingUrl(json['booking_url']),
      observedAt: observed,
    );
  }
}

/// Solo enlaces https: nunca abrimos otra cosa desde un dato del servidor.
Uri? safeBookingUrl(Object? raw) {
  if (raw is! String || raw.isEmpty || raw.length > 2048) return null;
  final Uri? uri = Uri.tryParse(raw);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
      ? uri
      : null;
}

/// Un chollo: un precio más lo que suele costar esa ruta.
class Deal {
  const Deal({
    required this.fare,
    required this.usualMinor,
    required this.dropBasisPoints,
  });

  final Fare fare;

  /// Precio habitual (mediana de los últimos días); 0 si aún no hay historia.
  final int usualMinor;

  /// Cuánto ha bajado en puntos básicos: 3500 = 35 %.
  final int dropBasisPoints;

  /// Más de un 50 % por debajo de lo normal: probablemente un error de tarifa.
  bool get looksLikeErrorFare => dropBasisPoints >= 5000;

  static Deal parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? usual = json['usual_minor'];
    final Object? drop = json['drop_bp'];
    if (usual is! int || drop is! int || drop < 0 || drop > 10000) _bad();
    return Deal(
      fare: Fare.parse(json),
      usualMinor: usual,
      dropBasisPoints: drop,
    );
  }
}

/// Una ruta que vigilas.
class Watch {
  const Watch({required this.route, this.target, this.latest});

  final FareRoute route;

  /// "Avísame si baja de…" (opcional).
  final Money? target;

  /// El último precio visto (null si el servidor aún no lo ha consultado).
  final Fare? latest;

  static Watch parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? target = json['target'];
    final Object? latest = json['latest'];
    return Watch(
      route: FareRoute.parse(json),
      target: target == null ? null : Money.parse(target),
      latest: latest == null ? null : Fare.parse(latest),
    );
  }
}

/// Un punto de la gráfica: el precio más bajo de un día.
class PricePoint {
  const PricePoint(this.day, this.minMinor);

  final DateTime day;
  final int minMinor;
}

/// El historial de precios de una ruta.
class PriceHistory {
  const PriceHistory({required this.currency, required this.points});

  /// '' si aún no hay ningún precio.
  final String currency;
  final List<PricePoint> points;
}

/// Por qué saltó un aviso.
enum FareAlertType { priceDrop, errorFare, targetReached }

/// Un aviso de precio que recibiste.
class FareAlert {
  const FareAlert({
    required this.id,
    required this.type,
    required this.route,
    required this.reference,
    required this.current,
    required this.dropBasisPoints,
    required this.observedAt,
    this.bookingUrl,
  });

  final String id;
  final FareAlertType type;
  final FareRoute route;
  final Money reference;
  final Money current;
  final int dropBasisPoints;
  final Uri? bookingUrl;
  final DateTime observedAt;

  static FareAlert parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final FareAlertType? type = switch (json['type']) {
      'PRICE_DROP' || 'price_drop' => FareAlertType.priceDrop,
      'ERROR_FARE' || 'error_fare' => FareAlertType.errorFare,
      'TARGET_REACHED' || 'target_reached' => FareAlertType.targetReached,
      _ => null,
    };
    final Object? id = json['alert_id'];
    final Object? drop = json['drop_bp'];
    final DateTime? observed = json['observed_at'] is String
        ? DateTime.tryParse(json['observed_at']! as String)
        : null;
    if (type == null || id is! String || drop is! int || observed == null) {
      _bad();
    }
    return FareAlert(
      id: id,
      type: type,
      route: FareRoute.parse(json),
      reference: Money.parse(json['reference']),
      current: Money.parse(json['current']),
      dropBasisPoints: drop.clamp(0, 10000),
      bookingUrl: safeBookingUrl(json['booking_url']),
      observedAt: observed,
    );
  }
}

/// Resultado de pedir vigilar una ruta.
enum WatchResult { added, updated }

class FaresApi {
  FaresApi(this._api);

  final ApiClient _api;

  static String _path(String routeKey) => Uri.encodeComponent(routeKey);

  Future<List<Deal>> deals(String origin) async {
    final Object? json = await _api.getJson(
      '/v1/fares/deals',
      query: <String, String>{'origin': origin},
      public: true, // los chollos también los ve un invitado
    );
    return _list(json, 'deals', Deal.parse);
  }

  /// Las rutas vigiladas y el máximo que permite el servidor.
  Future<(List<Watch>, int)> watches() async {
    final Object? json = await _api.getJson('/v1/fares/watches');
    final Object? max = json is Map<String, Object?> ? json['max'] : null;
    return (_list(json, 'watches', Watch.parse), max is int ? max : 50);
  }

  /// Vigilar (o cambiar el precio objetivo). ApiError.conflict = has llegado
  /// al máximo de rutas; ApiError.invalidInput = el vuelo ya salió o es
  /// demasiado lejano.
  Future<void> watch(String routeKey, {Money? target}) async {
    await _api.putJson(
      '/v1/fares/watches/${_path(routeKey)}',
      <String, Object?>{
        if (target != null)
          'target': <String, Object?>{
            'amount_minor': target.amountMinor,
            'currency': target.currency,
          },
      },
    );
  }

  /// Dejar de vigilar (si ya no la vigilabas, no pasa nada).
  Future<void> unwatch(String routeKey) async {
    try {
      await _api.delete('/v1/fares/watches/${_path(routeKey)}');
    } on ApiException catch (e) {
      if (e.error != ApiError.notFound) rethrow;
    }
  }

  Future<PriceHistory> history(String routeKey) async {
    final Object? json = await _api.getJson(
      '/v1/fares/history/${_path(routeKey)}',
      public: true,
    );
    if (json is! Map<String, Object?>) _bad();
    final Object? currency = json['currency'];
    final List<PricePoint> points = _list(json, 'points', (Object? p) {
      if (p is! Map<String, Object?>) _bad();
      final DateTime? day = FareRoute._day(p['date']);
      final Object? min = p['min_minor'];
      if (day == null || min is! int || min < 0) _bad();
      return PricePoint(day, min);
    });
    return PriceHistory(
      currency: currency is String ? currency : '',
      points: points,
    );
  }

  Future<List<FareAlert>> alerts() async =>
      _list(await _api.getJson('/v1/fares/alerts'), 'alerts', FareAlert.parse);

  static List<T> _list<T>(Object? json, String key, T Function(Object?) parse) {
    if (json is! Map<String, Object?>) _bad();
    final Object? items = json[key];
    if (items == null) return <T>[];
    if (items is! List<Object?>) _bad();
    return <T>[for (final Object? item in items) parse(item)];
  }
}

Never _bad() => throw const ApiException(ApiError.unavailable);
