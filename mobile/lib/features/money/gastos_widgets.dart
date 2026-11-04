// Las piezas de la pantalla de un gasto (maqueta 8), cada una igual que en
// la maqueta: el anillo que gira alrededor de una cara, la tarjeta de cada
// persona, la tarjeta de "Le debes a…", el selector "A partes iguales /
// Por lo que tomó cada uno", la tarjeta de cada plato y la de los extras.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/theme.dart';
import 'gastos_art.dart';

/// Un reloj que da vueltas sin fin, para los adornos (anillos, brillos).
class LoopClock extends StatefulWidget {
  const LoopClock({super.key, required this.period, required this.builder});

  final Duration period;
  final Widget Function(BuildContext context, double value) builder;

  @override
  State<LoopClock> createState() => _LoopClockState();
}

class _LoopClockState extends State<LoopClock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.period,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || MediaQuery.disableAnimationsOf(context)) return;
    _started = true;
    Motion.loop(_c, testCount: 1);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (BuildContext context, _) => widget.builder(context, _c.value),
  );
}

/// El anillo de colores que gira alrededor de una cara.
class SpinRing extends StatelessWidget {
  const SpinRing({
    super.key,
    required this.size,
    required this.colors,
    required this.width,
    required this.period,
  });

  final double size;
  final List<Color> colors;
  final double width;
  final Duration period;

