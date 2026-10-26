// Radar local: lluvia (GET /v1/rain, público) y lo que avisan otros
// viajeros de una ciudad (GET/POST /v1/radar/{ciudad}, con sesión).
//
// Nada inventado: la lluvia es la previsión de MET Norway; los timos y los
// precios los ponen viajeros de verdad, y el servidor solo los enseña
// cuando los ha avisado bastante gente (3 personas los timos, 5 los
// precios).
import '../../core/api_client.dart';
import '../map/geo.dart';

/// Casillas de 0,05° (~5 km), como el servidor.
GeoPoint rainCellOf(GeoPoint p) => GeoPoint(
  double.parse(((p.lat / 0.05).round() * 0.05).toStringAsFixed(2)),
  double.parse(((p.lon / 0.05).round() * 0.05).toStringAsFixed(2)),
);

class RainHour {
  const RainHour(this.time, this.rainMm, this.tempC);

  final DateTime time;
  final double rainMm;
  final double? tempC;
}

class RainForecast {
  const RainForecast(this.hours, this.attribution);

  final List<RainHour> hours;
  final String attribution;

  /// La primera hora con lluvia de verdad (≥ 0,2 mm), o null.
  RainHour? get firstRain {
    for (final RainHour h in hours) {
      if (h.rainMm >= 0.2) return h;
    }
    return null;
  }

  static RainForecast parse(Object? json) {
    if (json is! Map<String, Object?> || json['hours'] is! List) {
      throw const ApiException(ApiError.unavailable);
    }
    final List<RainHour> hours = <RainHour>[];
    for (final Object? h in (json['hours']! as List<Object?>).take(12)) {
      if (h is! Map<String, Object?>) continue;
      final Object? time = h['time'];
      final Object? rain = h['rain_mm'];
      final Object? temp = h['temp_c'];
      final DateTime? when = time is String ? DateTime.tryParse(time) : null;
      if (when == null || rain is! num) continue;
      hours.add(
        RainHour(
          when.toLocal(),
          rain.toDouble(),
          temp is num ? temp.toDouble() : null,
        ),
      );
    }
    final Object? attribution = json['attribution'];
    return RainForecast(
      hours,
      attribution is String ? attribution : 'MET Norway',
    );
  }
}

enum ScamCategory {
  streetTouts('street_touts'),
  taxi('taxi'),
  fakePolice('fake_police'),
  bracelet('bracelet'),
  atm('atm'),
  pickpockets('pickpockets'),
  fakeTickets('fake_tickets'),
  exchange('exchange');

  const ScamCategory(this.wire);

  final String wire;

  static ScamCategory? parse(Object? raw) {
    for (final ScamCategory c in values) {
      if (c.wire == raw) return c;
    }
    return null;
  }
}

enum PriceItem {
  coffee('coffee'),
  beer('beer'),
  water('water'),
  simpleMeal('simple_meal'),
  taxiShort('taxi_short');

  const PriceItem(this.wire);

  final String wire;

  static PriceItem? parse(Object? raw) {
    for (final PriceItem c in values) {
      if (c.wire == raw) return c;
    }
    return null;
  }
}

class PriceRange {
  const PriceRange({
    required this.item,
    required this.currency,
    required this.reporters,
    required this.low,
    required this.median,
    required this.high,
  });

  final PriceItem item;
  final String currency;
  final int reporters;
  final double low;
  final double median;
  final double high;
}

enum PriceVerdict { fine, bitHigh, overcharged }

/// ¿Es caro? Hasta el percentil 75 = normal; hasta un 25 % más = algo caro;
/// más = te cobran de más. Siempre comparado con lo que pagan otros.
PriceVerdict verdictFor(double asked, PriceRange range) => asked <= range.high
    ? PriceVerdict.fine
    : asked <= range.high * 1.25
    ? PriceVerdict.bitHigh
    : PriceVerdict.overcharged;

class CityRadar {
  const CityRadar({
    required this.scams,
    required this.prices,
    required this.myScams,
  });

  /// Tipo de timo → cuántas personas lo avisaron.
  final Map<ScamCategory, int> scams;
  final List<PriceRange> prices;
  final Set<ScamCategory> myScams;

  static CityRadar parse(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    final Map<ScamCategory, int> scams = <ScamCategory, int>{};
    final Object? rawScams = json['scams'];
    if (rawScams is List<Object?>) {
      for (final Object? s in rawScams) {
        if (s is! Map<String, Object?>) continue;
        final ScamCategory? c = ScamCategory.parse(s['category']);
        final Object? n = s['reporters'];
        if (c != null && n is int) scams[c] = n;
      }
    }
    final List<PriceRange> prices = <PriceRange>[];
    final Object? rawPrices = json['prices'];
    if (rawPrices is List<Object?>) {
      for (final Object? p in rawPrices) {
        if (p is! Map<String, Object?>) continue;
        final PriceItem? item = PriceItem.parse(p['item']);
        final Object? cur = p['currency'], n = p['reporters'];
        final Object? lo = p['low'], med = p['median'], hi = p['high'];
        if (item == null ||
            cur is! String ||
            n is! int ||
            lo is! num ||
            med is! num ||
            hi is! num) {
          continue;
        }
        prices.add(
          PriceRange(
            item: item,
            currency: cur,
            reporters: n,
            low: lo.toDouble(),
            median: med.toDouble(),
            high: hi.toDouble(),
          ),
        );
      }
    }
    final Object? mine = json['my_scams'];
    return CityRadar(
      scams: scams,
      prices: prices,
      myScams: <ScamCategory>{
        if (mine is List<Object?>)
          for (final Object? m in mine) ?ScamCategory.parse(m),
      },
    );
  }
}

class RadarApi {
  const RadarApi(this._api);

  final ApiClient _api;

  Future<RainForecast> rain(GeoPoint at) async {
    final GeoPoint c = rainCellOf(at);
    return RainForecast.parse(
      await _api.getJson(
        '/v1/rain',
        query: <String, String>{
          'lat': c.lat.toStringAsFixed(2),
          'lon': c.lon.toStringAsFixed(2),
        },
        public: true,
      ),
    );
  }

  Future<CityRadar> city(String iata) async =>
      CityRadar.parse(await _api.getJson('/v1/radar/${iata.toUpperCase()}'));

  Future<void> reportScam(String iata, ScamCategory c) => _api.postJson(
    '/v1/radar/${iata.toUpperCase()}/scams',
    <String, Object?>{'category': c.wire},
  );

  Future<void> withdrawScam(String iata, ScamCategory c) =>
      _api.delete('/v1/radar/${iata.toUpperCase()}/scams/${c.wire}');

  Future<void> addPrice(
    String iata,
    PriceItem item,
    String currency,
    double amount,
  ) =>
      _api.postJson('/v1/radar/${iata.toUpperCase()}/prices', <String, Object?>{
        'item': item.wire,
        'currency': currency,
        'amount': amount.toStringAsFixed(2),
      });
}
