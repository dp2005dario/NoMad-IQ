// La descarga de una ciudad, paso a paso. Lo de fuera (archivos, mapa y red)
// entra como "enchufes" (interfaces): así en los tests se puede probar la
// descarga entera sin tocar el disco ni Internet.
import 'dart:async';
import 'dart:typed_data';

import '../../core/api_client.dart';
import '../audioguide/audioguide_api.dart';
import '../map/geo.dart';
import '../map/geo_api.dart';
import '../route/geo.dart' show LatLon;
import 'city_pack.dart';

/// Guardar y borrar archivos dentro de la carpeta privada de la app.
abstract interface class OfflineFiles {
  /// Guarda [bytes] en [path] (ruta relativa) y devuelve lo que ocupa.
  Future<int> write(String path, Uint8List bytes);

  /// Borra una carpeta entera con lo que haya dentro.
  Future<void> deleteFolder(String path);

  /// Lo que ocupa un archivo ya guardado (null = no está). Sirve para
  /// SEGUIR una descarga parada sin volver a bajar lo que ya está.
  Future<int?> sizeOf(String path);
}

/// Guardar y borrar el mapa descargado (las teselas de MapLibre).
abstract interface class OfflineMaps {
  /// Descarga el trozo de mapa de [box] y devuelve lo que ocupa en bytes.
  /// [onProgress] va de 0 a 1.
  Future<int> download({
    required String iata,
    required GeoBox box,
    required void Function(double fraction) onProgress,
  });

  Future<void> delete(String iata);
}

/// Qué red hay ahora (wifi, datos o nada).
abstract interface class NetProbe {
  Future<NetKind> now();
}

/// La versión del mapa que publica ahora el servidor de mapas
/// ("20261025_080012"). null = no se sabe (sin red o servidor sin versión).
abstract interface class MapVersionProbe {
  Future<String?> latest();
}

/// Sin versión de mapa (tests y servidores de mapas que no la dicen).
class NoMapVersion implements MapVersionProbe {
  const NoMapVersion();

  @override
  Future<String?> latest() async => null;
}

/// ¿El móvil está cargando? (para actualizar solas sin gastar batería)
abstract interface class PowerProbe {
  Future<bool> charging();
}

/// En los tests, por defecto, nunca está cargando.
class NeverCharging implements PowerProbe {
  const NeverCharging();

  @override
  Future<bool> charging() async => false;
}

/// Lo que puede fallar al descargar una ciudad.
enum DownloadError {
  /// No hay red, o hay datos pero has pedido "solo con wifi".
  waitingForWifi,

  /// No hay conexión ninguna.
  offline,

  /// Esa ciudad no tiene ninguna zona con audioguía.
  nothingThere,

  /// El servidor falló o se cortó la descarga.
  failed,

  /// La paraste tú ("Parar descarga").
  cancelled,
}

class DownloadException implements Exception {
  const DownloadException(this.error);

  final DownloadError error;

  @override
  String toString() => 'DownloadException($error)';
}

/// Archivos en memoria: en los tests, y en una compilación sin almacenamiento.
class MemoryOfflineFiles implements OfflineFiles {
  final Map<String, int> written = <String, int>{};

  @override
  Future<int> write(String path, Uint8List bytes) async {
    written[path] = bytes.length;
    return bytes.length;
  }

  @override
  Future<void> deleteFolder(String path) async {
    written.removeWhere((String key, int _) => key.startsWith(path));
  }

  @override
  Future<int?> sizeOf(String path) async => written[path];
}

/// Sin mapa descargable (tests): la ciudad se guarda con el aviso de que el
/// mapa no está.
class NoOfflineMaps implements OfflineMaps {
  const NoOfflineMaps();

  @override
  Future<int> download({
    required String iata,
    required GeoBox box,
    required void Function(double fraction) onProgress,
  }) async => throw UnimplementedError('sin mapa descargable');