  @override
  Widget build(BuildContext context) => LoopClock(
    period: period,
    builder: (BuildContext context, double v) => Transform.rotate(
      angle: v * 2 * math.pi,
      child: CustomPaint(
        size: Size.square(size),
        painter: _RingPainter(colors, width),
      ),
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.colors, this.width);

  final List<Color> colors;
  final double width;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect r = Offset.zero & size;
    canvas.drawCircle(
      r.center,
      size.width / 2 - width / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = SweepGradient(
          colors: colors,
          transform: const GradientRotation(-math.pi / 2),
        ).createShader(r),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => false;
}

/// Una raya de luz que cruza una tarjeta de vez en cuando.
class Sheen extends StatelessWidget {
  const Sheen({
    super.key,
    required this.width,
    required this.period,
    this.delay = Duration.zero,
    this.color = const Color(0x29FFFFFF),
  });

  final double width;
  final Duration period;
  final Duration delay;
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => LoopClock(
        period: period,
        builder: (BuildContext context, double v) {
          // Cruza en la primera mitad (55 %) de la vuelta y luego espera.
          final double shifted =
              (v - delay.inMilliseconds / period.inMilliseconds) % 1;
          final double k = Curves.easeInOut.transform(
            (shifted / 0.55).clamp(0, 1),
          );
          final double from = -1.4 * width, to = 4.2 * width;
          return Transform(
            transform: Matrix4.translationValues(from + (to - from) * k, 0, 0)
              ..multiply(Matrix4.skewX(-20 * math.pi / 180)),
            child: Container(
              width: width,
              height: box.maxHeight,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: <Color>[
                    color.withValues(alpha: 0),
                    color,
                    color.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Las caras del gasto: la tarjeta de una persona con lo que le toca.
class PersonCard extends StatelessWidget {
  const PersonCard({
    super.key,
    required this.color,
    required this.initial,
    required this.name,
    required this.amount,
    required this.index,
    this.tag,
    this.tagColor = const Color(0xFFFFD25E),
  });

  final Color color;
  final String initial;
  final String name;
  final String amount;

  /// Su sitio en la lista: cambia lo rápido que gira el anillo y cuándo
  /// pasa el brillo.
  final int index;

  /// "PAGÓ" o "SALDADO" arriba a la derecha.
  final String? tag;
  final Color tagColor;

  @override
  Widget build(BuildContext context) => Container(
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.27)),
      gradient: LinearGradient(
        begin: const Alignment(-0.6, -1),
        end: const Alignment(0.6, 1),
        colors: <Color>[
          Color.alphaBlend(color.withValues(alpha: 0.13), GastosColors.card),
          GastosColors.card,
          const Color(0xFF0F181E),
        ],
        stops: const <double>[0, 0.45, 1],
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: color.withValues(alpha: 0.9),
          blurRadius: 26,
          spreadRadius: -16,
          offset: const Offset(0, 14),
        ),
      ],
    ),
    child: Stack(
      children: <Widget>[
        // El brillo de color de arriba a la izquierda.
        Positioned(
          left: -20,
          top: -30,
          child: Container(
            width: 90,
            height: 90,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: <Color>[
                  color.withValues(alpha: 0.2),
                  color.withValues(alpha: 0),
                ],
                stops: const <double>[0, 0.7],
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: OnScreenOnly(
            child: Sheen(
              width: 26,
              period: const Duration(milliseconds: 4500),
              delay: Duration(milliseconds: 900 * index),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 40,
                height: 40,
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    OnScreenOnly(
                      child: SpinRing(
                        size: 40,
                        width: 3,
                        colors: <Color>[
                          color,
                          color.withValues(alpha: 0),
                          color,
                          color.withValues(alpha: 0),
                        ],
                        period: Duration(milliseconds: 3000 + 600 * index),
                      ),
                    ),
                    Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: color,
                        border: Border.all(
                          color: NomadColors.background,
                          width: 2,
                        ),
                        gradient: RadialGradient(
                          center: const Alignment(-0.3, -0.4),
                          radius: 0.5,
                          colors: <Color>[
                            Color.alphaBlend(const Color(0x66FFFFFF), color),
                            color,
                          ],
                        ),
                      ),
                      child: Text(
                        initial,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0B1217),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: GastosColors.muted,
                      ),
                    ),
                    const SizedBox(height: 1),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        transitionBuilder: (
                          Widget child,
                          Animation<double> a,
                        ) => ScaleTransition(scale: a, child: child),
                        child: Text(
                          amount,
                          key: ValueKey<String>(amount),
                          style: TextStyle(
                            fontFamily: NomadFonts.display,
                            fontVariations: const <FontVariation>[
                              FontVariation.weight(800),
                            ],
                            fontSize: 20,
                            color: GastosColors.text,
                            shadows: <Shadow>[
                              Shadow(
                                color: color.withValues(alpha: 0.33),
                                blurRadius: 14,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (tag != null)
          PositionedDirectional(
            top: 8,
            end: 8,
            child: Container(
              height: 16,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tagColor,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                tag!,
                style: const TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                  color: Color(0xFF0B1217),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// "A partes iguales" / "Por lo que tomó cada uno".
class SplitSwitch extends StatelessWidget {
  const SplitSwitch({
    super.key,
    required this.labels,
    required this.selected,
    required this.onPick,
  });

  final List<String> labels;

  /// null = ninguno (el gasto se reparte con pesos).
  final int? selected;
  final ValueChanged<int>? onPick;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: GastosColors.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: GastosColors.line),
    ),
    child: Row(
      children: <Widget>[
        for (int i = 0; i < labels.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(width: 6),
          Expanded(
            child: Semantics(
              button: true,
              selected: selected == i,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onPick == null ? null : () => onPick!(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  constraints: const BoxConstraints(minHeight: 44),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected == i
                        ? GastosColors.amber
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    labels[i],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: selected == i
                          ? const Color(0xFF0B1217)
                          : const Color(0xFFDCE5E9),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// Un botón redondo pequeño de la maqueta ("No", "5 %", "+6,00 €"...).
class ToggleChip extends StatelessWidget {
  const ToggleChip({
    super.key,
    required this.label,
    required this.on,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool on;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: on,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      // 44 px de alto para el dedo, aunque el botón se vea de 32.
      child: SizedBox(
        height: 44,
        child: Center(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? color : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: on ? null : Border.all(color: const Color(0xFF33444E)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: on ? const Color(0xFF0B1217) : GastosColors.muted,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// El circulito de una persona en un plato (encendido si lo tomó).
class PersonToggle extends StatelessWidget {
  const PersonToggle({
    super.key,
    required this.label,
    required this.name,
    required this.on,
    required this.color,
    required this.onTap,
  });

  final String label;
  final String name;
  final bool on;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: on,
    label: name,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: 34,
        height: 44,
        child: Center(
          child: AnimatedScale(
            scale: on ? 1 : 0.94,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOutBack,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 34,
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
                border: on
                    ? null
                    : Border.all(color: const Color(0xFF33444E), width: 1.5),
                boxShadow: on
                    ? <BoxShadow>[
                        BoxShadow(
                          color: color.withValues(alpha: 0.4),
                          blurRadius: 12,
                        ),
                      ]
                    : null,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: on ? const Color(0xFF0B1217) : const Color(0xFF6B7A84),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// La caja oscura de las tarjetas de la maqueta.
BoxDecoration gastosBox({double radius = 16}) => BoxDecoration(
  color: GastosColors.card,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: GastosColors.line),
);

/// Entra subiendo 18 px y apareciendo (nq-rise de la maqueta).
Widget riseIn(double k, Widget child) {
  final double e = Curves.ease.transform(k.clamp(0, 1));
  return Opacity(
    opacity: e,
    child: Transform.translate(offset: Offset(0, 18 * (1 - e)), child: child),
  );
}

/// Entra girando desde atrás (gx-in de la maqueta) para las tarjetas.
Widget cardIn(double k, Widget child) {
  final double e = const Cubic(0.2, 0.9, 0.3, 1.2).transform(k.clamp(0, 1));
  return Opacity(
    opacity: k.clamp(0, 1),
    child: Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.002)
        ..translateByDouble(0, 18 * (1 - e), 0, 1)
        ..rotateX(25 * math.pi / 180 * (1 - e))
        ..scaleByDouble(0.92 + 0.08 * e, 0.92 + 0.08 * e, 1, 1),
      child: child,
    ),
  );
}
