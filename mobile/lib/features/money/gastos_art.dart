// Los dibujos de la pantalla de Gastos, copiados de la maqueta 8:
//   - El cielo de fondo (dos manchas de color, 40 estrellas que titilan y
//     una estrella fugaz cada 7 segundos).
//   - Los 3 cuadrados de "TU DINERO" (cartera, bote y globo), animados.
//   - El dibujo de cada plato del ticket.
//   - El "logo" del local: su inicial con un tenedor (no guardamos fotos de
//     logos, así que no nos inventamos uno).
//
// Las animaciones que no se acaban usan Motion.loop: en la app no paran,
// en las pruebas se repiten solo un par de veces, y con "reducir movimiento"
// se quedan quietas.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import 'money_screen.dart' show MoneyTab;

/// Colores de la maqueta de Gastos.
abstract final class GastosColors {
  static const Color card = Color(0xFF141E25);
  static const Color line = Color(0xFF26363F);
  static const Color muted = Color(0xFF9FB0B8);
  static const Color text = Color(0xFFF2F5F3);
  static const Color amber = Color(0xFFFFB86B);
}

/// Un controlador que da vueltas sin fin (si se puede animar).
mixin _Looping<T extends StatefulWidget>
    on State<T>, TickerProviderStateMixin<T> {
  Duration get period;
  late final AnimationController loop = AnimationController(
    vsync: this,
    duration: period,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || MediaQuery.disableAnimationsOf(context)) return;
    _started = true;
    Motion.loop(loop, testCount: 1);
  }

  @override
  void dispose() {
    loop.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// El cielo de fondo
// ---------------------------------------------------------------------------

/// Estrellas de la maqueta: x, y (sobre 390×844), ancho, alto, cuánto tarda
/// en titilar y cuánto espera al empezar (segundos).
const List<(double, double, double, double, double, double)> _stars =
    <(double, double, double, double, double, double)>[
      (121, 606, 2.5, 1.5, 2.9, 1.8),
      (320, 594, 1.5, 2.5, 2.0, 2.5),
      (132, 564, 1.5, 1.5, 4.5, 1.4),
      (281, 487, 2, 2.5, 4.2, 0.7),
      (77, 535, 2, 2.5, 2.0, 2.3),
      (81, 776, 2.5, 1.5, 2.8, 0.1),
      (137, 484, 2.5, 2.5, 4.3, 1.2),
      (218, 404, 2.5, 2.5, 3.1, 2.8),
      (187, 99, 1.5, 1.5, 3.2, 0.8),
      (344, 446, 2.5, 2, 3.1, 2.5),
      (293, 359, 2.5, 2.5, 3.0, 0.7),
      (172, 698, 1.5, 2, 4.5, 2.0),
      (83, 715, 2, 2.5, 4.3, 1.7),
      (365, 671, 1.5, 2.5, 4.1, 1.7),
      (145, 127, 1.5, 2, 4.1, 3.0),
      (45, 352, 1.5, 2, 4.2, 0.1),
      (218, 787, 2, 1.5, 2.1, 1.8),
      (23, 386, 2.5, 2.5, 2.8, 2.6),
      (142, 517, 1.5, 1.5, 2.8, 0.2),
      (307, 548, 1.5, 1.5, 4.4, 0.9),
      (134, 159, 2.5, 1.5, 4.4, 1.0),
      (184, 141, 2, 2, 3.2, 1.6),
      (329, 609, 2.5, 2.5, 2.3, 2.9),
      (259, 277, 2, 2.5, 3.8, 0.7),
      (154, 447, 2, 2.5, 2.8, 1.0),
      (212, 593, 2, 1.5, 2.9, 1.8),
      (68, 61, 2.5, 2.5, 2.8, 1.1),
      (180, 623, 2.5, 2, 3.8, 0.1),
      (31, 692, 1.5, 2, 2.6, 1.4),
      (303, 615, 2, 1.5, 2.9, 0.9),
      (189, 609, 2, 2, 4.0, 0.3),
      (13, 582, 2.5, 2.5, 2.3, 1.5),
      (334, 823, 2, 1.5, 2.8, 2.0),
      (332, 714, 1.5, 1.5, 3.5, 2.8),
      (345, 229, 2, 1.5, 2.2, 2.2),
      (111, 582, 2, 2, 2.6, 0.4),
      (271, 195, 2, 2.5, 2.5, 0.8),
      (328, 87, 2.5, 2, 3.5, 1.3),
      (265, 812, 2, 2, 2.9, 1.3),
      (214, 581, 2, 1.5, 4.3, 0.5),
    ];

/// El fondo de Gastos: queda quieto detrás mientras el contenido se mueve.
class GastosSky extends StatefulWidget {
  const GastosSky({super.key, required this.child});

  final Widget child;

  @override
  State<GastosSky> createState() => _GastosSkyState();
}

class _GastosSkyState extends State<GastosSky>
    with TickerProviderStateMixin, _Looping<GastosSky> {
  // 7 s: lo que tarda en volver la estrella fugaz.
  @override
  Duration get period => const Duration(seconds: 70);

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: NomadColors.background,
    child: Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(painter: _SkyPainter(loop)),
          ),
        ),
        widget.child,
      ],
    ),
  );
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.time) : super(repaint: time);

  final Animation<double> time;

  /// Una mancha de color en forma de óvalo que se difumina.
  void _glow(Canvas c, Offset center, Size radius, Color color) {
    c.save();
    c.translate(center.dx, center.dy);
    c.scale(radius.width, radius.height);
    c.drawCircle(
      Offset.zero,
      1,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[color, color.withValues(alpha: 0)],
          stops: const <double>[0, 0.7],
        ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1)),
    );
    c.restore();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width, h = size.height;
    _glow(
      canvas,
      Offset(w * 0.9, 0),
      Size(w * 0.7, h * 0.3),
      const Color(0x388B7CF6),
    );
    _glow(
      canvas,
      Offset(0, h * 0.45),
      Size(w * 0.6, h * 0.3),
      const Color(0x1A3DDC97),
    );
    final double seconds = time.value * 70;
    final double sx = w / 390, sy = h / 844;
    final Paint star = Paint();
    for (final (double x, double y, double sw, double sh, double dur, double d)
        in _stars) {
      // Titila entre 0,15 y 0,9 de opacidad.
      final double phase = ((seconds - d) / dur) * 2 * math.pi;
      final double o = 0.15 + 0.75 * (0.5 - 0.5 * math.cos(phase));
      star.color = const Color(0xFFDCF5EC).withValues(alpha: o);
      canvas.drawOval(Rect.fromLTWH(x * sx, y * sy, sw, sh), star);
    }
    // La estrella fugaz: sale arriba a la derecha y cruza en 1,4 s.
    final double s = (seconds - 2) % 7;
    final double k = (s / 7) / 0.2; // del 0 % al 20 % de la vuelta
    if (seconds >= 2 && k <= 1) {
      final double eased = k * k; // ease-in
      final double o = k < 0.3 ? k / 0.3 : 1 - (k - 0.3) / 0.7;
      canvas.save();
      canvas.translate(360 * sx - 320 * eased, 40 + 170 * eased);
      canvas.rotate(-28 * math.pi / 180);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(0, 0, 90, 2),
          const Radius.circular(1),
        ),
        Paint()
          ..shader = LinearGradient(
            colors: <Color>[
              Colors.white.withValues(alpha: o.clamp(0, 1)),
              Colors.white.withValues(alpha: 0),
            ],
          ).createShader(const Rect.fromLTWH(0, 0, 90, 2)),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_SkyPainter old) => false;
}

