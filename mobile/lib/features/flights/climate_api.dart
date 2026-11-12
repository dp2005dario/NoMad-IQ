// El clima medio de cada mes en un sitio (pantalla Explorar). Lo da el
// servidor con medias de 30 años de la NASA; es público (también para
// invitados) y el móvil lo guarda en memoria mientras la pantalla está
// abierta.
import '../../core/api_client.dart';

class MonthClimate {
  const MonthClimate({
    required this.month,
    required this.tempC,
    required this.tempMaxC,
    required this.rainMm,
  });

  /// 1 = enero ... 12 = diciembre.
  final int month;

  /// Temperatura media del día y media de las máximas, en grados.
  final double tempC;
  final double tempMaxC;

  /// Lluvia del mes entero, en litros por metro cuadrado (mm).
  final double rainMm;

  /// Cuántos días llueve, más o menos: cada ~5 mm es un día de lluvia.
  /// Es una regla aproximada (la NASA da el total, no los días), y así se
  /// entiende mejor que "118 mm".
  int get rainyDays => (rainMm / 5).round().clamp(0, 30);

  static MonthClimate? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? month = json['month'];
    final Object? temp = json['temp_c'];
    final Object? top = json['temp_max_c'];
    final Object? rain = json['rain_mm'];
    if (month is! int ||
        month < 1 ||
        month > 12 ||
        temp is! num ||
        top is! num ||
        rain is! num ||
        rain < 0) {
      return null;
    }
    return MonthClimate(
      month: month,
      tempC: temp.toDouble(),
      tempMaxC: top.toDouble(),
      rainMm: rain.toDouble(),
    );
  }
}

class ClimateApi {
  const ClimateApi(this._api);

  final ApiClient _api;

  /// El clima medio de cada mes alrededor de un punto. El servidor redondea
  /// la posición a ~50 km, así que no dice dónde está nadie.
  Future<List<MonthClimate>> at(double lat, double lon) async {
    final Object? json = await _api.getJson(
      '/v1/climate',
      query: <String, String>{
        'lat': lat.toStringAsFixed(2),
        'lon': lon.toStringAsFixed(2),
      },
      public: true,
    );
    if (json is! Map<String, Object?>) return <MonthClimate>[];
    final Object? items = json['months'];
    if (items is! List<Object?>) return <MonthClimate>[];
    return <MonthClimate>[
      for (final Object? item in items) ?MonthClimate.parse(item),
    ];
  }

  /// El clima de cada país (código ISO → 12 meses de [temperatura, lluvia]),
  /// para Explorar. [complete] = false si el servidor aún los está pidiendo.
  Future<CountryClimate> countries() async {
    final Object? json = await _api.getJson(
      '/v1/climate/countries',
      public: true,
    );
    return CountryClimate.parse(json);
  }
}

/// Datos de un país del Banco Mundial (Explorar). null = no lo tienen.
class WorldFacts {
  const WorldFacts({
    this.arrivals,
    this.price,
    this.homicides,
    this.population,
    this.capital,
  });

  /// Turistas que llegan al año.
  final int? arrivals;

  /// Nivel de precios (EE. UU. = 1): 0,5 = la mitad de caro.
  final double? price;

  /// Homicidios por cada 100 000 habitantes (para la seguridad).
  final double? homicides;
  final int? population;
  final String? capital;

  static WorldFacts? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    num? n(String k) {
      final Object? v = json[k];
      return v is num && v >= 0 && v.isFinite ? v : null;
    }

    final Object? cap = json['capital'];
    final WorldFacts f = WorldFacts(
      arrivals: n('arrivals')?.round(),
      price: n('price')?.toDouble(),
      homicides: n('homicides')?.toDouble(),
      population: n('population')?.round(),
      capital: cap is String && cap.isNotEmpty && cap.length <= 80 ? cap : null,
    );
    return f.toJson().isEmpty ? null : f;
  }

  Map<String, Object> toJson() => <String, Object>{
    'arrivals': ?arrivals,
    'price': ?price,
    'homicides': ?homicides,
    'population': ?population,
    'capital': ?capital,
  };
}

/// El clima de todos los países que tiene el servidor (ver [ClimateApi]).
class CountryClimate {
  const CountryClimate({
    required this.byCountry,
    required this.complete,
    this.facts = const <String, WorldFacts>{},
  });

  /// "ES" → [[temperatura, lluvia], ...] de enero a diciembre.
  final Map<String, List<List<double>>> byCountry;
  final bool complete;

  /// "ES" → turistas, precios, seguridad... (Banco Mundial).
  final Map<String, WorldFacts> facts;

  /// Junta lo guardado en el móvil ([this]) con lo nuevo del servidor.
  CountryClimate merge(CountryClimate fresh) => CountryClimate(
    byCountry: <String, List<List<double>>>{...byCountry, ...fresh.byCountry},
    complete: fresh.complete,
    facts: fresh.facts.isNotEmpty ? fresh.facts : facts,
  );

  /// Mismo formato que manda el servidor (para guardarlo en el móvil).
  Map<String, Object?> toJson() => <String, Object?>{
    'complete': complete,
    'countries': byCountry,
    'facts': <String, Object>{
      for (final MapEntry<String, WorldFacts> e in facts.entries)
        e.key: e.value.toJson(),
    },
  };

  static CountryClimate parse(Object? json) {
    final Map<String, List<List<double>>> out = <String, List<List<double>>>{};
    if (json is! Map<String, Object?>) {
      return const CountryClimate(
        byCountry: <String, List<List<double>>>{},
        complete: false,
      );
    }
    final Object? countries = json['countries'];
    if (countries is Map<String, Object?>) {
      for (final MapEntry<String, Object?> e in countries.entries) {
        final Object? months = e.value;
        if (!RegExp(r'^[A-Z]{2}$').hasMatch(e.key) ||
            months is! List<Object?> ||
            months.length != 12) {
          continue;
        }
        final List<List<double>> rows = <List<double>>[];
        for (final Object? m in months) {
          if (m is List<Object?> &&
              m.length == 2 &&
              m[0] is num &&
              m[1] is num) {
            rows.add(<double>[
              (m[0]! as num).toDouble(),
              (m[1]! as num).toDouble(),
            ]);
          }
        }
        if (rows.length == 12) out[e.key] = rows;
      }
    }
    final Map<String, WorldFacts> facts = <String, WorldFacts>{};
    final Object? rawFacts = json['facts'];
    if (rawFacts is Map<String, Object?>) {
      for (final MapEntry<String, Object?> e in rawFacts.entries) {
        if (!RegExp(r'^[A-Z]{2}$').hasMatch(e.key)) continue;
        final WorldFacts? f = WorldFacts.parse(e.value);
        if (f != null) facts[e.key] = f;
      }
    }
    return CountryClimate(
      byCountry: out,
      complete: json['complete'] == true,
      facts: facts,
    );
  }
}
