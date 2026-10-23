// Las llamadas de la audioguía al ai-orchestrator (a través de la puerta):
//   GET /v1/audioguides/{zona}?lang=es        → el guion (texto por partes)
//   GET /v1/audioguides/{zona}/audio?lang=es  → el "manifiesto" del audio:
//        qué archivos .opus reproducir y en qué orden
import '../../core/api_client.dart';

/// Un trozo del guion (unos 20-30 segundos hablado).
class GuideSegment {
  const GuideSegment(this.text);

  final String text;
}

/// El guion de la audioguía de una zona.
class GuideScript {
  const GuideScript({
    required this.zoneName,
    required this.title,
    required this.contentLanguage,
    required this.segments,
  });

  final String zoneName;
  final String title;

  /// Idioma en el que está escrito de verdad (si aún no hay traducción a
  /// tu idioma, puede venir en otro: la pantalla lo avisa).
  final String contentLanguage;
  final List<GuideSegment> segments;
}

/// Una parte del audio: un archivo .opus y lo que dice.
class AudioPart {
  const AudioPart({
    required this.index,
    required this.url,
    required this.duration,
    required this.text,
  });

  final int index;
  final Uri url;
  final Duration duration;
  final String text;
}

/// El manifiesto: la lista ordenada de partes.
class AudioManifest {
  const AudioManifest({
    required this.parts,
    required this.stale,
    required this.contentLanguage,
  });

  final List<AudioPart> parts;

  /// true si es la versión anterior (la nueva aún se está grabando).
  final bool stale;
  final String contentLanguage;

  Duration get total =>
      parts.fold(Duration.zero, (Duration a, AudioPart p) => a + p.duration);
}

class AudioguideApi {
  AudioguideApi(this._api);

  final ApiClient _api;

  /// El guion. Lanza ApiError.notFound si aún no está listo (el servidor lo
  /// prepara en cuanto alguien entra en la zona: hay que volver a preguntar).
  Future<GuideScript> script(String zoneId, String language) async {
    final Object? json = await _api.getJson(
      '/v1/audioguides/${Uri.encodeComponent(zoneId)}',
      query: <String, String>{'lang': language},
    );
    if (json is! Map<String, Object?>) _bad();
    final Object? segments = json['segments'];
    if (segments is! List<Object?> || segments.isEmpty) _bad();
    return GuideScript(
      zoneName: _text(json, 'zone_name'),
      title: _text(json, 'title'),
      contentLanguage: _text(json, 'content_language'),
      segments: <GuideSegment>[
        for (final Object? s in segments)
          if (s is Map<String, Object?> && s['text'] is String)
            GuideSegment(s['text']! as String)
          else
            _bad(),
      ],
    );
  }

  /// El audio. ApiError.notFound = aún no está grabado (se lee el texto).
  Future<AudioManifest> audio(String zoneId, String language) async {
    final Object? json = await _api.getJson(
      '/v1/audioguides/${Uri.encodeComponent(zoneId)}/audio',
      query: <String, String>{'lang': language},
    );
    if (json is! Map<String, Object?>) _bad();
    final Object? parts = json['parts'];
    if (parts is! List<Object?> || parts.isEmpty) _bad();
    final List<AudioPart> list = <AudioPart>[
      for (final Object? p in parts) _part(p),
    ]..sort((AudioPart a, AudioPart b) => a.index.compareTo(b.index));
    return AudioManifest(
      parts: list,
      stale: json['stale'] == true,
      contentLanguage: _text(json, 'content_language'),
    );
  }

  AudioPart _part(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? index = json['index'];
    final Object? seconds = json['duration_seconds'];
    if (index is! int || seconds is! num || seconds < 0) _bad();
    // La URL puede ser una ruta del servidor ("/v1/audio/...") o una
    // dirección completa de una CDN: resolve() entiende las dos.
    final Uri url = _api.resolve(_text(json, 'url'));
    // Solo audio cifrado (https), salvo en el PC de desarrollo (http).
    if (url.scheme != 'https' && url.scheme != 'http') _bad();
    return AudioPart(
      index: index,
      url: url,
      duration: Duration(milliseconds: (seconds * 1000).round()),
      text: json['text'] is String ? json['text']! as String : '',
    );
  }

  static String _text(Map<String, Object?> json, String key) {
    final Object? value = json[key];
    if (value is! String || value.isEmpty) _bad();
    return value;
  }

  static Never _bad() => throw const ApiException(ApiError.unavailable);
}