// ---------------------------------------------------------------------------
// TU DINERO: cartera, bote y globo
// ---------------------------------------------------------------------------

/// Los 3 cuadrados de "TU DINERO". Cada uno abre su pestaña de Dinero.
class MoneyTiles extends StatelessWidget {
  const MoneyTiles({
    super.key,
    required this.title,
    required this.abroad,
    required this.kitty,
    required this.fx,
    required this.onOpen,
  });

  final String title;
  final String abroad;
  final String kitty;
  final String fx;
  final void Function(MoneyTab tab) onOpen;

  @override
  Widget build(BuildContext context) {
    Widget tile(MoneyTab tab, String label, _TileArt art) => Expanded(
      child: Material(
        color: GastosColors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: GastosColors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onOpen(tab),
          child: SizedBox(
            height: 80,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                OnScreenOnly(child: _AnimatedTileArt(art: art)),
                const SizedBox(height: 6),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    height: 1.1,
                    color: GastosColors.text,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: gastosLabel),
        const SizedBox(height: 8),
        Row(
          children: <Widget>[
            tile(MoneyTab.abroad, abroad, _TileArt.wallet),
            const SizedBox(width: 8),
            tile(MoneyTab.kitty, kitty, _TileArt.jar),
            const SizedBox(width: 8),
            tile(MoneyTab.fx, fx, _TileArt.globe),
          ],
        ),
      ],
    );
  }
}

