// "Copia este viaje": hablar con el servidor (/v1/shared-trips).
//
// Alguien comparte su viaje (título, destino, días y una lista de cosas con
// su precio) y recibe un código de 8 letras. Con ese código cualquiera lo ve,
// lo copia y le pide a Flyra que lo adapte a su presupuesto.
import '../../core/api_client.dart';

/// Qué tipo de cosa es cada línea (el mismo vocabulario que el servidor).
enum TripKind {
  flight,
  stay,
  transport,
  food,
  activity,
  other;

  static TripKind parse(Object? raw) => TripKind.values.firstWhere(
    (TripKind k) => k.name == raw,
    orElse: () => TripKind.other,
  );
}

/// Una línea del viaje: "Vuelo con escala en Estambul, 690 €".
class TripLine {
  const TripLine({
    required this.kind,
    required this.title,
    required this.priceMinor,
  });

  final TripKind kind;
  final String title;

  /// En unidades mínimas (céntimos) de la moneda del viaje.
  final int priceMinor;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'title': title,
    'price_minor': priceMinor,
  };

  static TripLine? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? title = json['title'];
    final Object? price = json['price_minor'];
    if (title is! String || title.isEmpty || price is! int || price < 0) {
      return null;
    }
    return TripLine(
      kind: TripKind.parse(json['kind']),
      title: title,
      priceMinor: price,
    );
  }
}

int linesTotal(Iterable<TripLine> lines) =>
    lines.fold(0, (int sum, TripLine l) => sum + l.priceMinor);

/// Un viaje compartido, tal y como lo ve quien tiene el código.
class SharedTrip {
  const SharedTrip({
    required this.code,
    required this.author,
    required this.title,
    required this.destination,
    required this.days,
    required this.currency,
    required this.lines,
    required this.copies,
    required this.mine,
  });

  final String code;

  /// El nombre que eligió quien lo compartió ("laura.viaja"), nunca su cuenta.
  final String author;
  final String title;
  final String destination;
  final int days;
  final String currency;
  final List<TripLine> lines;

  /// Cuántas personas distintas lo han copiado.
  final int copies;

  /// True si lo compartiste tú.
  final bool mine;

  int get totalMinor => linesTotal(lines);

  static SharedTrip parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    String text(String key) {
      final Object? v = json[key];
      if (v is! String || v.isEmpty) _bad();
      return v;
    }

    final Object? days = json['days'];
    final Object? copies = json['copies'];
    final Object? items = json['items'];
    if (days is! int || items is! List<Object?>) _bad();
    return SharedTrip(
      code: text('code'),
      author: text('author'),
      title: text('title'),
      destination: text('destination'),
      days: days,
      currency: text('currency'),
      lines: <TripLine>[for (final Object? i in items) ?TripLine.parse(i)],
      copies: copies is int && copies >= 0 ? copies : 0,
      mine: json['mine'] == true,
    );
  }
}

/// Una línea después de que Flyra la adapte (con lo que tenía el original).
class AdaptedLine {
  const AdaptedLine({
    required this.line,
    required this.wasTitle,
    required this.wasPriceMinor,
  });

  final TripLine line;
  final String wasTitle;
  final int wasPriceMinor;

  bool get changed =>
      line.title != wasTitle || line.priceMinor != wasPriceMinor;
}

class TripAdaptation {
  const TripAdaptation({
    required this.lines,
    required this.budgetMinor,
    required this.fits,
    this.remainingToday,
  });

  final List<AdaptedLine> lines;
  final int budgetMinor;

  /// ¿Cabe en el presupuesto? Si no, se dice en naranja (no se esconde).
  final bool fits;

  /// Adaptaciones que te quedan hoy (null si vino de la caché del servidor).
  final int? remainingToday;

  int get totalMinor =>
      lines.fold(0, (int sum, AdaptedLine l) => sum + l.line.priceMinor);
  int get changes => lines.where((AdaptedLine l) => l.changed).length;

  /// El viaje sin adaptar (para el chip "como el original").
  static TripAdaptation original(SharedTrip trip) => TripAdaptation(
    lines: <AdaptedLine>[
      for (final TripLine l in trip.lines)
        AdaptedLine(line: l, wasTitle: l.title, wasPriceMinor: l.priceMinor),
    ],
    budgetMinor: trip.totalMinor,
    fits: true,
  );

  static TripAdaptation parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? items = json['items'];
    final Object? budget = json['budget_minor'];
    final Object? left = json['remaining_today'];
    if (items is! List<Object?> || budget is! int) _bad();
    final List<AdaptedLine> lines = <AdaptedLine>[];
    for (final Object? i in items) {
      final TripLine? line = TripLine.parse(i);
      if (line == null || i is! Map<String, Object?>) continue;
      final Object? wasTitle = i['was_title'];
      final Object? wasPrice = i['was_price_minor'];
      lines.add(
        AdaptedLine(
          line: line,
          wasTitle: wasTitle is String ? wasTitle : line.title,
          wasPriceMinor: wasPrice is int ? wasPrice : line.priceMinor,
        ),
      );
    }
    return TripAdaptation(
      lines: lines,
      budgetMinor: budget,
      fits: json['fits'] == true,
      remainingToday: left is int ? left : null,
    );
  }
}

/// Lo que se manda al pulsar "Compartir mi viaje".
class NewSharedTrip {
  const NewSharedTrip({
    required this.title,
    required this.author,
    required this.destination,
    required this.days,
    required this.currency,
    required this.lines,
  });

  final String title;
  final String author;
  final String destination;
  final int days;
  final String currency;
  final List<TripLine> lines;

  Map<String, Object?> toJson() => <String, Object?>{
    'title': title,
    'author': author,
    'destination': destination,
    'days': days,
    'currency': currency,
    'items': <Object?>[for (final TripLine l in lines) l.toJson()],
  };
}

Never _bad() => throw const ApiException(ApiError.unavailable);

/// Lo que escribe la persona ("7k2m-9qxd") → el código, o null si no puede serlo.
/// Las mismas reglas que el servidor: sin guiones ni espacios, O → 0, I/L → 1.
String? normalizeTripCode(String raw) {
  final String text = raw
      .toUpperCase()
      .replaceAll(RegExp(r'[\s-]'), '')
      .replaceAll('O', '0')
      .replaceAll(RegExp('[IL]'), '1');
  return RegExp(r'^[0-9A-HJKMNP-TV-Z]{8}$').hasMatch(text) ? text : null;
}

class SharedTripApi {
  const SharedTripApi(this._api);

  final ApiClient _api;

  static const String _base = '/v1/shared-trips';

  Future<SharedTrip> share(NewSharedTrip trip) async =>
      SharedTrip.parse(await _api.postJson(_base, trip.toJson()));

  Future<List<SharedTrip>> mine() async {
    final Object? json = await _api.getJson('$_base/mine');
    final Object? items = json is Map<String, Object?> ? json['items'] : null;
    if (items is! List<Object?>) _bad();
    return items.map(SharedTrip.parse).toList();
  }

  Future<SharedTrip> get(String code) async =>
      SharedTrip.parse(await _api.getJson('$_base/$code'));

  Future<SharedTrip> copy(String code) async => SharedTrip.parse(
    await _api.postJson('$_base/$code/copy', const <String, Object?>{}),
  );

  Future<TripAdaptation> adapt(
    String code, {
    required int budgetMinor,
    required String language,
  }) async => TripAdaptation.parse(
    await _api.postJson('$_base/$code/adapt', <String, Object?>{
      'budget_minor': budgetMinor,
      'language': language,
    }),
  );

  Future<void> unshare(String code) => _api.delete('$_base/$code');
}
