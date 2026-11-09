// "Juntar móviles con Álex" (maqueta 8): la escena animada de los dos
// móviles que se acercan, se conectan y las monedas pasan de uno a otro.
//
// Dura 5,6 s. Los tiempos son los de la maqueta:
//   0,0–1,3 s  los móviles entran desde los lados (rebotan un poco);
//   0,75 s     destello en el centro, 3 ondas y "Conectados";
//   1,3–3,5 s  7 monedas vuelan de tu móvil al suyo y la barra de la deuda
//              se vacía;
//   3,5 s      la deuda pasa a 0,00;
//   3,9 s      sale el sello verde ✓ con chispas;
//   4,6 s      "Abriendo tu banco…".
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'gastos_art.dart';

/// Cuánto dura la escena (luego se abre el banco).
const Duration tapSceneLength = Duration(milliseconds: 5600);

/// Avance de 0 a 1 de una animación que empieza en [start] y dura [length]
/// (en segundos), sabiendo que ahora vamos por [t] segundos.
double _k(double t, double start, double length) =>
    ((t - start) / length).clamp(0.0, 1.0);

/// Interpola entre "fotogramas clave" (como @keyframes en CSS): [stops] son
/// los puntos de 0 a 1 y [values] lo que vale en cada uno.
double _frames(double k, List<double> stops, List<double> values) {
  if (k <= stops.first) return values.first;
  for (int i = 1; i < stops.length; i++) {
    if (k <= stops[i]) {
      final double f = (k - stops[i - 1]) / (stops[i] - stops[i - 1]);
      return values[i - 1] +
          (values[i] - values[i - 1]) * Curves.easeInOut.transform(f);
    }
  }
  return values.last;
}

/// El título de la hoja: "Deuda en proceso de saldar" → "¡Todo listo!".
class TapTitle extends StatelessWidget {
  const TapTitle({super.key, required this.t});

