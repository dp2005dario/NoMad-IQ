// Fichas de ciudad (ai-orchestrator, a través de la puerta de entrada):
//   GET /v1/places/{IATA}?lang=es  → por qué es famosa, datos del país y lo
//                                    más visitado, con fotos de licencia libre
//
// Es una ruta pública: también la ve quien entra como invitado. Las
// respuestas se recuerdan mientras la app está abierta (una ciudad no cambia
// en cinco minutos) y aquí se valida todo lo que llega.
import '../../core/api_client.dart';

/// Una foto de Wikimedia Commons: la imagen y su página (autor y licencia).
class PlacePhoto {
  const PlacePhoto({required this.url, required this.pageUrl});

  final Uri url;
  final Uri pageUrl;

  static PlacePhoto? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Uri? url = _https(json['url']);
    final Uri? page = _https(json['page_url']);
    if (url == null || page == null) return null;
    return PlacePhoto(url: url, pageUrl: page);
  }
}

class Attraction {
  const Attraction({
    required this.name,
    this.description,
    this.photo,
    this.articleUrl,
    this.wikidataId,
  });

  final String name;
  final String? description;
  final PlacePhoto? photo;
  final Uri? articleUrl;

  /// "Q193208" (las fichas antiguas de la caché no lo traen).
  final String? wikidataId;
}

class CountryFacts {
  const CountryFacts({
    required this.name,
    this.capital,
    this.currency,
    this.languages = const <String>[],
  });

  final String name;
  final String? capital;
  final String? currency;
  final List<String> languages;
}

class PlaceCard {
  const PlaceCard({
    required this.iata,
    required this.language,
    required this.city,
    required this.attribution,
    this.summary,
    this.summaryLanguage,
    this.articleUrl,
    this.photo,
    this.population,
    this.country,
    this.attractions = const <Attraction>[],
  });

  final String iata;
  final String language;
  final String city;
  final String? summary;

  /// En qué idioma está el resumen (puede ser inglés si en el tuyo no hay).
  final String? summaryLanguage;
  final Uri? articleUrl;
  final PlacePhoto? photo;
  final int? population;
  final CountryFacts? country;
  final List<Attraction> attractions;

  /// Lo que piden las licencias que se vea junto a textos y fotos.
  final String attribution;

  static PlaceCard parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? iata = json['iata'];
    final Object? city = json['city'];
    final Object? lang = json['language'];
    final Object? attribution = json['attribution'];
    if (iata is! String || city is! String || city.isEmpty) _bad();
    if (lang is! String || attribution is! String) _bad();
    final Object? country = json['country'];
    final Object? attractions = json['attractions'];
    final Object? population = json['population'];
    return PlaceCard(
      iata: iata,
      language: lang,
      city: city,
      attribution: attribution,
      summary: _text(json['summary']),
      summaryLanguage: _text(json['summary_language']),
      articleUrl: _https(json['article_url']),
      photo: PlacePhoto.parse(json['photo']),
      population: population is int && population > 0 ? population : null,
      country: country is Map<String, Object?> && _text(country['name']) != null
          ? CountryFacts(
              name: _text(country['name'])!,
              capital: _text(country['capital']),
              currency: _text(country['currency']),
              languages: <String>[
                if (country['languages'] case final List<Object?> l)
                  for (final Object? x in l)
                    if (_text(x) case final String s) s,
              ],
            )
          : null,
      attractions: <Attraction>[
        if (attractions case final List<Object?> list)
          for (final Object? a in list)
            if (a is Map<String, Object?> && _text(a['name']) != null)
              Attraction(
                name: _text(a['name'])!,
                description: _text(a['description']),
                photo: PlacePhoto.parse(a['photo']),
                articleUrl: _https(a['article_url']),
                wikidataId: switch (_text(a['wikidata_id'])) {
                  final String q when RegExp(r'^Q[1-9]\d{0,11}$').hasMatch(q) =>
                    q,
                  _ => null,
                },
              ),
      ],
    );
  }
}

String? _text(Object? v) => v is String && v.trim().isNotEmpty ? v : null;

/// Solo enlaces https (nada de "javascript:" ni direcciones locales).
Uri? _https(Object? v) {
  if (v is! String) return null;
  final Uri? u = Uri.tryParse(v);
  return u != null && u.scheme == 'https' && u.host.isNotEmpty ? u : null;
}

Never _bad() => throw const ApiException(ApiError.unavailable);

/// Lo que necesita la pantalla: dame la ficha de este aeropuerto en este idioma.
typedef PlaceLoader = Future<PlaceCard?> Function(String iata, String lang);

class PlacesApi {
  PlacesApi(this._api);

  final ApiClient _api;
  final Map<String, Future<PlaceCard?>> _memo = <String, Future<PlaceCard?>>{};

  /// La ficha, o null si esa ciudad no tiene (404). Otros fallos lanzan
  /// [ApiException] y NO se recuerdan (se reintenta la próxima vez).
  Future<PlaceCard?> get(String iata, String lang) {
    final String key = '${iata.toUpperCase()}:$lang';
    return _memo[key] ??= _fetch(iata.toUpperCase(), lang).catchError((
      Object e,
    ) {
      _memo.remove(key);
      throw e;
    });
  }

  Future<PlaceCard?> _fetch(String iata, String lang) async {
    try {
      final Object? json = await _api.getJson(
        '/v1/places/${Uri.encodeComponent(iata)}',
        query: <String, String>{'lang': lang},
        public: true,
      );
      return PlaceCard.parse(json);
    } on ApiException catch (e) {
      if (e.error == ApiError.notFound) return null;
      rethrow;
    }
  }
}
