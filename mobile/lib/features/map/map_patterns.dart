// Las "texturas" e iconos del mapa: adoquín, fachadas con ventanas (tres
// estilos), árboles para los parques, olas para el agua, flechas de sentido
// único e iconos de sitios (restaurantes, museos, metro...).
//
// No son fotos ni archivos: se pintan aquí mismo con código (unos pocos
// trazos), así no pesan nada en la app y cambian con la hora: de noche,
// parte de las ventanas se encienden.
//
// MapLibre las recibe como imágenes PNG con un nombre (MapIds...) y el
// estilo las usa con "fill-pattern", "fill-extrusion-pattern" e "icon-image".
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'map_style.dart';

/// Tamaño de cada textura en píxeles (MapLibre prefiere potencias de 2).
const int patternSize = 64;

/// Tamaño de los iconos de sitios (se dibujan a la mitad: nítidos en
/// pantallas de alta densidad).
const int iconSize = 48;

final Map<MapLook, Future<Map<String, Uint8List>>> _cache =
    <MapLook, Future<Map<String, Uint8List>>>{};

/// Las texturas e iconos de un aspecto (día, atardecer o noche), ya en PNG.
/// Se pintan una vez por aspecto y se reutilizan.
Future<Map<String, Uint8List>> mapPatterns(MapLook look) =>
    _cache[look] ??= _paintAll(look);

Future<Map<String, Uint8List>> _paintAll(MapLook look) async {
  final MapPalette p = MapPalette.of(look);
  final Map<String, Uint8List> out = <String, Uint8List>{
    MapIds.cobblePattern: await _png((Canvas c) => paintCobble(c, p)),
    MapIds.treesPattern: await _png((Canvas c) => paintTrees(c, p)),
    MapIds.wavesPattern: await _png((Canvas c) => paintWaves(c, p)),
    MapIds.arrowIcon: await _png((Canvas c) => paintArrow(c, p), size: 32),
  };
  for (final Facade f in Facade.values) {
    out[MapIds.facade(f)] = await _png((Canvas c) => paintFacade(c, look, f));
  }
  for (final PoiKind k in PoiKind.values) {
    out[MapIds.poiIcon(k)] = await _png(
      (Canvas c) => paintPoi(c, k),
      size: iconSize,
    );
  }
  return out;
}

Future<Uint8List> _png(
  void Function(Canvas canvas) draw, {
  int size = patternSize,
}) async {
  final ui.PictureRecorder rec = ui.PictureRecorder();
  draw(Canvas(rec));
  final ui.Image img = await rec.endRecording().toImage(size, size);
  final ByteData? data = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return data!.buffer.asUint8List();
}

const double _s = patternSize / 1.0;

/// Adoquines: filas de piedras redondeadas, cada fila desplazada media
/// piedra (como se colocan de verdad) y cada piedra de un tono algo distinto.
void paintCobble(Canvas c, MapPalette p) {
  c.drawRect(const Rect.fromLTWH(0, 0, _s, _s), Paint()..color = p.curb);
  final math.Random r = math.Random(7); // siempre igual: la textura no "baila"
  const int rows = 8, cols = 4;
  const double h = _s / rows, w = _s / cols;
  for (int row = 0; row < rows; row++) {
    final double shift = row.isOdd ? w / 2 : 0;
    // Una piedra de más por la izquierda, para que el desplazamiento case
    // al repetirse la textura.
    for (int col = -1; col < cols; col++) {
      c.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(col * w + shift + 0.8, row * h + 0.8, w - 1.6, h - 1.6),
          const Radius.circular(2),
        ),
        Paint()..color = _shade(p.cobble, (r.nextDouble() - 0.5) * 0.12),
      );
    }
  }
}

/// Un color un poco más claro (t > 0) o más oscuro (t < 0).
Color _shade(Color c, double t) => Color.lerp(
  c,
  t > 0 ? const Color(0xFFFFFFFF) : const Color(0xFF000000),
  t.abs(),
)!;

/// Los tres tipos de fachada: así una calle no parece hecha en serie.
enum Facade { brick, glass, stone }

