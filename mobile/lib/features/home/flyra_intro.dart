// La entrada de Flyra en Inicio (maqueta "ECLIPTA Inicio"), dibujada encima
// de la bola:
//   0,3-1,7 s  muchas chispas de colores vuelan desde fuera y forman un
//              pájaro (la silueta de Flyra);
//   1,5-2,1 s  un destello blanco;
//   1,7-3,1 s  el pájaro vuela una curva alrededor de la bola dejando una
//              estela de colores y "aterriza" en el centro;
//   3,1-4,6 s  tres ondas salen de la bola.
// Además, durante un rato, polvo de estrellas que sale de la bola.
//
// Todo dura poco y se para solo (no gasta batería). Con "reducir
// movimiento" del móvil no se dibuja nada.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Lo que dura la entrada entera.
const Duration flyraIntroLength = Duration(milliseconds: 4600);

/// Cuándo empieza a escribirse el saludo (cuando el pájaro ha llegado).
const Duration flyraIntroGreetAt = Duration(milliseconds: 3000);

/// Cuánto rato sale polvo de estrellas.
const Duration flyraDustLength = Duration(seconds: 20);

const List<Color> _colors = <Color>[
  Color(0xFF3DDC97),
  Color(0xFF9B7BFF),
  Color(0xFF58B4E6),
  Color(0xFFFF82BE),
];

/// La silueta del pájaro en una caja de 64 × 44 (las mismas curvas que la
/// maqueta): ala izquierda, ala derecha, cuerpo y cola.
Path _leftWing() => Path()
  ..moveTo(32, 22)
  ..cubicTo(24, 10, 10, 6, 0, 8)
  ..cubicTo(8, 12, 14, 18, 20, 26)
  ..close();

Path _rightWing() => Path()
  ..moveTo(32, 22)
  ..cubicTo(40, 10, 54, 6, 64, 8)
  ..cubicTo(56, 12, 50, 18, 44, 26)
  ..close();

Path _body() => Path()
  ..moveTo(32, 14)
  ..cubicTo(36, 14, 38, 18, 38, 23)
  ..cubicTo(38, 29, 35, 33, 32, 35)
  ..cubicTo(29, 33, 26, 29, 26, 23)
  ..cubicTo(26, 18, 28, 14, 32, 14)
  ..close();

Path _tail() => Path()
  ..moveTo(28, 34)
  ..lineTo(20, 43)
  ..lineTo(32, 38)
  ..lineTo(44, 43)
  ..lineTo(36, 34)
  ..close();

/// Los puntos del pájaro donde acaban las chispas (relativos al centro) y
/// su color (0 = menta, 1 = violeta, de izquierda a derecha).
final List<(Offset, double)> _birdPoints = () {
  final List<Path> parts = <Path>[_leftWing(), _rightWing(), _body(), _tail()];
  final List<(Offset, double)> out = <(Offset, double)>[];
  for (double y = 0; y <= 44; y += 4 / 3) {
    for (double x = 0; x <= 64; x += 4 / 3) {
      final Offset p = Offset(x, y);
      if (parts.any((Path path) => path.contains(p))) {
        out.add((Offset((x - 32) * 1.71, (y - 22) * 1.71), x / 64));
      }
    }
  }
  return out;
}();

/// El vuelo: una curva que da la vuelta a la bola (puntos de la maqueta).
const List<Offset> _flight = <Offset>[
  Offset.zero,
  Offset.zero,
  Offset(110, -80),
  Offset(30, -130),
  Offset(-120, -70),
  Offset(-90, 50),
  Offset(70, 60),
  Offset.zero,
  Offset.zero,
];

double _cr(double p0, double p1, double p2, double p3, double u) {
  final double u2 = u * u;
  final double u3 = u2 * u;
  return 0.5 *
      ((2 * p1) +
          (-p0 + p2) * u +
          (2 * p0 - 5 * p1 + 4 * p2 - p3) * u2 +
          (-p0 + 3 * p1 - 3 * p2 + p3) * u3);
}

/// Dónde está el pájaro en el momento [s] (0 → 1) del vuelo.
Offset _at(double s) {
  final int n = _flight.length - 3;
  final double f = s.clamp(0.0, 1.0) * n;
  final int i = math.min(f.floor(), n - 1);
  final double u = f - i;
  final Offset a = _flight[i];
  final Offset b = _flight[i + 1];
  final Offset c = _flight[i + 2];
  final Offset d = _flight[i + 3];
  return Offset(_cr(a.dx, b.dx, c.dx, d.dx, u), _cr(a.dy, b.dy, c.dy, d.dy, u));
}

