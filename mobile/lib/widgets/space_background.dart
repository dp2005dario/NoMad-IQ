// El fondo espacial de la maqueta: cielo oscuro con tres nubes de color
// (menta, violeta y azul) y 70 estrellas que titilan un rato.
//
// Las estrellas siempre salen en el mismo sitio (semilla fija). El brillo
// dura unos 30 s y se para (no gasta batería); con "reducir movimiento"
// las estrellas se quedan quietas.
import 'dart:math' as math;

import 'package:flutter/material.dart';

class SpaceBackground extends StatefulWidget {
  const SpaceBackground({super.key, required this.child});

  final Widget child;

  @override
  State<SpaceBackground> createState() => _SpaceBackgroundState();
}

class _SpaceBackgroundState extends State<SpaceBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _twinkle = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 5),
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || MediaQuery.disableAnimationsOf(context)) return;
    _started = true;
    _twinkle.repeat(count: 6);
  }

  @override
  void dispose() {
    _twinkle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(painter: _SkyPainter(_twinkle)),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _SkyPainter extends CustomPainter {
  _SkyPainter(this.t) : super(repaint: t);

  final Animation<double> t;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect all = Offset.zero & size;
    // Las tres nubes de color, muy suaves.
    for (final (Alignment at, Color c) in <(Alignment, Color)>[
      (const Alignment(-0.8, -0.7), const Color(0x223DDC97)),
      (const Alignment(0.9, -0.2), const Color(0x229B7BFF)),
      (const Alignment(-0.6, 0.7), const Color(0x1858B4E6)),
    ]) {
      canvas.drawRect(
        all,
        Paint()
          ..shader = RadialGradient(
            center: at,
            radius: 0.8,
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
      // Titilar: cada estrella con su propio ritmo.
      final double tw = 0.5 + 0.5 * math.sin((t.value + phase) * 2 * math.pi);
      star.color = Colors.white.withValues(alpha: base * (0.45 + 0.55 * tw));
      canvas.drawCircle(Offset(x, y), big, star);
    }
  }

  @override
  bool shouldRepaint(_SkyPainter old) => false;
}