/// Fachada: la pared y una rejilla de ventanas. De día reflejan el cielo; al
/// atardecer hay alguna encendida; de noche, muchas.
void paintFacade(Canvas c, MapLook look, Facade f) {
  final bool night = look == MapLook.night, dusk = look == MapLook.dusk;
  final Color wall = switch (f) {
    Facade.brick => const Color(0xFFB0674A),
    Facade.glass => const Color(0xFF5D7387),
    Facade.stone => const Color(0xFFD8CDB8),
  };
  // De noche las paredes casi no se ven: lo que destaca son las ventanas.
  c.drawRect(
    const Rect.fromLTWH(0, 0, _s, _s),
    Paint()
      ..color = night
          ? _shade(wall, -0.78)
          : (dusk ? _shade(wall, -0.35) : wall),
  );
  final math.Random r = math.Random(11 + f.index);
  final double lit = night ? 0.45 : (dusk ? 0.25 : 0.0);
  const Color warm = Color(0xFFFFD27A);
  final Color glass = night
      ? const Color(0xFF0E1420)
      : (dusk ? const Color(0xFF4E4A63) : const Color(0xFF8DA6B8));
  if (f == Facade.glass) {
    // Muro cortina: cristal de arriba abajo con los forjados marcados.
    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 4; x++) {
        final bool on = r.nextDouble() < lit;
        c.drawRect(
          Rect.fromLTWH(x * 16 + 1, y * 8 + 1, 14, 6),
          Paint()
            ..color = on ? warm : _shade(glass, (r.nextDouble() - 0.5) * 0.2),
        );
      }
    }
    return;
  }
  const int cells = 8;
  const double cell = _s / cells;
  for (int y = 0; y < cells; y++) {
    for (int x = 0; x < cells; x++) {
      final bool on = r.nextDouble() < lit;
      final Rect win = f == Facade.stone
          // Ventanas altas y estrechas, de edificio clásico.
          ? Rect.fromLTWH(x * cell + 2.5, y * cell + 1, cell - 5, cell - 2.5)
          : Rect.fromLTWH(x * cell + 2, y * cell + 1.5, cell - 4, cell - 3);
      c.drawRect(win, Paint()..color = on ? warm : glass);
    }
  }
}

/// Copas de árboles vistas desde arriba (fondo transparente: se pinta
/// encima del verde del parque).
void paintTrees(Canvas c, MapPalette p) {
  final math.Random r = math.Random(3);
  for (int i = 0; i < 9; i++) {
    final Offset at = Offset(r.nextDouble() * _s, r.nextDouble() * _s);
    final double rad = 4 + r.nextDouble() * 4;
    // Se pinta también desplazado ±64 px para que los árboles del borde
    // sigan al otro lado y la textura no tenga "cortes".
    for (final Offset d in const <Offset>[
      Offset.zero,
      Offset(_s, 0),
      Offset(-_s, 0),
      Offset(0, _s),
      Offset(0, -_s),
    ]) {
      final Offset o = at + d;
      c.drawCircle(
        o + const Offset(1.5, 1.5),
        rad,
        Paint()..color = const Color(0x40000000),
      );
      c.drawCircle(o, rad, Paint()..color = _shade(p.park, -0.18));
      c.drawCircle(
        o - Offset(rad * 0.3, rad * 0.3),
        rad * 0.5,
        Paint()..color = _shade(p.park, 0.12),
      );
    }
  }
}

/// Olas suaves: arcos claros sobre fondo transparente.
void paintWaves(Canvas c, MapPalette p) {
  final Paint wave = Paint()
    ..color = p.waterEdge.withValues(alpha: 0.55)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2
    ..strokeCap = StrokeCap.round;
  for (int row = 0; row < 4; row++) {
    for (int col = 0; col < 2; col++) {
      final double x = col * 32 + (row.isOdd ? 16 : 0) + 4;
      final double y = row * 16 + 8;
      c.drawArc(Rect.fromLTWH(x, y, 12, 6), math.pi, math.pi, false, wave);
    }
  }
}

/// Flecha de sentido único (apunta a la derecha: MapLibre la gira con la calle).
void paintArrow(Canvas c, MapPalette p) {
  final Paint paint = Paint()
    ..color = p.laneMark
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.5
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  c.drawLine(const Offset(6, 16), const Offset(26, 16), paint);
  c.drawPath(
    Path()
      ..moveTo(19, 9)
      ..lineTo(26, 16)
      ..lineTo(19, 23),
    paint,
  );
}

/// Tipos de sitio con icono propio.
enum PoiKind { food, cafe, bar, culture, shop, lodging, transport, health }