/// Las letras pequeñas en mayúsculas de los títulos ("TU DINERO").
const TextStyle gastosLabel = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w800,
  letterSpacing: 0.66,
  color: GastosColors.muted,
);

enum _TileArt { wallet, jar, globe }

class _AnimatedTileArt extends StatefulWidget {
  const _AnimatedTileArt({required this.art});

  final _TileArt art;

  @override
  State<_AnimatedTileArt> createState() => _AnimatedTileArtState();
}

class _AnimatedTileArtState extends State<_AnimatedTileArt>
    with TickerProviderStateMixin, _Looping<_AnimatedTileArt> {
  // Una vuelta de 31,2 s: cabe un número entero de veces cada animación
  // (2,4 s, 1,6 s, 1,8 s... con un poco de margen no se nota el salto).
  @override
  Duration get period => const Duration(milliseconds: 31200);

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 44,
    height: 40,
    child: CustomPaint(painter: _TilePainter(widget.art, loop)),
  );
}

/// Un trozo de la vuelta (0..1) de una animación que dura [seconds].
double _cycle(double loopValue, double seconds) {
  final double t = loopValue * 31.2 / seconds;
  return t - t.floorToDouble();
}

/// Curva "ease" de CSS (aproximada).
double _ease(double t) => Curves.ease.transform(t.clamp(0, 1));

class _TilePainter extends CustomPainter {
  _TilePainter(this.art, this.time) : super(repaint: time);

  final _TileArt art;
  final Animation<double> time;

  static const Color _coinEdge = Color(0xFFB07A12);

  Paint _coinFill(Rect r) => Paint()
    ..shader = const RadialGradient(
      center: Alignment(-0.3, -0.4),
      radius: 0.7,
      colors: <Color>[Color(0xFFFFF6C8), Color(0xFFE0A21E)],
    ).createShader(r);

