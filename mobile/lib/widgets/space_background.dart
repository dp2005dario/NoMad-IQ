// El fondo espacial de la maqueta: cielo oscuro con tres nubes de color
// (menta, violeta y azul) que se mueven muy despacio, 70 estrellas que
// titilan y, cada 19 segundos, una estrella fugaz.
//
// Las estrellas siempre salen en el mismo sitio (semilla fija). Todo se
// mueve sin fin, como en la maqueta, pero se para solo cuando otra pantalla
// lo tapa o la app está en segundo plano. Con "reducir movimiento" todo se
// queda quieto y no hay estrella fugaz.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/motion.dart';

class SpaceBackground extends StatefulWidget {
  const SpaceBackground({super.key, required this.child});

  final Widget child;

  @override
  State<SpaceBackground> createState() => _SpaceBackgroundState();
}

class _SpaceBackgroundState extends State<SpaceBackground>
    with TickerProviderStateMixin {
  // Una vuelta = 19 s: en ella las estrellas titilan 4 veces y pasa una
  // estrella fugaz.
  late final AnimationController _sky = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 19),
  );
  // Las nubes van y vienen en 75 s.
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 75),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || MediaQuery.disableAnimationsOf(context)) return;
    _started = true;
    Motion.loop(_sky);
    Motion.loop(_drift, reverse: true, testCount: 1);
  }

  @override
  void dispose() {
    _sky.dispose();
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _SkyPainter(_sky, _drift, shooting: _started),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.t, this.drift, {required this.shooting})
    : super(repaint: Listenable.merge(<Listenable>[t, drift]));

  final Animation<double> t;
  final Animation<double> drift;

  /// Sin animaciones (reducir movimiento), no hay estrella fugaz.
  final bool shooting;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect all = Offset.zero & size;
    // Las tres nubes de color, muy suaves; cada una va hacia un lado.
    final double d = Curves.easeInOut.transform(drift.value);
    for (final (Alignment at, Offset to, Color c)
        in <(Alignment, Offset, Color)>[
          (
            const Alignment(-0.8, -0.7),
            const Offset(0.35, 0.25),
            const Color(0x223DDC97),
          ),
          (
            const Alignment(0.9, -0.2),
            const Offset(-0.3, -0.2),
            const Color(0x229B7BFF),
          ),
          (
            const Alignment(-0.6, 0.7),
            const Offset(0.3, -0.3),
            const Color(0x1858B4E6),
          ),
        ]) {
      canvas.drawRect(
        all,
        Paint()
          ..shader = RadialGradient(
            center: Alignment(at.x + to.dx * d, at.y + to.dy * d),
            radius: 0.8 + 0.1 * d,
            colors: <Color>[c, c.withValues(alpha: 0)],
          ).createShader(all),
      );
    }
    final math.Random r = math.Random(11);
    final Paint star = Paint()..color = Colors.white;
    for (int i = 0; i < 70; i++) {
      final double x = r.nextDouble() * size.width;
      final double y = r.nextDouble() * size.height;
      final double big = r.nextDouble() < 0.8 ? 0.65 : 1.1;
      final double base = 0.4 + r.nextDouble() * 0.5;
      final double phase = r.nextDouble();
      // Titilar: cada estrella con su propio ritmo (4 veces por vuelta).
      final double tw =
          0.5 + 0.5 * math.sin((t.value * 4 + phase) * 2 * math.pi);
      star.color = Colors.white.withValues(alpha: base * (0.45 + 0.55 * tw));
      canvas.drawCircle(Offset(x, y), big, star);
    }
    if (shooting) _shootingStar(canvas, size);
  }

  /// La estrella fugaz (como la de la maqueta): sale a los 6 s de la vuelta,
  /// cruza en 1,5 s de arriba a la derecha hacia abajo a la izquierda y se
  /// apaga.
  void _shootingStar(Canvas canvas, Size size) {
    const double start = 6 / 19;
    const double length = 1.5 / 19;
    final double p = (t.value - start) / length;
    if (p <= 0 || p >= 1) return;
    // Aparece deprisa y se va apagando.
    final double alpha = p < 0.25 ? p / 0.25 * 0.9 : 0.9 * (1 - p) / 0.75;
    final Offset from = Offset(size.width * 0.70, size.height * 0.08);
    final Offset to = Offset(size.width * 0.25, size.height * 0.36);
    final Offset head = Offset.lerp(from, to, p)!;
    // La cola: 110 px hacia atrás, en la dirección de donde viene.
    final Offset dir = from - to;
    final Offset tail = head + dir / dir.distance * 110;
    canvas.drawLine(
      head,
      tail,
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: <Color>[
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromPoints(head, tail)),
    );
  }

  @override
  bool shouldRepaint(_SkyPainter old) => old.shooting != shooting;
}
