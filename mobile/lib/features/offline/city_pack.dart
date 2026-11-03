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

/// Cuánto de la ciudad se baja (como en la maqueta: "Elige la zona").
enum OfflineArea {
  /// El centro: unos 2 km a cada lado.
  center(0.02, 2),

  /// La ciudad: unos 8 km a cada lado.
  city(0.07, 8),

  /// Con alrededores: unos 20 km a cada lado.
  around(0.18, 20);

  const OfflineArea(this.halfDeg, this.km);

  /// Medio lado del cuadrado, en grados (1 grado ≈ 111 km).
  final double halfDeg;

  /// Para enseñarlo: "2 km", "8 km", "20 km".
  final int km;

  static OfflineArea? byName(Object? name) =>
      OfflineArea.values.where((OfflineArea a) => a.name == name).firstOrNull;
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
    this.area = OfflineArea.city,
    this.withAudio = true,
    this.mapVersion,
  });

  /// Qué versión del mapa se bajó (la fecha con la que OpenFreeMap publica
  /// cada mapa nuevo, "20261025_080012"). Sirve para avisar de que hay uno
  /// más nuevo. null = no se sabe (servidor de mapas sin versión).
  final String? mapVersion;

  /// Cuánto de la ciudad se bajó.
  final OfflineArea area;

  /// false = elegiste no bajar las voces de las audioguías (solo el texto).
  final bool withAudio;

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
    'area': area.name,
    if (!withAudio) 'with_audio': false,
    'map_version': ?mapVersion,
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
      // Las ciudades bajadas antes de poder elegir eran "la ciudad".
      area: OfflineArea.byName(json['area']) ?? OfflineArea.city,
      withAudio: json['with_audio'] != false,
      mapVersion: switch (json['map_version']) {
        final String v when mapVersionPattern.hasMatch(v) => v,
        _ => null,
      },
    );
  }
}

/// Cómo es una versión de mapa: "20261025_080012" (año, mes, día, hora).
final RegExp mapVersionPattern = RegExp(r'^\d{8}_\d{6}$');

/// El día de una versión de mapa ("20261025_080012" → 25/10/2026).
DateTime? mapVersionDay(String? version) {
  if (version == null || !mapVersionPattern.hasMatch(version)) return null;
  return DateTime.tryParse(version.substring(0, 8));
}

/// ¿Hay un mapa más nuevo que el que bajaste? Solo si se saben las dos
/// versiones (si no, no se avisa: mejor callar que inventar).
bool hasNewerMap(CityPack pack, String? latest) {
  final String? mine = pack.mapVersion;
  if (mine == null || latest == null || pack.mapFailed) return false;
  return latest.compareTo(mine) > 0;
}

/// Lo que ocupará aproximadamente una ciudad, sacado de lo que ocuparon DE
/// VERDAD las que ya bajaste en este móvil (no es un número inventado):
///   - el mapa: los bytes por grado² de tus otras ciudades × el trozo nuevo;
///   - las voces: lo que ocuparon de media las ciudades bajadas con voces.
/// null = aún no has bajado ninguna, así que no hay con qué calcularlo.
int? estimateBytes(
  List<CityPack> done, {
  required OfflineArea area,
  required bool withAudio,
}) {
  double side(OfflineArea a) => 2 * a.halfDeg;
  final List<double> perDeg = <double>[
    for (final CityPack p in done)
      if (!p.mapFailed && p.tileBytes > 0)
        p.tileBytes / (side(p.area) * side(p.area)),
  ];
  if (perDeg.isEmpty) return null;
  final double map =
      perDeg.reduce((double a, double b) => a + b) /
      perDeg.length *
      side(area) *
      side(area);
  if (!withAudio) return map.round();
  final List<int> voices = <int>[
    for (final CityPack p in done)
      if (p.withAudio && p.audioBytes > 0) p.audioBytes,
  ];
  // Sin ninguna ciudad con voces no se puede decir cuánto ocupan.
  if (voices.isEmpty) return null;
  return (map + voices.reduce((int a, int b) => a + b) / voices.length).round();
}

/// Una descarga que se paró a medias (la paraste tú o se fue la red): lo
/// que ya se bajó se queda y "Seguir" continúa desde ahí.
class PausedDownload {
  const PausedDownload({
    required this.iata,
    required this.city,
    required this.area,
    required this.withAudio,
  });

  final String iata;
  final String city;
  final OfflineArea area;
  final bool withAudio;

  Map<String, Object?> toJson() => <String, Object?>{
    'iata': iata,
    'city': city,
    'area': area.name,
    'with_audio': withAudio,
  };

  static PausedDownload? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? iata = json['iata'];
    final Object? city = json['city'];
    if (iata is! String || iata.length != 3 || city is! String) return null;
    return PausedDownload(
      iata: iata.toUpperCase(),
      city: city,
      area: OfflineArea.byName(json['area']) ?? OfflineArea.city,
      withAudio: json['with_audio'] != false,
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

  /// Las descargas paradas a medias (como mucho una por ciudad).
  List<PausedDownload> paused() {
    try {
      final Object? list = jsonDecode(
        _store.readData(LocalData.offlinePaused) ?? '[]',
      );
      if (list is! List<Object?>) return <PausedDownload>[];
      return <PausedDownload>[
        for (final Object? p in list) ?PausedDownload.parse(p),
      ];
    } on FormatException {
      return <PausedDownload>[];
    }
  }

  Future<void> pause(PausedDownload p) => _writePaused(<PausedDownload>[
    p,
    for (final PausedDownload o in paused())
      if (o.iata != p.iata) o,
  ]);

  Future<void> unpause(String iata) => _writePaused(<PausedDownload>[
    for (final PausedDownload o in paused())
      if (o.iata != iata.toUpperCase()) o,
  ]);

  Future<void> _writePaused(List<PausedDownload> list) => _store.writeData(
    LocalData.offlinePaused,
    list.isEmpty
        ? null
        : jsonEncode(<Object?>[
            for (final PausedDownload p in list.take(maxCities)) p.toJson(),
          ]),
  );

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