  void _coinEllipse(Canvas c, Offset center, double rx, double ry) {
    final Rect r = Rect.fromCenter(
      center: center,
      width: rx * 2,
      height: ry * 2,
    );
    c.drawOval(r, _coinFill(r));
    c.drawOval(
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = _coinEdge,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    switch (art) {
      case _TileArt.wallet:
        _wallet(canvas);
      case _TileArt.jar:
        _jar(canvas);
      case _TileArt.globe:
        _globe(canvas);
    }
  }

  void _wallet(Canvas c) {
    // La tarjeta sube y baja dentro de la cartera (2,4 s).
    final double k = _cycle(time.value, 2.4);
    final double up = k < 0.4
        ? _ease(k / 0.4)
        : k <= 0.6
        ? 1
        : 1 - _ease((k - 0.6) / 0.4);
    final double cardY = 6 - 8 * up;
    c.save();
    c.translate(0, cardY);
    c.drawRRect(
      RRect.fromLTRBR(10, 6, 34, 22, const Radius.circular(3)),
      Paint()..color = const Color(0xFF6CA8FF),
    );
    c.drawRect(
      const Rect.fromLTWH(10, 10, 24, 3),
      Paint()..color = const Color(0xFF2B4E8F),
    );
    c.drawRRect(
      RRect.fromLTRBR(13, 16, 19, 20, const Radius.circular(1)),
      Paint()..color = const Color(0xFFFFE08A),
    );
    c.restore();
    const Rect body = Rect.fromLTWH(5, 15, 34, 22);
    c.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(5)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFFC77B3B), Color(0xFF7A3F14)],
        ).createShader(body),
    );
    c.drawRRect(
      RRect.fromLTRBR(5, 15, 39, 20, const Radius.circular(3)),
      Paint()..color = const Color(0x99E39A57),
    );
    c.drawRRect(
      RRect.fromLTRBR(27, 22, 40, 31, const Radius.circular(3)),
      Paint()..color = const Color(0xFF5C2E0E),
    );
    c.drawCircle(
      const Offset(32, 26.5),
      2,
      Paint()..color = const Color(0xFFFFD54F),
    );
    // La moneda salta y gira (1,6 s).
    final double m = _cycle(time.value, 1.6);
    double dy, sx;
    if (m < 0.25) {
      final double e = _ease(m / 0.25);
      dy = -5 * e;
      sx = 1 - 0.8 * e;
    } else if (m < 0.5) {
      final double e = _ease((m - 0.25) / 0.25);
      dy = -5 + 5 * e;
      sx = 0.2 + 0.8 * e;
    } else if (m < 0.6) {
      dy = -1.5 * _ease((m - 0.5) / 0.1);
      sx = 1;
    } else {
      dy = -1.5 + 1.5 * _ease((m - 0.6) / 0.4);
      sx = 1;
    }
    c.save();
    c.translate(9, 10 + dy);
    c.scale(sx, 1);
    const Rect coin = Rect.fromLTWH(-5, -5, 10, 10);
    c.drawCircle(Offset.zero, 5, _coinFill(coin));
    c.drawCircle(
      Offset.zero,
      5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8
        ..color = _coinEdge,
    );
    c.drawCircle(
      Offset.zero,
      2.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = const Color(0xFFFFF3B0),
    );
    c.restore();
  }

  void _jar(Canvas c) {
    // Cae una moneda en el bote y aparece arriba del montón (1,8 s).
    final double k = _cycle(time.value, 1.8);
    final double fall = k < 0.6 ? Curves.easeIn.transform(k / 0.6) : 1;
    final double dropOpacity = k < 0.15
        ? k / 0.15
        : k < 0.6
        ? 1
        : k < 0.7
        ? 1 - (k - 0.6) / 0.1
        : 0;
    if (dropOpacity > 0) {
      c.saveLayer(
        null,
        Paint()..color = Colors.white.withValues(alpha: dropOpacity),
      );
      _coinEllipse(c, Offset(22, 4 - 4 + 20 * fall), 5, 2);
      c.restore();
    }
    _coinEllipse(c, const Offset(22, 34), 9, 2.6);
    _coinEllipse(c, const Offset(23, 31), 9, 2.6);
    _coinEllipse(c, const Offset(22, 28), 9, 2.6);
    _coinEllipse(c, const Offset(23, 25), 9, 2.6);
    final double top = k < 0.62
        ? 0
        : k < 0.7
        ? Curves.easeOut.transform(((k - 0.62) / 0.08).clamp(0.0, 1.0))
        : 1;
    if (top > 0) {
      c.saveLayer(null, Paint()..color = Colors.white.withValues(alpha: top));
      _coinEllipse(c, Offset(22, 22 - 2 * (1 - top)), 9, 2.6);
      c.restore();
    }
    // El cristal del bote.
    final Path glass = Path()
      ..moveTo(11, 12)
      ..lineTo(33, 12)
      ..lineTo(33, 15)
      ..cubicTo(36, 17, 36, 19, 36, 22)
      ..lineTo(36, 32)
      ..cubicTo(36, 36, 33, 37, 30, 37)
      ..lineTo(14, 37)
      ..cubicTo(11, 37, 8, 36, 8, 32)
      ..lineTo(8, 22)
      ..cubicTo(8, 19, 8, 17, 11, 15)
      ..close();
    c.drawPath(
      glass,
      Paint()
        ..shader = const LinearGradient(
          colors: <Color>[
            Color(0x73BFE9FF),
            Color(0x26FFFFFF),
            Color(0x59BFE9FF),
          ],
          stops: <double>[0, 0.3, 1],
        ).createShader(const Rect.fromLTWH(8, 12, 28, 25)),
    );
    c.drawPath(
      glass,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = const Color(0xFFCFEFFF),
    );
    c.drawRRect(
      RRect.fromLTRBR(10, 9, 34, 13, const Radius.circular(2)),
      Paint()..color = const Color(0xFFFF8A65),
    );
    c.drawLine(
      const Offset(14, 18),
      const Offset(14, 30),
      Paint()
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round
        ..color = const Color(0x99FFFFFF),
    );
  }

  void _globe(Canvas c) {
    const Offset center = Offset(22, 20);
    final Rect ball = Rect.fromCircle(center: center, radius: 13);
    c.drawCircle(
      center,
      13,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          radius: 0.75,
          colors: <Color>[Color(0xFF7FF0C0), Color(0xFF138A5A)],
        ).createShader(ball),
    );
    // Los meridianos giran (3 s).
    final double shift = -13 * _cycle(time.value, 3);
    c.save();
    c.clipPath(Path()..addOval(ball));
    final Paint mer = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0x8C0B4D33);
    for (final double x in <double>[0, 13, 26, 39, 52]) {
      c.drawOval(
        Rect.fromCenter(center: Offset(x + shift, 20), width: 8, height: 26),
        mer,
      );
    }
    final Paint lat = Paint()
      ..strokeWidth = 1
      ..color = const Color(0x800B4D33);
    c.drawLine(const Offset(9, 15), const Offset(35, 15), lat);
    c.drawLine(const Offset(9, 25), const Offset(35, 25), lat);
    c.restore();
    // La órbita, de rayas.
    final Path orbit = Path()
      ..addOval(Rect.fromCenter(center: center, width: 38, height: 12));
    final Paint dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = const Color(0xB3FFE08A);
    for (final ui in orbit.computeMetrics()) {
      for (double d = 0; d < ui.length; d += 4) {
        c.drawPath(ui.extractPath(d, d + 2), dash);
      }
    }
    // La moneda que da vueltas (2,6 s).
    final double a = _cycle(time.value, 2.6) * 2 * math.pi;
    final Offset p = Offset(22 + 19 * math.cos(a), 20 + 6 * math.sin(a));
    final Rect coin = Rect.fromCircle(center: p, radius: 3.6);
    c.drawCircle(p, 3.6, _coinFill(coin));
    c.drawCircle(
      p,
      3.6,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.6
        ..color = _coinEdge,
    );
  }

  @override
  bool shouldRepaint(_TilePainter old) => old.art != art;
}