/// Se pone encima de la bola (centrado en ella). No recibe toques.
class FlyraIntro extends StatefulWidget {
  const FlyraIntro({super.key, required this.size});

  /// Lo que mide el dibujo (más grande que la bola: las chispas vienen de
  /// lejos).
  final double size;

  @override
  State<FlyraIntro> createState() => _FlyraIntroState();
}

class _FlyraIntroState extends State<FlyraIntro> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: flyraIntroLength,
  );
  late final AnimationController _dust = AnimationController(
    vsync: this,
    duration: flyraDustLength,
  );
  // Cada chispa sale de un sitio al azar (fijo para toda la entrada).
  late final List<_Spark> _sparks = () {
    final math.Random r = math.Random(7);
    return <_Spark>[
      for (final (Offset to, double c) in _birdPoints)
        _Spark(
          from: Offset.fromDirection(
            r.nextDouble() * 2 * math.pi,
            170 + r.nextDouble() * 120,
          ).scale(1, 0.8),
          to: to,
          color: c,
          delay: r.nextDouble() * 450,
          radius: 0.9 + r.nextDouble() * 1.3,
        ),
    ];
  }();
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || MediaQuery.disableAnimationsOf(context)) return;
    _started = true;
    _intro.forward();
    _dust.forward();
  }

  @override
  void dispose() {
    _intro.dispose();
    _dust.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return SizedBox.square(dimension: widget.size);
    }
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _IntroPainter(_intro, _dust, _sparks),
        ),
      ),
    );
  }
}

class _Spark {
  const _Spark({
    required this.from,
    required this.to,
    required this.color,
    required this.delay,
    required this.radius,
  });

  final Offset from;
  final Offset to;
  final double color; // 0 menta → 1 violeta
  final double delay; // ms
  final double radius;
}

class _IntroPainter extends CustomPainter {
  _IntroPainter(this.intro, this.dust, this.sparks)
    : super(repaint: Listenable.merge(<Listenable>[intro, dust]));

  final Animation<double> intro;
  final Animation<double> dust;
  final List<_Spark> sparks;

  static final Path _wingL = _leftWing();
  static final Path _wingR = _rightWing();
  static final Path _birdBody = _body();
  static final Path _birdTail = _tail();

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = size.center(Offset.zero);
    _paintDust(canvas, center);
    final double t = intro.value * flyraIntroLength.inMilliseconds;
    if (intro.value <= 0 || intro.value >= 1) return;