/// El color de cada tipo (los de la app: comida = naranja del Dinero,
/// cultura = violeta del Grupo, transporte = azul de Vuelos...).
Color poiColor(PoiKind k) => switch (k) {
  PoiKind.food => const Color(0xFFFFB86B),
  PoiKind.cafe => const Color(0xFFC9925E),
  PoiKind.bar => const Color(0xFFF78FB3),
  PoiKind.culture => const Color(0xFFB69CFF),
  PoiKind.shop => const Color(0xFFFF8A65),
  PoiKind.lodging => const Color(0xFF3DDC97),
  PoiKind.transport => const Color(0xFF6CA8FF),
  PoiKind.health => const Color(0xFFFF6B6B),
};

/// Un icono: círculo de color con borde blanco y un dibujo sencillo dentro.
void paintPoi(Canvas c, PoiKind k) {
  const double m = iconSize / 2;
  c.drawCircle(
    const Offset(m, m + 1.5),
    m - 2,
    Paint()..color = const Color(0x55000000),
  );
  c.drawCircle(
    const Offset(m, m),
    m - 2,
    Paint()..color = const Color(0xFFFFFFFF),
  );
  c.drawCircle(const Offset(m, m), m - 5, Paint()..color = poiColor(k));
  final Paint ink = Paint()
    ..color = const Color(0xFFFFFFFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2.6
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final Paint fill = Paint()..color = const Color(0xFFFFFFFF);
  switch (k) {
    case PoiKind.food: // tenedor y cuchillo
      c.drawLine(const Offset(18, 14), const Offset(18, 34), ink);
      c.drawLine(const Offset(15, 14), const Offset(15, 20), ink);
      c.drawLine(const Offset(21, 14), const Offset(21, 20), ink);
      c.drawLine(const Offset(30, 14), const Offset(30, 34), ink);
      c.drawLine(const Offset(30, 14), const Offset(33, 22), ink);
    case PoiKind.cafe: // taza
      c.drawRRect(
        RRect.fromLTRBR(14, 18, 30, 32, const Radius.circular(3)),
        fill,
      );
      c.drawArc(const Rect.fromLTWH(27, 20, 8, 8), -1.6, 3.2, false, ink);
    case PoiKind.bar: // copa
      c.drawPath(
        Path()
          ..moveTo(15, 15)
          ..lineTo(33, 15)
          ..lineTo(24, 25)
          ..close(),
        fill,
      );
      c.drawLine(const Offset(24, 25), const Offset(24, 33), ink);
      c.drawLine(const Offset(19, 33), const Offset(29, 33), ink);
    case PoiKind.culture: // templo clásico
      c.drawPath(
        Path()
          ..moveTo(13, 20)
          ..lineTo(24, 13)
          ..lineTo(35, 20)
          ..close(),
        fill,
      );
      for (final double x in <double>[17, 22, 26, 31]) {
        c.drawLine(Offset(x, 22), Offset(x, 31), ink..strokeWidth = 2);
      }
      c.drawLine(
        const Offset(14, 34),
        const Offset(34, 34),
        ink..strokeWidth = 2.6,
      );
    case PoiKind.shop: // bolsa
      c.drawRRect(
        RRect.fromLTRBR(15, 20, 33, 34, const Radius.circular(2)),
        fill,
      );
      c.drawArc(
        const Rect.fromLTWH(19, 13, 10, 12),
        math.pi,
        math.pi,
        false,
        ink,
      );
    case PoiKind.lodging: // cama
      c.drawLine(const Offset(13, 16), const Offset(13, 33), ink);
      c.drawLine(const Offset(13, 28), const Offset(35, 28), ink);
      c.drawLine(const Offset(35, 24), const Offset(35, 33), ink);
      c.drawRRect(
        RRect.fromLTRBR(19, 21, 35, 27, const Radius.circular(2)),
        fill,
      );
      c.drawCircle(const Offset(16.5, 23.5), 2.5, fill);
    case PoiKind.transport: // frente de un tren
      c.drawRRect(
        RRect.fromLTRBR(16, 12, 32, 31, const Radius.circular(4)),
        fill,
      );
      c.drawRect(
        const Rect.fromLTWH(19, 15, 10, 6),
        Paint()..color = poiColor(k),
      );
      c.drawLine(const Offset(18, 33), const Offset(15, 37), ink);
      c.drawLine(const Offset(30, 33), const Offset(33, 37), ink);
    case PoiKind.health: // cruz
      c.drawRect(const Rect.fromLTWH(21, 13, 6, 22), fill);
      c.drawRect(const Rect.fromLTWH(13, 21, 22, 6), fill);
  }
}
