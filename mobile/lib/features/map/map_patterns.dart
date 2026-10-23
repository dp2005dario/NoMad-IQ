// Las "texturas" del mapa: adoquín para plazas y calles peatonales, y
// fachadas con ventanas para los edificios en 3D.
//
// No son fotos: se pintan aquí mismo con código (unos pocos cuadraditos),
// así no pesan nada en la app y cambian con la hora: de noche, parte de las
// ventanas se encienden.
//
// MapLibre las recibe como imágenes PNG con un nombre (MapIds.cobble...) y
// el estilo las usa con "fill-pattern" y "fill-extrusion-pattern".
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'map_style.dart';

/// Tamaño de cada textura en píxeles (MapLibre prefiere potencias de 2).
const int patternSize = 64;

final Map<MapLook, Future<Map<String, Uint8List>>> _cache =
    <MapLook, Future<Map<String, Uint8List>>>{};

/// Las texturas de un aspecto (día, atardecer o noche), ya en PNG. Se
/// pintan una vez por aspecto y se reutilizan.
Future<Map<String, Uint8List>> mapPatterns(MapLook look) =>
    _cache[look] ??= _paintAll(look);

Future<Map<String, Uint8List>> _paintAll(MapLook look) async {
  final MapPalette p = MapPalette.of(look);
  return <String, Uint8List>{
    MapIds.cobblePattern: await _png((Canvas c) => paintCobble(c, p)),
    MapIds.facadePattern: await _png((Canvas c) => paintFacade(c, p, look)),
  };
}

Future<Uint8List> _png(void Function(Canvas canvas) draw) async {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  draw(Canvas(rec));
  final ui.Image img = await rec.endRecording().toImage(
    patternSize,
    patternSize,
  );
  final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

/// Adoquines: filas de piedras redondeadas, cada fila desplazada media
/// piedra (como se colocan de verdad) y cada piedra de un tono algo distinto.
void paintCobble(Canvas c, MapPalette p) {
  const double s = patternSize / 1.0;
  c.drawRect(const Rect.fromLTWH(0, 0, s, s), Paint()..color = p.curb);
  final math.Random r = math.Random(7); // siempre igual: la textura no "baila"
  const int rows = 8, cols = 4;
  const double h = s / rows, w = s / cols;
  for (int row = 0; row < rows; row++) {
    final double shift = row.isOdd ? w / 2 : 0;
    // Una piedra de más por la izquierda, para que el desplazamiento case
    // al repetirse la textura.
    for (int col = -1; col < cols; col++) {
      final double tone = (r.nextDouble() - 0.5) * 0.12;
      final Color stone = Color.lerp(
        p.cobble,
        tone > 0 ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
        tone.abs(),
      )!;
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(col * w + shift + 0.8, row * h + 0.8, w - 1.6, h - 1.6),
          const Radius.circular(2),
        ),
        Paint()..color = stone,
      );
    }
  }
}

/// Fachada: la pared y una rejilla de ventanas. De día reflejan el cielo; al
/// atardecer hay alguna encendida; de noche, muchas.
void paintFacade(Canvas c, MapPalette p, MapLook look) {
  const double s = patternSize / 1.0;
  c.drawRect(const Rect.fromLTWH(0, 0, s, s), Paint()..color = p.building);
  final math.Random r = math.Random(11);
  final double lit = switch (look) {
    MapLook.night => 0.45,
    MapLook.dusk => 0.25,
    _ => 0.0,
  };
  const Color warm = Color(0xFFFFD27A);
  final Color glass = switch (look) {
    MapLook.day => const Color(0xFF8DA6B8),
    MapLook.dusk => const Color(0xFF4E4A63),
    _ => const Color(0xFF0E1420),
  };
  const int cells = 8;
  const double cell = s / cells;
  for (int y = 0; y < cells; y++) {
    for (int x = 0; x < cells; x++) {
      final bool on = r.nextDouble() < lit;
      c.drawRect(
        Rect.fromLTWH(x * cell + 2, y * cell + 1.5, cell - 4, cell - 3),
        Paint()..color = on ? warm : glass,
      );
    }
  }
}