// ---------------------------------------------------------------------------
// Los platos
// ---------------------------------------------------------------------------

/// Un dibujo de plato de la maqueta: el SVG y su color.
class _Dish {
  const _Dish(this.color, this.svg);
  final Color color;
  final String svg;
}

String _bg(String a, String b) =>
    '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">'
    '<stop offset="0" stop-color="$a"/><stop offset="1" stop-color="$b"/>'
    '</linearGradient></defs><rect width="100" height="100" fill="url(#g)"/>';

String _svg(String body) =>
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">$body</svg>';

final _Dish _croquetas = _Dish(
  const Color(0xFFE9A15A),
  _svg(
    '${_bg('#E9A15A', '#3A1E10')}'
    '<ellipse cx="50" cy="66" rx="40" ry="14" fill="#fff"/>'
    '<ellipse cx="34" cy="60" rx="13" ry="8" fill="#C77A2E" transform="rotate(-15 34 60)"/>'
    '<ellipse cx="31" cy="57" rx="6" ry="2.5" fill="#E9A85A"/>'
    '<ellipse cx="60" cy="58" rx="13" ry="8" fill="#C77A2E" transform="rotate(10 60 58)"/>'
    '<ellipse cx="57" cy="55" rx="6" ry="2.5" fill="#E9A85A"/>'
    '<ellipse cx="48" cy="68" rx="13" ry="8" fill="#C77A2E" transform="rotate(0 48 68)"/>'
    '<ellipse cx="45" cy="65" rx="6" ry="2.5" fill="#E9A85A"/>',
  ),
);

