// El modo cámara habla con el ai-orchestrator (por la puerta de entrada):
//   POST /v1/landmarks/recognize  → ¿qué monumento tengo delante?
//   GET  /v1/landmarks/{qid}      → la ficha de otro (al tocar "¿No es este?")
//
// La app manda dónde estás (GPS), hacia dónde miras (brújula) y una foto
// pequeña. El servidor busca los lugares famosos de alrededor en Wikidata y,
// si tiene un modelo de visión, mira la foto para elegir. La foto NO se
// guarda en ningún sitio.
import 'dart:convert';
import 'dart:typed_data';

import '../../core/api_client.dart';
import '../route/places_api.dart';

/// Cómo de seguro está el servidor.
enum RecognitionStatus {
  recognized, // lo ha visto en la foto: "RECONOCIDO"
  guess, // lo más probable por dónde estás y hacia dónde miras: "¿ES ESTE?"
  none, // no hay nada conocido cerca (o la foto no muestra ninguno)
}

/// La ficha del monumento (la tarjeta de abajo de la maqueta).
class Landmark {
  const Landmark({
    required this.qid,
    required this.name,
    required this.lat,
    required this.lon,
    this.description,
    this.year,
    this.photo,
    this.summary,
    this.articleUrl,
    this.distanceM,
  });

  /// El identificador de Wikidata ("Q1503138"): también la clave del sello.
  final String qid;
  final String name;
  final double lat;
  final double lon;
  final String? description;
  final int? year;
  final PlacePhoto? photo;
  final String? summary;
  final Uri? articleUrl;
  final int? distanceM;

  static Landmark parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final Object? qid = json['qid'];
    final Object? name = json['name'];
    final Object? lat = json['lat'];
    final Object? lon = json['lon'];
    if (qid is! String ||
        !RegExp(r'^Q[1-9][0-9]{0,11}$').hasMatch(qid) ||
        name is! String ||
        name.trim().isEmpty ||
        lat is! num ||
        lon is! num) {
      _bad();
    }
    final Object? article = json['article_url'];
    final Uri? articleUrl = article is String ? Uri.tryParse(article) : null;
    return Landmark(
      qid: qid,
      name: name.trim(),
      lat: lat.toDouble(),
      lon: lon.toDouble(),
      description: _text(json['description']),
      year: json['year'] is int ? json['year']! as int : null,
      photo: PlacePhoto.parse(json['photo']),
      summary: _text(json['summary']),
      // Solo enlaces seguros a Wikipedia (se abren en el navegador).
      articleUrl:
          articleUrl != null &&
              articleUrl.scheme == 'https' &&
              articleUrl.host.endsWith('.wikipedia.org')
          ? articleUrl
          : null,
      distanceM: json['distance_m'] is int ? json['distance_m']! as int : null,
    );
  }
}

/// Otro lugar cercano, por si no era el que apuntabas.
class Alternative {
  const Alternative({
    required this.qid,
    required this.name,
    required this.distanceM,
  });

  final String qid;
  final String name;
  final int distanceM;
}

class Recognition {
  const Recognition({
    required this.status,
    this.landmark,
    this.alternatives = const <Alternative>[],
  });

  final RecognitionStatus status;
  final Landmark? landmark;
  final List<Alternative> alternatives;

  static Recognition parse(Object? json) {
    if (json is! Map<String, Object?>) _bad();
    final RecognitionStatus status = switch (json['status']) {
      'recognized' => RecognitionStatus.recognized,
      'guess' => RecognitionStatus.guess,
      'none' => RecognitionStatus.none,
      _ => _bad(),
    };
    final Object? alts = json['alternatives'];
    final List<Alternative> alternatives = <Alternative>[
      if (alts is List<Object?>)
        for (final Object? a in alts)
          if (a is Map<String, Object?> &&
              a['qid'] is String &&
              a['name'] is String &&
              a['distance_m'] is int)
            Alternative(
              qid: a['qid']! as String,
              name: a['name']! as String,
              distanceM: a['distance_m']! as int,
            ),
    ];
    final Object? landmark = json['landmark'];
    final Landmark? parsed = landmark == null ? null : Landmark.parse(landmark);
    if (status != RecognitionStatus.none && parsed == null) _bad();
    return Recognition(
      status: status,
      landmark: parsed,
      alternatives: alternatives,
    );
  }
}

class LandmarksApi {
  const LandmarksApi(this._api);

  final ApiClient _api;

  /// Errores (ApiException): signedOut (invitado), rateLimited (sin usos
  /// hoy), unavailable (ocupado) o network (sin internet).
  Future<Recognition> recognize({
    required double lat,
    required double lon,
    required double accuracyM,
    required String language,
    double? heading,
    Uint8List? jpeg,
  }) async => Recognition.parse(
    await _api.postJson('/v1/landmarks/recognize', <String, Object?>{
      'lat': lat,
      'lon': lon,
      'accuracy_m': accuracyM.clamp(0, 2000),
      'language': language,
      if (heading != null) 'heading': heading % 360,
      if (jpeg != null) 'image': base64Encode(jpeg),
    }),
  );

  Future<Landmark> get(String qid, String language) async => Landmark.parse(
    await _api.getJson(
      '/v1/landmarks/${Uri.encodeComponent(qid)}',
      query: <String, String>{'lang': language},
    ),
  );
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

Never _bad() => throw const ApiException(ApiError.unavailable);
