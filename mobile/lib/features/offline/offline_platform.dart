// Las piezas de verdad de "Sin conexión": archivos en la carpeta privada de
// la app, el mapa descargado con MapLibre y saber si hay wifi.
//
// En los tests NO se usa nada de esto (se enchufan versiones de mentira):
// aquí vive justo lo que necesita el móvil real.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:http/http.dart' as http;
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:path_provider/path_provider.dart';

import '../map/geo.dart';
import 'city_pack.dart';
import 'city_downloader.dart';

/// Archivos dentro de `getApplicationSupportDirectory()`: una carpeta privada
/// de la app que no se ve desde la galería ni la comparte nadie, y que se
/// borra sola al desinstalar.
class AppOfflineFiles implements OfflineFiles {
  Future<Directory> _root() => getApplicationSupportDirectory();

  @override
  Future<int> write(String path, Uint8List bytes) async {
    final Directory root = await _root();
    final File file = File('${root.path}/$path');
    await file.parent.create(recursive: true);
    // Primero a un archivo ".part" y luego se le cambia el nombre: así, si la
    // descarga se corta a medio escribir, no queda un audio roto que luego
    // se daría por bueno al "Seguir".
    final File part = File('${file.path}.part');
    await part.writeAsBytes(bytes, flush: true);
    await part.rename(file.path);
    return bytes.length;
  }

  @override
  Future<int?> sizeOf(String path) async {
    final File file = File('${(await _root()).path}/$path');
    if (!await file.exists()) return null;
    final int size = await file.length();
    return size > 0 ? size : null;
  }

  @override
  Future<void> deleteFolder(String path) async {
    final Directory root = await _root();
    final Directory dir = Directory('${root.path}/$path');
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  /// La ruta completa de un archivo guardado (para dárselo al reproductor).
  Future<Uri> uriOf(String path) async =>
      Uri.file('${(await _root()).path}/$path');
}

/// El mapa descargado. MapLibre guarda las teselas en su propia base de
/// datos y pide el estilo por una dirección, así que el estilo de la app
/// (que se genera en código) se escribe antes en un archivo y se le pasa
/// como `file://...`.
class MapLibreOfflineMaps implements OfflineMaps {
  MapLibreOfflineMaps({required this.styleJson});

  /// Devuelve el estilo del mapa en JSON (el mismo que usa la pantalla).
  final String Function() styleJson;

  /// Niveles de zoom que se guardan: del 11 (la ciudad entera) al 16 (la
  /// calle). Bajar más multiplicaría el tamaño por cuatro en cada nivel.
  static const double minZoom = 11;
  static const double maxZoom = 16;

  @override
  Future<int> download({
    required String iata,
    required GeoBox box,
    required void Function(double fraction) onProgress,
  }) async {
    final Directory dir = await getApplicationSupportDirectory();
    final File style = File('${dir.path}/${cityFolder(iata)}/estilo.json');
    await style.parent.create(recursive: true);
    await style.writeAsString(styleJson(), flush: true);
    int bytes = 0;
    final ml.OfflineRegion fresh = await ml.downloadOfflineRegion(
      ml.OfflineRegionDefinition(
        bounds: ml.LatLngBounds(
          southwest: ml.LatLng(box.minLat, box.minLon),
          northeast: ml.LatLng(box.maxLat, box.maxLon),
        ),
        mapStyleUrl: style.uri.toString(),
        minZoom: minZoom,
        maxZoom: maxZoom,
      ),
      metadata: <String, dynamic>{'iata': iata},
      onEvent: (ml.DownloadRegionStatus event) {
        if (event is ml.InProgress) {
          onProgress((event.progress / 100).clamp(0.0, 1.0));
          bytes = event.completedResourceSize;
        }
      },
    );
    // Ya está el mapa nuevo: se borran los de antes de esta ciudad (de una
    // descarga parada o de la versión anterior) para no ocupar el doble.
    // MapLibre guarda cada tesela una sola vez aunque la usen dos zonas, así
    // que borrar la vieja no quita lo que la nueva necesita.
    for (final ml.OfflineRegion old in await ml.getListOfRegions()) {
      if (old.id != fresh.id && old.metadata['iata'] == iata) {
        await ml.deleteOfflineRegion(old.id);
      }
    }
    return bytes;
  }

  @override
  Future<void> delete(String iata) async {
    for (final ml.OfflineRegion region in await ml.getListOfRegions()) {
      if (region.metadata['iata'] == iata) {
        await ml.deleteOfflineRegion(region.id);
      }
    }
  }
}

/// ¿Wifi, datos o nada? Lo dice el sistema (connectivity_plus).
class SystemNetProbe implements NetProbe {
  const SystemNetProbe();

  @override
  Future<NetKind> now() async {
    final List<ConnectivityResult> result = await Connectivity()
        .checkConnectivity();
    if (result.contains(ConnectivityResult.wifi) ||
        result.contains(ConnectivityResult.ethernet)) {
      return NetKind.wifi;
    }
    if (result.contains(ConnectivityResult.mobile)) return NetKind.mobile;
    return NetKind.none;
  }
}

/// La versión del mapa de OpenFreeMap: su ficha (TileJSON) apunta a las
/// teselas de la última versión publicada, con la fecha en la dirección
/// (".../planet/20261025_080012_pt/{z}/{x}/{y}.pbf"). Es un dato real y
/// gratis; si el servidor de mapas es otro y no lo dice, devuelve null.
class TileJsonMapVersion implements MapVersionProbe {
  TileJsonMapVersion(this.tilesUrl, {http.Client? client})
    : _client = client ?? http.Client();

  final Uri tilesUrl;
  final http.Client _client;

  static final RegExp _stamp = RegExp(r'/(\d{8}_\d{6})(?:_[a-z]+)?/');

  @override
  Future<String?> latest() async {
    try {
      final http.Response r = await _client
          .get(tilesUrl)
          .timeout(const Duration(seconds: 8));
      if (r.statusCode != 200 || r.body.length > 200000) return null;
      return versionFromTileJson(r.body);
    } on Object {
      return null;
    }
  }

  /// Saca la versión de la ficha del mapa (null si no la trae).
  static String? versionFromTileJson(String body) {
    try {
      final Object? json = jsonDecode(body);
      if (json is! Map<String, Object?>) return null;
      final Object? tiles = json['tiles'];
      if (tiles is! List<Object?> || tiles.isEmpty) return null;
      final Object? first = tiles.first;
      if (first is! String) return null;
      return _stamp.firstMatch(first)?.group(1);
    } on FormatException {
      return null;
    }
  }
}

/// ¿Está cargando? Lo dice el sistema (battery_plus).
class SystemPowerProbe implements PowerProbe {
  const SystemPowerProbe();

  @override
  Future<bool> charging() async {
    try {
      final BatteryState s = await Battery().batteryState;
      return s == BatteryState.charging ||
          s == BatteryState.full ||
          s == BatteryState.connectedNotCharging;
    } on Object {
      return false;
    }
  }
}