final _Dish _tortilla = _Dish(
  const Color(0xFFF2C46B),
  _svg(
    '${_bg('#F2C46B', '#3A2A10')}'
    '<ellipse cx="50" cy="60" rx="42" ry="22" fill="#fff"/>'
    '<path d="M50 58 L14 52 A38 18 0 0 0 86 60 Z" fill="#F2C46B"/>'
    '<path d="M50 58 L14 52 A38 18 0 0 1 50 40 Z" fill="#FFD98A"/>'
    '<circle cx="30" cy="58" r="2" fill="#E9A23A"/>'
    '<circle cx="62" cy="64" r="2" fill="#E9A23A"/>',
  ),
);

final _Dish _meat = _Dish(
  const Color(0xFFC9634A),
  _svg(
    '${_bg('#C9634A', '#1A1210')}'
    '<rect x="8" y="40" width="84" height="40" rx="6" fill="#2A2A2A"/>'
    '${<int>[16, 26, 36, 46, 56, 66, 76, 86].map((int x) => '<path d="M$x 40 V80" stroke="#444" stroke-width="2"/>').join()}'
    '<path d="M20 50 Q40 40 64 46 Q84 50 80 64 Q60 76 30 70 Q14 64 20 50 Z" fill="#B5523A"/>'
    '<path d="M28 48 L40 70" stroke="#5A1E12" stroke-width="2.4"/>'
    '<path d="M42 48 L54 70" stroke="#5A1E12" stroke-width="2.4"/>'
    '<path d="M56 48 L68 70" stroke="#5A1E12" stroke-width="2.4"/>',
  ),
);

final _Dish _wine = _Dish(
  const Color(0xFF8E2A3C),
  _svg(
    '${_bg('#B23A4C', '#2A0A12')}'
    '<path d="M34 16 H66 Q68 44 50 50 Q32 44 34 16 Z" fill="#FFFFFF33" stroke="#fff" stroke-width="1.5"/>'
    '<path d="M35 28 H65 Q64 44 50 48 Q36 44 35 28 Z" fill="#8E1A2C"/>'
    '<path d="M50 50 V80 M38 82 H62" stroke="#fff" stroke-width="2.4" stroke-linecap="round"/>',
  ),
);

final _Dish _octopus = _Dish(
  const Color(0xFFD9774E),
  _svg(
    '${_bg('#D9774E', '#3A1A10')}'
    '<ellipse cx="50" cy="62" rx="42" ry="22" fill="#E8D2B0"/>'
    '${<(int, int)>[(30, 56), (48, 52), (66, 58), (40, 68), (58, 70)].map(((int, int) p) => '<circle cx="${p.$1}" cy="${p.$2}" r="7" fill="#B23A4C"/><circle cx="${p.$1}" cy="${p.$2}" r="3" fill="#F2D2C2"/><circle cx="${p.$1 + 1}" cy="${p.$2}" r="1.2" fill="#D9442F"/>').join()}',
  ),
);

final _Dish _beer = _Dish(
  const Color(0xFFF2B33D),
  _svg(
    '${_bg('#F2B33D', '#3A2A08')}'
    '<path d="M34 24 H66 L62 84 H38 Z" fill="#F2B33D"/>'
    '<path d="M33 18 Q50 10 67 18 V28 H33 Z" fill="#FFFDF6"/>'
    '<circle cx="44" cy="70" r="1.4" fill="#fff" opacity=".7"/>'
    '<circle cx="52" cy="56" r="1.4" fill="#fff" opacity=".7"/>'
    '<circle cx="48" cy="44" r="1.4" fill="#fff" opacity=".7"/>'
    '<circle cx="56" cy="64" r="1.4" fill="#fff" opacity=".7"/>',
  ),
);

