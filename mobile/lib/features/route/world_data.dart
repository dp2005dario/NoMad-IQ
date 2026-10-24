// Los datos que la Ruta del vuelo lleva dentro de la app (sin Internet):
// los contornos de los países y los aeropuertos con su zona horaria. Ver
// assets/geo/LEEME.md (de dónde salen y su licencia).
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'geo.dart';

/// Un aeropuerto: código IATA, posición, ciudad, país y zona horaria IANA
/// ("Europe/Madrid").
class Airport {
  const Airport({
    required this.iata,
    required this.position,
    required this.city,
    required this.country,
    required this.timeZone,
  });

  final String iata;
  final LatLon position;
  final String city;
  final String country;
  final String timeZone;
}

/// Los aeropuertos por código IATA.
class Airports {
  Airports(this._byCode);

  final Map<String, Airport> _byCode;

  Airport? operator [](String iata) => _byCode[iata.toUpperCase()];

  int get length => _byCode.length;

  /// Todos (para buscar el más cercano a un punto).
  Iterable<Airport> get all => _byCode.values;

  /// Lee el formato de assets/geo/airports.txt: "MAD|40.472|-3.563|Madrid|Spain|Europe/Madrid".
  /// Una línea rara se salta (mejor un aeropuerto menos que no abrir).
  static Airports parse(String text) {
    final Map<String, Airport> out = <String, Airport>{};
    for (final String line in text.split('\n')) {
      final List<String> f = line.split('|');
      if (f.length != 6 || f[0].length != 3) continue;
      final double? lat = double.tryParse(f[1]);
      final double? lon = double.tryParse(f[2]);
      if (lat == null || lon == null) continue;
      out[f[0]] = Airport(
        iata: f[0],
        position: LatLon(lat, lon),
        city: f[3],
        country: f[4],
        timeZone: f[5],
      );
    }
    return Airports(out);
  }
}

/// Los contornos de los países: cada anillo es una lista plana
/// [lon0, lat0, lon1, lat1, …] en grados.
class WorldShapes {
  const WorldShapes(this.rings);

  final List<Float32List> rings;

  /// Lee el binario de assets/geo/world.bin (formato en LEEME.md).
  static WorldShapes parse(ByteData data) {
    if (data.lengthInBytes < 8 ||
        String.fromCharCodes(<int>[
              data.getUint8(0),
              data.getUint8(1),
              data.getUint8(2),
              data.getUint8(3),
            ]) !=
            'NQW1') {
      throw const FormatException('world.bin: firma desconocida');
    }
    int at = 4;
    final int count = data.getUint32(at, Endian.little);
    at += 4;
    final List<Float32List> rings = <Float32List>[];
    for (int r = 0; r < count; r++) {
      final int n = data.getUint32(at, Endian.little);
      at += 4;
      if (at + n * 4 > data.lengthInBytes) {
        throw const FormatException('world.bin: cortado');
      }
      final Float32List ring = Float32List(n * 2);
      for (int i = 0; i < n * 2; i++) {
        ring[i] = data.getInt16(at, Endian.little) / 10;
        at += 2;
      }
      rings.add(ring);
    }
    return WorldShapes(rings);
  }
}

/// Carga ambos una sola vez (se quedan en memoria: ~2 MB) y los comparte.
class WorldData {
  WorldData._(this.shapes, this.airports);

  final WorldShapes shapes;
  final Airports airports;

  static Future<WorldData>? _loading;

  static Future<WorldData> load([AssetBundle? bundle]) =>
      _loading ??= _load(bundle ?? rootBundle);

  static Future<WorldData> _load(AssetBundle bundle) async {
    try {
      final ByteData world = await bundle.load('assets/geo/world.bin');
      final String airports = await bundle.loadString(
        'assets/geo/airports.txt',
      );
      return WorldData._(WorldShapes.parse(world), Airports.parse(airports));
    } catch (_) {
      _loading = null; // que el siguiente intento vuelva a probar
      rethrow;
    }
  }
}
