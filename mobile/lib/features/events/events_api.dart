// "Qué pasa en tus fechas": GET /v1/events?iata&from&to (público).
//
// Solo datos reales con fuente: festivos oficiales (Nager.Date) y eventos
// publicados en Ticketmaster (con el precio que pone el organizador, si lo
// pone). La app no estima nada.
import '../../core/api_client.dart';

enum EventKind { holiday, music, sports, arts, family, festival, other }

/// Cómo están las entradas, según Ticketmaster.
enum SaleStatus { onsale, offsale, cancelled, rescheduled }

class CityEvent {
  const CityEvent({
    required this.id,
    required this.kind,
    required this.name,
    required this.date,
    this.time,
    this.venue,
    this.url,
    this.priceMin,
    this.currency,
    this.regional = false,
    this.status,
    this.lat,
    this.lon,
    this.image,
    this.top = false,
    this.monthOnly = false,
  });

  final String id;
  final EventKind kind;
  final String name;

  /// El día (sin hora: es la fecha local de la ciudad).
  final DateTime date;
  final String? time;
  final String? venue;
  final Uri? url;
  final double? priceMin;
  final String? currency;

  /// Festivo solo en una parte del país.
  final bool regional;

  /// El estado de las entradas (solo si Ticketmaster lo publica).
  final SaleStatus? status;

  /// Dónde está el recinto (para el mapa "Dónde pasan").
  final double? lat;
  final double? lon;

  /// La foto real del evento (o su cartel), si la hay. Sin foto, la app
  /// enseña el dibujo de siempre.
  final Uri? image;

  /// De los más conocidos de la ciudad en esas fechas.
  final bool top;

  /// Fiesta que se celebra "en julio" (no se sabe el día exacto): la app
  /// enseña el mes en vez de la hora.
  final bool monthOnly;

  static CityEvent? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? name = json['name'];
    final Object? day = json['date'];
    EventKind? kind;
    for (final EventKind k in EventKind.values) {
      if (k.name == json['kind']) kind = k;
    }
    final DateTime? date = day is String ? DateTime.tryParse(day) : null;
    if (id is! String || name is! String || date == null || kind == null) {
      return null;
    }
    String? text(String key) {
      final Object? v = json[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final Uri? url = Uri.tryParse(text('url') ?? '');
    final Uri? image = Uri.tryParse(text('image') ?? '');
    final Object? price = json['price_min'];
    final String? currency = text('currency');
    return CityEvent(
      id: id,
      kind: kind,
      name: name,
      date: DateTime(date.year, date.month, date.day),
      time: text('time'),
      venue: text('venue'),
      url: url != null && url.scheme == 'https' ? url : null,
      priceMin: price is num && currency != null ? price.toDouble() : null,
      currency: price is num ? currency : null,
      regional: json['regional'] == true,
      status: SaleStatus.values
          .where((SaleStatus s) => s.name == json['status'])
          .firstOrNull,
      lat: switch (json['lat']) {
        final num v when v >= -90 && v <= 90 => v.toDouble(),
        _ => null,
      },
      lon: switch (json['lon']) {
        final num v when v >= -180 && v <= 180 => v.toDouble(),
        _ => null,
      },
      image: image != null && image.scheme == 'https' && image.host.isNotEmpty
          ? image
          : null,
      top: json['top'] == true,
      monthOnly: json['month_only'] == true,
    );
  }
}

class CityEvents {
  const CityEvents({
    required this.city,
    required this.events,
    required this.sources,
  });

  final String city;
  final List<CityEvent> events;
  final List<String> sources;

  static CityEvents parse(Object? json) {
    if (json is! Map<String, Object?> || json['events'] is! List) {
      throw const ApiException(ApiError.unavailable);
    }
    final Object? city = json['city'];
    final Object? sources = json['sources'];
    return CityEvents(
      city: city is String ? city : '',
      events: <CityEvent>[
        for (final Object? e in (json['events']! as List<Object?>).take(200))
          ?CityEvent.parse(e),
      ],
      sources: <String>[
        if (sources is List<Object?>)
          for (final Object? s in sources)
            if (s is String) s,
      ],
    );
  }
}

String _day(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class EventsApi {
  const EventsApi(this._api);

  final ApiClient _api;

  /// [language]: el idioma de los nombres de las fiestas (Wikidata).
  Future<CityEvents> between(
    String iata,
    DateTime from,
    DateTime to, {
    String language = 'en',
  }) async => CityEvents.parse(
    await _api.getJson(
      '/v1/events',
      query: <String, String>{
        'iata': iata.toUpperCase(),
        'from': _day(from),
        'to': _day(to),
        'lang': language,
      },
      public: true,
      // La primera vez en una ciudad, las fiestas de Wikidata tardan más.
      timeout: ApiClient.slow,
    ),
  );
}