    final Paint glow = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4);

    // 1) Las chispas se juntan y forman el pájaro.
    if (t < 2000) {
      final double fade = t < 1700 ? 1 : math.max(0, 1 - (t - 1700) / 300);
      for (final _Spark p in sparks) {
        final double u = ((t - 300 - p.delay) / 950).clamp(0, 1);
        final double e = 1 - math.pow(1 - u, 3).toDouble();
        final Offset pos = center + p.from * (1 - e) + p.to * e;
        final double a = math.min(1, u * 3) * fade * (0.5 + 0.5 * u);
        if (a <= 0) continue;
        glow.color = Color.lerp(
          _colors[0],
          _colors[1],
          p.color,
        )!.withValues(alpha: a);
        canvas.drawCircle(pos, p.radius, glow);
      }
    }

    // 2) El destello.
    if (t > 1450 && t < 2100) {
      final double f = 1 - (t - 1700).abs() / 400;
      if (f > 0) {
        final double r = 130 * f + 20;
        canvas.drawCircle(
          center,
          r,
          Paint()
            ..shader = RadialGradient(
              colors: <Color>[
                Colors.white.withValues(alpha: 0.9 * f),
                _colors[0].withValues(alpha: 0.45 * f),
                _colors[1].withValues(alpha: 0),
              ],
              stops: const <double>[0, 0.35, 1],
            ).createShader(Rect.fromCircle(center: center, radius: r)),
        );
      }
    }

    // 3) El vuelo con su estela.
    final double fs = (t - 1700) / 1400;
    if (fs > 0) {
      double ease(double s) {
        final double e = s < 0.5
            ? 2 * s * s
            : 1 - math.pow(-2 * s + 2, 2).toDouble() / 2;
        return 0.3 * s + 0.7 * e;
      }

      // La estela: los últimos puntos por los que ha pasado.
      final double head = ease(fs.clamp(0, 1));
      final double tailStart = fs >= 1
          ? head - math.max(0, 0.35 - (fs - 1) * 0.6)
          : head - 0.35;
      const int steps = 40;
      Offset? prev;
      for (int i = 0; i <= steps; i++) {
        final double s = tailStart + (head - tailStart) * i / steps;
        if (s < 0) continue;
        final Offset p = center + _at(s);
        if (prev != null) {
          final double a = i / steps;
          canvas.drawLine(
            prev,
            p,
            Paint()
              ..color = _colors[(i >> 3) % 4].withValues(alpha: a * 0.8)
              ..strokeWidth = 0.6 + a * 4.2
              ..strokeCap = StrokeCap.round
              ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 3),
          );
        }
        prev = p;
      }

      // El pájaro, mientras vuela.
      if (fs < 1) {
        final Offset p = _at(head);
        final Offset q = _at(math.min(head + 0.012, 1));
        final double angle = math.atan2(q.dy - p.dy, q.dx - p.dx) * 0.3;
        final double scale = 1.7 - 0.75 * math.sin(head * math.pi) * 0.9;
        final double opacity = fs < 0.08 ? fs / 0.08 : 1;
        // Aleteo: las alas suben y bajan rápido.
        final double flap = math.sin(t / 220 * math.pi);
        _paintBird(canvas, center + p, angle, scale, opacity, flap);
      }
    }

    // 4) Al aterrizar, tres ondas.
    for (int k = 0; k < 3; k++) {
      final double u = (t - 3100 - k * 200) / 1300;
      if (u < 0 || u > 1) continue;
      canvas.drawCircle(
        center,
        92 + u * 80,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 * (1 - u) + 0.5
          ..color = _colors[k % 2].withValues(alpha: (1 - u) * 0.6),
      );
    }
  }

  void _paintBird(
    Canvas canvas,
    Offset at,
    double angle,
    double scale,
    double opacity,
    double flap,
  ) {
    canvas
      ..save()
      ..translate(at.dx, at.dy)
      ..rotate(angle)
      ..scale(scale)
      ..translate(-32, -22);
    final Paint fill = Paint()
      ..shader = LinearGradient(
        colors: <Color>[
          _colors[0].withValues(alpha: opacity),
          _colors[1].withValues(alpha: opacity),
        ],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(const Rect.fromLTWH(0, 0, 64, 44));
    final Paint halo = Paint()
      ..color = _colors[0].withValues(alpha: 0.6 * opacity)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    // Cada ala gira un poco sobre el hombro (32, 22).
    for (final (Path wing, double dir) in <(Path, double)>[
      (_wingL, 1),
      (_wingR, -1),
    ]) {
      canvas
        ..save()
        ..translate(32, 22)
        ..scale(1, 1 - 0.35 * (0.5 + 0.5 * flap))
        ..rotate(dir * 0.08 * flap)
        ..translate(-32, -22)
        ..drawPath(wing, halo)
        ..drawPath(wing, fill)
        ..restore();
    }
    canvas
      ..drawPath(_birdBody, fill)
      ..drawPath(
        _birdTail,
        Paint()..color = _colors[1].withValues(alpha: opacity),
      )
      ..restore();
  }

  /// Polvo de estrellas: 24 motas que salen del borde de la bola, suben un
  /// poco, brillan y se apagan. Cada mota repite su ciclo mientras dura.
  void _paintDust(Canvas canvas, Offset center) {
    if (dust.value <= 0 || dust.value >= 1) return;
    final double now = dust.value * flyraDustLength.inMilliseconds / 16.7;
    final math.Random r = math.Random(3);
    final Paint p = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 4);
    for (int i = 0; i < 24; i++) {
      final double life = 140 + r.nextDouble() * 160; // en "fotogramas"
      final double offset = r.nextDouble() * life;
      final double angle0 = r.nextDouble() * 2 * math.pi;
      final double speed = 0.15 + r.nextDouble() * 0.45;
      final double radius = 0.5 + r.nextDouble() * 1.2;
      final Color color = _colors[r.nextInt(4)];
      final double twinkle = r.nextDouble() * 6;
      final double age = (now + offset) % life;
      final int round = ((now + offset) / life).floor();
      // Cada vuelta, la mota sale por otro sitio.
      final double a = angle0 + round * 2.399;
      final Offset start = center + Offset.fromDirection(a, 70);
      final Offset pos =
          start +
          Offset(
            math.cos(a) * speed * age + math.sin(age * 0.03 + twinkle) * 3,
            (math.sin(a) * speed - 0.08) * age,
          );
      final double alpha =
          math.sin(age / life * math.pi) *
          (0.5 + 0.5 * math.sin(age * 0.15 + twinkle));
      if (alpha <= 0) continue;
      p.color = color.withValues(alpha: alpha.clamp(0, 1));
      canvas.drawCircle(pos, radius, p);
    }
  }

  @override
  bool shouldRepaint(_IntroPainter old) => false;
}
