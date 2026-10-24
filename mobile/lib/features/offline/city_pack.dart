// "Sin conexión" (maqueta "SinConexion"): lo que se guarda de una ciudad para
// que el mapa, las audioguías y los avisos de zona funcionen en modo avión o
// en el extranjero sin datos.
//
// Aquí solo están las CUENTAS y el guardado (sin pantalla ni red), que es lo
// que se puede probar a conciencia:
//   - qué lleva el paquete de una ciudad y cuánto ocupa;
//   - si toca descargar ahora o esperar al wifi;
//   - cómo va la descarga (el porcentaje de la barra).
import 'dart:convert';

import '../../core/settings.dart';

/// Un trozo de audio ya guardado en el móvil.
class PackAudio {
  const PackAudio({
    required this.index,
    required this.file,
    required this.bytes,
    required this.seconds,
  });

  /// El orden dentro de la audioguía (0, 1, 2...).
  final int index;

  /// Ruta DENTRO de la carpeta de la app ("offline/NRT/zona-0.opus").
  final String file;
  final int bytes;
  final int seconds;

  Map<String, Object?> toJson() => <String, Object?>{
    'index': index,
    'file': file,
    'bytes': bytes,
    'seconds': seconds,
  };

  static PackAudio? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? index = json['index'];
    final Object? file = json['file'];
    final Object? bytes = json['bytes'];
    final Object? seconds = json['seconds'];
    if (index is! int || index < 0) return null;
    if (file is! String || file.isEmpty || file.contains('..')) return null;
    if (bytes is! int || bytes < 0) return null;
    return PackAudio(
      index: index,
      file: file,
      bytes: bytes,
      seconds: seconds is int && seconds >= 0 ? seconds : 0,
    );
  }
}

/// Una zona de la ciudad, con su audioguía guardada.
class PackZone {
  const PackZone({
    required this.id,
    required this.name,
    required this.title,
    required this.texts,
    required this.audio,
  });

  final String id;
  final String name;

  /// El título de la audioguía ("El Madrid de los Austrias").
  final String title;

  /// El guion escrito: sirve para leerlo cuando no hay audio grabado.
  final List<String> texts;
  final List<PackAudio> audio;

  int get bytes => audio.fold(0, (int a, PackAudio p) => a + p.bytes);

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'title': title,
    'texts': texts,
    'audio': <Object?>[for (final PackAudio a in audio) a.toJson()],
  };

  static PackZone? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? name = json['name'];
    if (id is! String || id.isEmpty || name is! String) return null;
    final Object? texts = json['texts'];
    final Object? audio = json['audio'];
    return PackZone(
      id: id,
      name: name,
      title: json['title'] is String ? json['title']! as String : name,
      texts: <String>[
        if (texts is List<Object?>)
          for (final Object? t in texts) ?(t is String ? t : null),
      ],
      audio: <PackAudio>[
        if (audio is List<Object?>)
          for (final Object? a in audio) ?PackAudio.parse(a),
      ]..sort((PackAudio a, PackAudio b) => a.index.compareTo(b.index)),
    );
  }
}

/// Todo lo guardado de una ciudad.
class CityPack {
  const CityPack({
    required this.iata,
    required this.city,
    required this.language,
    required this.zones,
    required this.tileBytes,
    required this.savedAt,
    this.mapFailed = false,
  });

  /// El código del aeropuerto, que es como se nombran las ciudades en la app.
  final String iata;
  final String city;

  /// En qué idioma se bajaron las audioguías: si cambias de idioma, hay que
  /// volver a descargar (y la pantalla lo dice).
  final String language;
  final List<PackZone> zones;

  /// Lo que ocupa el mapa descargado (las "teselas").
  final int tileBytes;
  final DateTime savedAt;

  /// true si el mapa no se pudo guardar pero las audioguías sí. La pantalla
  /// lo avisa en vez de hacer creer que todo está listo.
  final bool mapFailed;

  int get audioBytes => zones.fold(0, (int a, PackZone z) => a + z.bytes);
  int get bytes => tileBytes + audioBytes;
  int get guides => zones.where((PackZone z) => z.audio.isNotEmpty).length;

  Map<String, Object?> toJson() => <String, Object?>{
    'iata': iata,
    'city': city,
    'language': language,
    'zones': <Object?>[for (final PackZone z in zones) z.toJson()],
    'tile_bytes': tileBytes,
    'saved_at': savedAt.toUtc().toIso8601String(),
    if (mapFailed) 'map_failed': true,
  };

