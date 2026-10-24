// Las piezas de verdad de "Sin conexión": archivos en la carpeta privada de
// la app, el mapa descargado con MapLibre y saber si hay wifi.
//
// En los tests NO se usa nada de esto (se enchufan versiones de mentira):
// aquí vive justo lo que necesita el móvil real.
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
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
    await file.writeAsBytes(bytes, flush: true);
    return bytes.length;
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
    await ml.downloadOfflineRegion(
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