  /// Segundos desde que empezó la escena.
  final double t;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    const TextStyle style = TextStyle(
      fontFamily: NomadFonts.display,
      fontVariations: <FontVariation>[FontVariation.weight(800)],
      fontSize: 20,
    );
    final double out = _k(t, 4.4, 0.3);
    final double inn = _k(t, 4.5, 0.4);
    return SizedBox(
      height: 26,
      child: Stack(
        children: <Widget>[
          Opacity(
            opacity: 1 - out,
            child: Transform.translate(
              offset: Offset(0, -8 * out),
              child: Text(l.tapTitle, maxLines: 1, style: style),
            ),
          ),
          Opacity(
            opacity: inn,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - inn)),
              child: Text(
                l.tapReady,
                maxLines: 1,
                style: style.copyWith(color: NomadColors.mint),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// La escena de 300 px de alto con los dos móviles.
class TapScene extends StatelessWidget {
  const TapScene({
    super.key,
    required this.t,
    required this.otherInitial,
    required this.otherColor,
    required this.debtLabel,
    required this.amount,
    required this.zero,
  });

  /// Segundos desde que empezó la escena.
  final double t;
  final String otherInitial;
  final Color otherColor;

  /// "Deuda con Álex".
  final String debtLabel;

  /// La deuda ("21,50 €") y la misma a cero ("0,00 €").
  final String amount;
  final String zero;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        // La maqueta mide 358 px de ancho: todo se coloca respecto al centro.
        final double w = box.maxWidth.isFinite ? box.maxWidth : 358;
        final double dx = (w - 358) / 2;
        // Entrada de los móviles (gzb-l / gzb-r): -120 → 64 → 48 → 44.
        final double inK = _k(t, 0, 1.3);
        final double slide = _frames(
          inK,
          <double>[0, 0.55, 0.68, 1],
          <double>[-120, 64, 48, 44],
        );
        final double tilt = _frames(
          inK,
          <double>[0, 0.55, 0.68, 1],
          <double>[-14, 4, 0, 0],
        );
        // Tiembla al conectar (0,78 s) y al terminar (3,95 s).
        final bool buzz =
            (t >= 0.78 && t < 0.78 + 0.56) || (t >= 3.95 && t < 3.95 + 0.7);
        final double shake = buzz ? math.sin(t * math.pi * 2 / 0.07) * 2 : 0;
        final double glow = _k(t, 0.78, 0.9);
        final double chip = _k(t, 0.9, 2.6);
        final double chipOpacity = chip < 0.12
            ? chip / 0.12
            : chip > 0.85
            ? (1 - chip) / 0.15
            : 1;
        final double rise = _k(t, 1, 0.4);
        final double drain = Curves.easeInOut.transform(_k(t, 1.3, 2.4));
        final double out = _k(t, 3.5, 0.3);
        final double inn = _k(t, 3.6, 0.4);
        final double stamp = _k(t, 3.9, 0.55);
        return ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Container(
            height: 300,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.1),
                radius: 0.85,
                colors: <Color>[
                  Color(0xFF163A31),
                  Color(0xFF08110F),
                  Color(0xFF05080A),
                ],
                stops: <double>[0, 0.6, 1],
              ),
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BackPainter(t: t, dx: dx),
                  ),
                ),
                // "Conectados".
                Positioned(
                  top: 30,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Opacity(
                      opacity: chipOpacity.clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(
                          0,
                          chip < 0.12 ? 8 * (1 - chip / 0.12) : 0,
                        ),
                        child: Container(
                          height: 24,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          decoration: BoxDecoration(
                            color: const Color(0x293DDC97),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: NomadColors.mint),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Icon(
                                Icons.wifi_tethering_rounded,
                                size: 14,
                                color: Color(0xFF9BFFD3),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                l.tapConnected,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF9BFFD3),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // Tu móvil (izquierda) y el suyo (derecha).
                Positioned(
                  top: 72,
                  left: dx + 30 + slide + shake,
                  child: Transform.rotate(
                    angle: tilt * math.pi / 180,
                    child: _Phone(
                      label: l.tapYou,
                      color: NomadColors.mint,
                      glow: glow,
                    ),
                  ),
                ),
                Positioned(
                  top: 72,
                  left: dx + 236 - slide - shake,
                  child: Transform.rotate(
                    angle: -tilt * math.pi / 180,
                    child: _Phone(
                      label: otherInitial,
                      color: otherColor,
                      glow: glow,
                    ),
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _FrontPainter(t: t, dx: dx),
                  ),
                ),
                // La barra de la deuda que se vacía.
                Positioned(
                  left: 22,
                  right: 22,
                  bottom: 22,
                  child: Opacity(
                    opacity: rise,
                    child: Transform.translate(
                      offset: Offset(0, 18 * (1 - rise)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  debtLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: GastosColors.muted,
                                  ),
                                ),
                              ),
                              SizedBox(
                                height: 26,
                                width: 110,
                                child: Stack(
                                  alignment: Alignment.centerRight,
                                  children: <Widget>[
                                    Opacity(
                                      opacity: 1 - out,
                                      child: Transform.translate(
                                        offset: Offset(0, -8 * out),
                                        child: _Big(amount),
                                      ),
                                    ),
                                    Opacity(
                                      opacity: inn,
                                      child: Transform.translate(
                                        offset: Offset(0, 8 * (1 - inn)),
                                        child: _Big(
                                          zero,
                                          color: NomadColors.mint,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 12,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: CustomPaint(
                                painter: _BarPainter(
                                  left: 1 - drain,
                                  shine: t < 1.3 || t > 4.3
                                      ? -1
                                      : ((t - 1.3) % 1.0),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // El sello verde con el ✓.
                if (stamp > 0)
                  Positioned(
                    top: 120,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Opacity(
                        opacity: stamp,
                        child: Transform.rotate(
                          angle:
                              -25 *
                              (1 - Curves.easeOutBack.transform(stamp)) *
                              math.pi /
                              180,
                          child: Transform.scale(
                            scale:
                                1 +
                                1.4 * (1 - Curves.easeOutBack.transform(stamp)),
                            child: _Stamp(check: _k(t, 4.25, 0.4)),
                          ),
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _SparkPainter(t: t, dx: dx),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// "Abriendo tu banco…" con su ruedita (sale a los 4,6 s).
class TapOpening extends StatelessWidget {
  const TapOpening({super.key, required this.t, required this.text});

  final double t;
  final String text;

  @override
  Widget build(BuildContext context) {
    final double k = _k(t, 4.6, 0.4);
    return Opacity(
      opacity: k,
      child: Transform.translate(
        offset: Offset(0, 18 * (1 - k)),
        child: Row(
          children: <Widget>[
            Transform.rotate(
              angle: (t / 0.8) * 2 * math.pi,
              child: const SizedBox(
                width: 18,
                height: 18,
                child: CustomPaint(painter: _SpinPainter()),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFCFE9DE),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Big extends StatelessWidget {
  const _Big(this.text, {this.color = GastosColors.text});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerRight,
    child: Text(
      text,
      style: TextStyle(
        fontFamily: NomadFonts.display,
        fontVariations: const <FontVariation>[FontVariation.weight(800)],
        fontSize: 22,
        color: color,
      ),
    ),
  );
}

/// Un móvil dibujado: pantalla oscura, la inicial y dos rayas.
class _Phone extends StatelessWidget {
  const _Phone({required this.label, required this.color, required this.glow});

  final String label;
  final Color color;
  final double glow;

  @override
  Widget build(BuildContext context) {
    // gzb-glow: sombra normal → brillo verde fuerte (30 %) → brillo suave.
    final double g = glow < 0.3 ? glow / 0.3 : 1 - (glow - 0.3) / 0.7 * 0.7;
    return Container(
      width: 92,
      height: 160,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: const LinearGradient(
          begin: Alignment(-0.5, -1),
          end: Alignment(0.5, 1),
          colors: <Color>[Color(0xFF2A3B45), Color(0xFF0E171C)],
          stops: <double>[0, 0.7],
        ),
        border: Border.all(color: const Color(0xFF4A5D69), width: 2),
        boxShadow: <BoxShadow>[
          const BoxShadow(
            color: Color(0x8C000000),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
          if (glow > 0)
            BoxShadow(
              color: NomadColors.mint.withValues(alpha: 0.7 * g),
              blurRadius: 34 * g + 16 * (1 - g),
              spreadRadius: 6 * g + 2 * (1 - g),
            ),
        ],
      ),
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          Positioned(
            top: 7,
            child: Container(
              width: 26,
              height: 5,
              decoration: BoxDecoration(
                color: const Color(0xFF0B1217),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: color.withValues(alpha: 0.53),
                      blurRadius: 18,
                    ),
                  ],
                ),
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0B1217),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final double w in <double>[48, 32]) ...<Widget>[
                Container(
                  width: w,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFF33444E),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// El sello verde de 96 px con el ✓ que se dibuja solo.
class _Stamp extends StatelessWidget {
  const _Stamp({required this.check});

  final double check;

  @override
  Widget build(BuildContext context) => Container(
    width: 96,
    height: 96,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(
        center: Alignment(-0.3, -0.4),
        colors: <Color>[Color(0xFFB6FFE0), NomadColors.mint, Color(0xFF138A5C)],
        stops: <double>[0, 0.45, 1],
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(color: Color(0xFF0B1217), spreadRadius: 5),
        BoxShadow(color: NomadColors.mint, spreadRadius: 8, blurRadius: 0),
        BoxShadow(color: Color(0x8C3DDC97), blurRadius: 40, spreadRadius: 10),
      ],
    ),
    child: CustomPaint(painter: _CheckPainter(check)),
  );
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.k);

  final double k;

  @override
  void paint(Canvas canvas, Size size) {
    if (k <= 0) return;
    // El ✓ de 50 px dentro de los 96 px del sello (viewBox 24×24).
    final double s = 50 / 24;
    final Offset o = Offset((size.width - 50) / 2, (size.height - 50) / 2);
    final Path p = Path()
      ..moveTo(o.dx + 5 * s, o.dy + 12.5 * s)
      ..lineTo(o.dx + 9.5 * s, o.dy + 17 * s)
      ..lineTo(o.dx + 19 * s, o.dy + 7.5 * s);
    final Paint paint = Paint()
      ..color = const Color(0xFF0B1217)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.2 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final PathMetric m in p.computeMetrics()) {
      canvas.drawPath(m.extractPath(0, m.length * k), paint);
    }
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.k != k;
}

/// Las estrellitas, el destello, las ondas, los anillos y el arco.
class _BackPainter extends CustomPainter {
  _BackPainter({required this.t, required this.dx});

  final double t;
  final double dx;

  @override
  void paint(Canvas canvas, Size size) {
    // 18 estrellitas que parpadean (nq-led).
    for (int i = 0; i < 18; i++) {
      final double period = 1.4 + 0.3 * (i % 5);
      final double local = t - 0.11 * i;
      double o = 0.5;
      if (local > 0) {
        // Va y vuelve (alternate): 1 → 0,2 → 1.
        final double ph = (local / period) % 2;
        final double f = ph < 1 ? ph : 2 - ph;
        o = 0.5 * (f < 0.5 ? 1 - 1.6 * f : 0.2 + 1.6 * (f - 0.5));
      }
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(dx + (53.0 * i) % 370, (37.0 * i) % 290, 2, 2),
          const Radius.circular(1),
        ),
        Paint()..color = const Color(0xFFCCFFFF).withValues(alpha: o),
      );
    }
    final Offset c = Offset(dx + 179, 152);
    // Destello al conectar (gzb-flash).
    final double f = _k(t, 0.75, 0.7);
    if (f > 0 && f < 1) {
      final double op = f < 0.3 ? f / 0.3 : 1 - (f - 0.3) / 0.7;
      final double r = 60 * (0.3 + 1.5 * f);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              Colors.white.withValues(alpha: op),
              const Color(0xFF9BFFD3).withValues(alpha: op),
              Colors.transparent,
            ],
            stops: const <double>[0, 0.3, 0.7],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    // 3 anillos que se agrandan (gzt-ring).
    for (int i = 0; i < 3; i++) {
      final double k = _k(t, 0.8 + 0.18 * i, 1.1);
      if (k <= 0 || k >= 1) continue;
      canvas.drawCircle(
        c,
        25 * (0.4 + 2.8 * k),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = NomadColors.mint.withValues(alpha: 0.9 * (1 - k)),
      );
    }
    // Las ondas de "conectado" a los dos lados (gzn-wave).
    for (int i = 0; i < 4; i++) {
      final double k = _k(t, 0.85 + 0.12 * i, 1.4);
      if (k <= 0 || k >= 1) continue;
      final double op = k < 0.25
          ? k / 0.25
          : k < 0.7
          ? 1 - (k - 0.25) / 0.45 * 0.1
          : 0.9 * (1 - (k - 0.7) / 0.3);
      final double sc = k < 0.25
          ? 0.5 + 2 * k
          : 1 + (k > 0.7 ? (k - 0.7) / 0.3 * 0.25 : 0);
      final double r = <double>[14, 27, 40, 53][i] * sc;
      final double a = math.asin(
        (<double>[10, 19, 28, 37][i]) / <double>[14, 27, 40, 53][i],
      );
      final Paint p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF9BFFD3).withValues(alpha: op);
      final Rect rect = Rect.fromCircle(center: c, radius: r);
      canvas.drawArc(rect, -a, 2 * a, false, p);
      canvas.drawArc(rect, math.pi - a, 2 * a, false, p);
    }
    // El arco punteado por donde vuelan las monedas (gzc-arc).
    final double arc = _k(t, 1.1, 3.2);
    if (arc > 0 && arc < 1) {
      final double op = arc < 0.15
          ? arc / 0.15 * 0.8
          : arc <= 0.8
          ? 0.8
          : 0.8 * (1 - (arc - 0.8) / 0.2);
      final Path path = Path()
        ..moveTo(dx + 120, 150)
        ..quadraticBezierTo(dx + 179, 40, dx + 238, 150);
      final Paint p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFFFFD25E).withValues(alpha: op);
      final double shift = (arc * 120) % 15;
      for (final PathMetric m in path.computeMetrics()) {
        for (double d = -15 + shift; d < m.length; d += 15) {
          final double a0 = d.clamp(0, m.length);
          final double a1 = (d + 6).clamp(0, m.length);
          if (a1 > a0) canvas.drawPath(m.extractPath(a0, a1), p);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_BackPainter old) => old.t != t || old.dx != dx;
}

/// Las 7 monedas que vuelan de tu móvil al suyo (gzc-fly).
class _FrontPainter extends CustomPainter {
  _FrontPainter({required this.t, required this.dx});

  final double t;
  final double dx;

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < 7; i++) {
      final double k = _k(t, 1.3 + 0.32 * i, 1.05);
      if (k <= 0 || k >= 1) continue;
      const List<double> st = <double>[0, 0.12, 0.5, 0.88, 1];
      final double x = _frames(k, st, <double>[0, 20, 60, 112, 120]);
      final double y = _frames(k, st, <double>[0, -40, -96, -30, -6]);
      final double s = _frames(k, st, <double>[0.4, 1, 1.25, 0.9, 0.3]);
      final double o = _frames(k, st, <double>[0, 1, 1, 1, 0]);
      final double turn = _frames(k, st, <double>[0, 180, 540, 900, 1080]);
      final Offset c = Offset(dx + 105 + 15 + x, 137 + 15 + y);
      canvas
        ..save()
        ..translate(c.dx, c.dy)
        // Girar en Y se ve como estrecharse de lado.
        ..scale(s * math.cos(turn * math.pi / 180).abs().clamp(0.08, 1), s);
      const Rect r = Rect.fromLTWH(-15, -15, 30, 30);
      canvas
        ..drawCircle(
          Offset.zero,
          15,
          Paint()
            ..color = const Color(0xFFFFBE3C).withValues(alpha: 0.6 * o)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
        )
        ..drawCircle(
          Offset.zero,
          15,
          Paint()
            ..shader = RadialGradient(
              center: const Alignment(-0.3, -0.4),
              colors: <Color>[
                const Color(0xFFFFF4C9).withValues(alpha: o),
                const Color(0xFFFFD25E).withValues(alpha: o),
                const Color(0xFFE39B1B).withValues(alpha: o),
                const Color(0xFF9A5B07).withValues(alpha: o),
              ],
              stops: const <double>[0, 0.35, 0.7, 1],
            ).createShader(r),
        )
        ..drawCircle(
          Offset.zero,
          13,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFFFFE7A1).withValues(alpha: o),
        )
        ..drawCircle(
          Offset.zero,
          7,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0x88C77F0A).withValues(alpha: 0.53 * o),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_FrontPainter old) => old.t != t || old.dx != dx;
}

/// Las 10 chispas alrededor del sello (gzc-spark).
class _SparkPainter extends CustomPainter {
  _SparkPainter({required this.t, required this.dx});

  final double t;
  final double dx;

  static const List<Offset> _at = <Offset>[
    Offset(265, 150),
    Offset(266, 202),
    Offset(228, 251),
    Offset(173, 217),
    Offset(124, 202),
    Offset(89, 150),
    Offset(138, 109),
    Offset(168, 66),
    Offset(228, 49),
    Offset(252, 109),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < _at.length; i++) {
      final double k = _k(t, 4.1 + 0.08 * (i % 4), 0.9);
      if (k <= 0 || k >= 1) continue;
      final double o = k < 0.4 ? k / 0.4 : 1 - (k - 0.4) / 0.6;
      final double s = k < 0.4 ? 1.6 * k / 0.4 : 1.6 - 1.2 * (k - 0.4) / 0.6;
      final double up = k < 0.4 ? 0 : -16 * (k - 0.4) / 0.6;
      canvas
        ..save()
        ..translate(dx + _at[i].dx, _at[i].dy + up)
        ..rotate(k * math.pi)
        ..scale(s);
      // Estrella de 4 puntas de 10 px (el clip-path de la maqueta).
      final Path star = Path()
        ..moveTo(0, -5)
        ..lineTo(1.2, -1.2)
        ..lineTo(5, 0)
        ..lineTo(1.2, 1.2)
        ..lineTo(0, 5)
        ..lineTo(-1.2, 1.2)
        ..lineTo(-5, 0)
        ..lineTo(-1.2, -1.2)
        ..close();
      canvas
        ..drawPath(
          star,
          Paint()
            ..color =
                (i.isEven ? const Color(0xFF9BFFD3) : const Color(0xFFFFE38A))
                    .withValues(alpha: o.clamp(0, 1)),
        )
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.t != t || old.dx != dx;
}

/// La barra naranja de la deuda: [left] es lo que queda (de 1 a 0, se vacía
/// hacia la derecha) y [shine] por dónde va el brillo (−1 = sin brillo).
class _BarPainter extends CustomPainter {
  _BarPainter({required this.left, required this.shine});

  final double left;
  final double shine;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF1A2730),
    );
    final Rect full = Offset.zero & size;
    final Rect bar = Rect.fromLTWH(
      size.width * (1 - left),
      0,
      size.width * left,
      size.height,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bar, const Radius.circular(6)),
      Paint()
        ..shader = const LinearGradient(
          colors: <Color>[
            Color(0xFFFF8A65),
            Color(0xFFFFB86B),
            Color(0xFFFFD25E),
          ],
        ).createShader(full),
    );
    if (shine >= 0) {
      final double x = -40 + (size.width + 40) * shine;
      final Rect r = Rect.fromLTWH(x, 0, 40, size.height);
      canvas.drawRect(
        r,
        Paint()
          ..shader = const LinearGradient(
            colors: <Color>[
              Colors.transparent,
              Color(0xAAFFFFFF),
              Colors.transparent,
            ],
          ).createShader(r),
      );
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.left != left || old.shine != shine;
}

/// La ruedita: un aro gris con el trozo de arriba naranja.
class _SpinPainter extends CustomPainter {
  const _SpinPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = (Offset.zero & size).deflate(1.5);
    canvas
      ..drawArc(
        r,
        0,
        2 * math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xFF33444E),
      )
      ..drawArc(
        r,
        -math.pi * 3 / 4,
        math.pi / 2,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = GastosColors.amber,
      );
  }

  @override
  bool shouldRepaint(_SpinPainter old) => false;
}
