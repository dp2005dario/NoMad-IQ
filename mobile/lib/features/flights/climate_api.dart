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
}