  @override
  Future<void> delete(String iata) async {}
}

/// En los tests se da por hecho que hay wifi.
class AlwaysWifi implements NetProbe {
  const AlwaysWifi();

  @override
  Future<NetKind> now() async => NetKind.wifi;
}

/// Descarga la ciudad: zonas → guiones → audios → mapa.
class CityDownloader {
  const CityDownloader({
    required this.api,
    required this.geo,
    required this.guides,
    required this.files,
    required this.maps,
    required this.net,
    required this.cities,
    this.mapVersion = const NoMapVersion(),
  });

  /// Qué versión del mapa hay ahora (se guarda con la ciudad).
  final MapVersionProbe mapVersion;

  final ApiClient api;
  final GeoApi geo;
  final AudioguideApi guides;
  final OfflineFiles files;
  final OfflineMaps maps;
  final NetProbe net;

  /// Lo que ya hay descargado en este móvil.
  final OfflineLibrary cities;

  /// Cuántas zonas se guardan como máximo por ciudad: con 40 hay de sobra
  /// para un centro histórico y no se dispara el tamaño.
  static const int maxZones = 40;

  /// Descarga la ciudad [iata] (centrada en [center]) en [language].
  ///
  /// [onProgress] se llama a cada paso para mover la barra. Lanza
  /// [DownloadException] si no se puede.
  Future<CityPack> run({
    required String iata,
    required String city,
    required LatLon center,
    required String language,
    required bool wifiOnly,
    required void Function(DownloadProgress) onProgress,
    bool Function()? stopped,
    OfflineArea area = OfflineArea.city,
    bool withAudio = true,
  }) async {
    // Entre paso y paso se mira si has tocado "Parar descarga".
    void check() {
      if (stopped?.call() ?? false) {
        throw const DownloadException(DownloadError.cancelled);
      }
    }

    final NetKind kind = await net.now();
    if (!mayDownload(wifiOnly: wifiOnly, net: kind)) {
      throw DownloadException(
        kind == NetKind.none
            ? DownloadError.offline
            : DownloadError.waitingForWifi,
      );
    }
    final String code = iata.toUpperCase();
    final GeoBox box = GeoBox(
      minLon: center.lon - area.halfDeg,
      minLat: center.lat - area.halfDeg,
      maxLon: center.lon + area.halfDeg,
      maxLat: center.lat + area.halfDeg,
    );

    // 1. Las zonas (los barrios con audioguía).
    onProgress(const DownloadProgress(DownloadStep.zones));
    final List<Zone> zones;
    try {
      zones = (await geo.zones(box)).zones.take(maxZones).toList();
    } on ApiException {
      throw const DownloadException(DownloadError.failed);
    }
    if (zones.isEmpty) {
      throw const DownloadException(DownloadError.nothingThere);
    }

    // 2. Los guiones. Una zona sin audioguía preparada no rompe nada: se
    // salta y se avisa al final con las que sí hay.
    final List<PackZone> saved = <PackZone>[];
    for (int i = 0; i < zones.length; i++) {
      check();
      onProgress(
        DownloadProgress(DownloadStep.guides, done: i, total: zones.length),
      );
      final Zone zone = zones[i];
      final GuideScript? script = await _script(zone.id, language);
      if (script == null) continue;
      saved.add(
        PackZone(
          id: zone.id,
          name: zone.name,
          title: script.title,
          texts: <String>[for (final GuideSegment s in script.segments) s.text],
          audio: const <PackAudio>[],
        ),
      );
    }
    if (saved.isEmpty) {
      throw const DownloadException(DownloadError.nothingThere);
    }

    // 3. Los audios (.opus) en la carpeta de la ciudad.
    final List<PackZone> voiced = <PackZone>[];
    // Sin voces (lo elegiste tú): las audioguías se quedan con su texto.
    for (int i = 0; i < saved.length && withAudio; i++) {
      check();
      onProgress(
        DownloadProgress(DownloadStep.audio, done: i, total: saved.length),
      );
      voiced.add(await _withAudio(code, saved[i], language));
    }
    if (!withAudio) voiced.addAll(saved);

    check();
    // 4. El mapa. Si falla, la ciudad se guarda igual (con el aviso): las
    // audioguías ya descargadas siguen valiendo.
    onProgress(const DownloadProgress(DownloadStep.map, total: 1));
    // La versión se pide ANTES de bajar: así, si sale un mapa nuevo durante
    // la descarga, la próxima vez se avisa en vez de creer que está al día.
    String? version;
    try {
      version = await mapVersion.latest();
    } on Object {
      version = null;
    }
    int tiles = 0;
    bool mapFailed = false;
    try {
      tiles = await maps.download(
        iata: code,
        box: box,
        onProgress: (double f) => onProgress(
          DownloadProgress(
            DownloadStep.map,
            done: (f * 100).round(),
            total: 100,
          ),
        ),
      );
    } on Object {
      mapFailed = true;
    }

    check();
    final CityPack pack = CityPack(
      iata: code,
      city: city,
      language: language,
      zones: voiced,
      tileBytes: tiles,
      savedAt: DateTime.now(),
      mapFailed: mapFailed,
      area: area,
      withAudio: withAudio,
      mapVersion: mapFailed ? null : version,
    );
    await cities.save(pack);
    return pack;
  }