/// Si el nombre no se parece a ningún plato conocido: un plato con
/// cubiertos (el mismo dibujo que el logo de la maqueta).
final _Dish _plate = _Dish(
  const Color(0xFF9CC4FF),
  _svg(
    '${_bg('#9CC4FF', '#101A2A')}'
    '<ellipse cx="50" cy="58" rx="36" ry="24" fill="#fff"/>'
    '<ellipse cx="50" cy="58" rx="22" ry="14" fill="none" stroke="#1E2124" stroke-width="2"/>'
    '<path d="M14 30v10a3 3 0 0 0 6 0V30M17 40v28" stroke="#fff" stroke-width="2.4" fill="none" stroke-linecap="round"/>'
    '<path d="M86 30c-4 3-4 12 0 15v23" stroke="#fff" stroke-width="2.4" fill="none" stroke-linecap="round"/>',
  ),
);

/// Elige el dibujo por el nombre de la línea del ticket.
_Dish _dishFor(String name) {
  final String n = name.toLowerCase();
  bool has(List<String> words) => words.any(n.contains);
  if (has(<String>['croquet', 'croquet', 'nugget', 'frit'])) return _croquetas;
  if (has(<String>['tortilla', 'omelet', 'huevo', 'egg', 'pizza'])) {
    return _tortilla;
  }
  if (has(<String>['vino', 'wine', 'copa', 'sangr', 'cava', 'vin '])) {
    return _wine;
  }
  if (has(<String>[
    'caña',
    'cana',
    'cerve',
    'beer',
    'bier',
    'birra',
    'jarra',
  ])) {
    return _beer;
  }
  if (has(<String>['pulpo', 'octop', 'calamar', 'gamba', 'marisco', 'pesca'])) {
    return _octopus;
  }
  if (has(<String>[
    'secreto',
    'ibéric',
    'iberic',
    'carne',
    'chulet',
    'filete',
    'entrec',
    'solomillo',
    'pollo',
    'burger',
    'hambur',
    'steak',
    'meat',
  ])) {
    return _meat;
  }
  return _plate;
}

/// El cuadrado de 46 px con el dibujo del plato, con brillo y sombra.
class DishThumb extends StatelessWidget {
  const DishThumb({super.key, required this.name, this.size = 46});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final _Dish d = _dishFor(name);
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: d.color,
            blurRadius: 14,
            spreadRadius: -6,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        gradient: const RadialGradient(
          center: Alignment(-0.3, -0.4),
          radius: 0.55,
          colors: <Color>[Color(0x55FFFFFF), Color(0x00FFFFFF)],
        ),
      ),
      child: SvgPicture.string(d.svg, fit: BoxFit.cover),
    );
  }
}

// ---------------------------------------------------------------------------
// El logo del local
// ---------------------------------------------------------------------------

/// La inicial del local en un círculo violeta, con un tenedor naranja.
class PlaceInitial extends StatelessWidget {
  const PlaceInitial({
    super.key,
    required this.name,
    this.size = 40,
    this.badge = false,
  });

  final String name;
  final double size;

  /// El circulito naranja con el tenedor (en el ticket).
  final bool badge;

  @override
  Widget build(BuildContext context) {
    final String letter = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF6C5CE7),
            ),
            child: Text(
              letter,
              style: TextStyle(
                fontFamily: NomadFonts.body,
                color: Colors.white,
                fontWeight: FontWeight.w800,
                fontSize: size * 0.45,
              ),
            ),
          ),
          if (badge)
            Positioned(
              right: -4,
              bottom: -4,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: GastosColors.amber,
                  border: Border.all(color: const Color(0xFFFFFDF8), width: 2),
                ),
                alignment: Alignment.center,
                child: SvgPicture.string(
                  '<svg width="12" height="12" viewBox="0 0 24 24" fill="none" '
                  'stroke="#0B1217" stroke-width="2.6" stroke-linecap="round">'
                  '<path d="M7 3v8a2 2 0 0 0 4 0V3M9 11v10M17 3c-3 2-3 8 0 '
                  '10v8"/></svg>',
                  width: 12,
                  height: 12,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
