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
  });

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

  /// El trozo de mapa alrededor del centro: unos 12 km de lado.
  static const double citySpanDeg = 0.11;

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
  }) async {
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
      minLon: center.lon - citySpanDeg,
      minLat: center.lat - citySpanDeg,
      maxLon: center.lon + citySpanDeg,
      maxLat: center.lat + citySpanDeg,
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
    final List<PackZone> withAudio = <PackZone>[];
    for (int i = 0; i < saved.length; i++) {
      onProgress(
        DownloadProgress(DownloadStep.audio, done: i, total: saved.length),
      );
      withAudio.add(await _withAudio(code, saved[i], language));
    }

    // 4. El mapa. Si falla, la ciudad se guarda igual (con el aviso): las
    // audioguías ya descargadas siguen valiendo.
    onProgress(const DownloadProgress(DownloadStep.map, total: 1));
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

    final CityPack pack = CityPack(
      iata: code,
      city: city,
      language: language,
      zones: withAudio,
      tileBytes: tiles,
      savedAt: DateTime.now(),
      mapFailed: mapFailed,
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
        final Uint8List bytes = await api.getBytes(part.url.toString());
        final int size = await files.write(file, bytes);
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