  static CityPack? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? iata = json['iata'];
    final Object? city = json['city'];
    final Object? saved = json['saved_at'];
    if (iata is! String || iata.length != 3) return null;
    if (city is! String || saved is! String) return null;
    final DateTime? at = DateTime.tryParse(saved);
    if (at == null) return null;
    final Object? zones = json['zones'];
    final Object? tiles = json['tile_bytes'];
    return CityPack(
      iata: iata.toUpperCase(),
      city: city,
      language: json['language'] is String ? json['language']! as String : 'en',
      zones: <PackZone>[
        if (zones is List<Object?>)
          for (final Object? z in zones) ?PackZone.parse(z),
      ],
      tileBytes: tiles is int && tiles >= 0 ? tiles : 0,
      savedAt: at.toLocal(),
      mapFailed: json['map_failed'] == true,
    );
  }
}

/// La carpeta (dentro de la app) donde van los audios de una ciudad.
String cityFolder(String iata) => 'offline/${iata.toUpperCase()}';

/// Lo que hay descargado en este móvil. Vive SOLO aquí.
class OfflineLibrary {
  const OfflineLibrary(this._store);

  final SettingsStore _store;

  /// Como máximo se guardan 10 ciudades: así no se llena el teléfono sin
  /// darse cuenta.
  static const int maxCities = 10;

  List<CityPack> all() {
    try {
      final Object? list = jsonDecode(
        _store.readData(LocalData.offlineCities) ?? '[]',
      );
      if (list is! List<Object?>) return <CityPack>[];
      return <CityPack>[for (final Object? p in list) ?CityPack.parse(p)]
        // La última descargada, arriba.
        ..sort((CityPack a, CityPack b) => b.savedAt.compareTo(a.savedAt));
    } on FormatException {
      return <CityPack>[];
    }
  }

  CityPack? of(String iata) {
    final String code = iata.trim().toUpperCase();
    for (final CityPack p in all()) {
      if (p.iata == code) return p;
    }
    return null;
  }

  int get totalBytes => all().fold(0, (int a, CityPack p) => a + p.bytes);

  /// Guarda (o sustituye) una ciudad. Si ya hay 10, se tira la más vieja.
  Future<void> save(CityPack pack) async {
    final List<CityPack> kept = <CityPack>[
      pack,
      for (final CityPack p in all())
        if (p.iata != pack.iata) p,
    ];
    await _write(kept.take(maxCities).toList());
  }

  Future<void> remove(String iata) async {
    final String code = iata.trim().toUpperCase();
    await _write(<CityPack>[
      for (final CityPack p in all())
        if (p.iata != code) p,
    ]);
  }

  Future<void> _write(List<CityPack> packs) => _store.writeData(
    LocalData.offlineCities,
    jsonEncode(<Object?>[for (final CityPack p in packs) p.toJson()]),
  );
}

/// Por dónde va la descarga.
enum DownloadStep {
  zones, // pidiendo la lista de barrios
  guides, // bajando los guiones
  audio, // bajando los .opus
  map, // guardando el mapa
}

/// Cuánto llevamos: sirve para la barra y para el texto ("3 de 12").
class DownloadProgress {
  const DownloadProgress(this.step, {this.done = 0, this.total = 0});

  final DownloadStep step;
  final int done;
  final int total;

  /// De 0 a 1, repartido entre los cuatro pasos (el audio es el que más
  /// tarda, así que se lleva la mitad de la barra).
  double get fraction {
    const Map<DownloadStep, (double, double)> span =
        <DownloadStep, (double, double)>{
          DownloadStep.zones: (0.0, 0.1),
          DownloadStep.guides: (0.1, 0.3),
          DownloadStep.audio: (0.3, 0.8),
          DownloadStep.map: (0.8, 1.0),
        };
    final (double from, double to) = span[step]!;
    final double inside = total <= 0 ? 0 : (done / total).clamp(0.0, 1.0);
    return from + (to - from) * inside;
  }
}

/// Cómo está la red ahora mismo.
enum NetKind { wifi, mobile, none }

/// ¿Se puede descargar ahora? Con "solo wifi" marcado, con datos del móvil
/// se espera (así nadie se gasta la tarifa en el extranjero sin querer).
bool mayDownload({required bool wifiOnly, required NetKind net}) =>
    switch (net) {
      NetKind.wifi => true,
      NetKind.mobile => !wifiOnly,
      NetKind.none => false,
    };

/// "48 MB", "900 kB": el tamaño como lo diría una persona.
String sizeLabel(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) return '${(bytes / (1024 * 1024)).round()} MB';
  if (bytes >= 1024) return '${(bytes / 1024).round()} kB';
  return '$bytes B';
}