  /// Borra una ciudad: el mapa, los audios y la ficha.
  Future<void> forget(String iata) async {
    final String code = iata.toUpperCase();
    try {
      await maps.delete(code);
    } on Object {
      // Si el mapa ya no estaba, da igual: lo importante es que la ciudad
      // desaparezca de la lista y no ocupe sitio.
    }
    await files.deleteFolder(cityFolder(code));
    await cities.remove(code);
  }

  Future<GuideScript?> _script(String zoneId, String language) async {
    try {
      return await guides.script(zoneId, language);
    } on ApiException catch (e) {
      // notFound = aún no está escrita; el resto, tampoco impide seguir.
      if (e.error == ApiError.network) {
        throw const DownloadException(DownloadError.offline);
      }
      return null;
    }
  }

  Future<PackZone> _withAudio(
    String iata,
    PackZone zone,
    String language,
  ) async {
    final AudioManifest manifest;
    try {
      manifest = await guides.audio(zone.id, language);
    } on ApiException catch (e) {
      if (e.error == ApiError.network) {
        throw const DownloadException(DownloadError.offline);
      }
      // Sin audio grabado la zona se queda con el texto: se puede leer.
      return zone;
    }
    final List<PackAudio> parts = <PackAudio>[];
    for (final AudioPart part in manifest.parts) {
      final String file =
          '${cityFolder(iata)}/${_safe(zone.id)}-'
          '${part.index}.opus';
      try {
        // Ya bajado en un intento anterior (descarga parada): no se repite.
        final int? had = await files.sizeOf(file);
        final int size =
            had ??
            await files.write(file, await api.getBytes(part.url.toString()));
        parts.add(
          PackAudio(
            index: part.index,
            file: file,
            bytes: size,
            seconds: part.duration.inSeconds,
          ),
        );
      } on ApiException catch (e) {
        if (e.error == ApiError.network) {
          throw const DownloadException(DownloadError.offline);
        }
        // Un trozo que ya no está (410) no tumba la descarga: la audioguía
        // se queda sin audio y se lee el texto.
        return zone;
      }
    }
    return PackZone(
      id: zone.id,
      name: zone.name,
      title: zone.title,
      texts: zone.texts,
      audio: parts,
    );
  }

  /// El id de la zona se usa como nombre de archivo: fuera todo lo que no
  /// sea una letra o un número, para no inventar rutas raras.
  static String _safe(String id) =>
      id.replaceAll(RegExp('[^A-Za-z0-9_-]'), '_');
}
