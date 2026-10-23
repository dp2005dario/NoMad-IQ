// La gráfica del precio de una ruta: una línea con el precio más bajo de
// cada día y un punto en el último. Se dibuja "a mano" (CustomPainter) para
// no añadir una librería de gráficas solo para esto.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'fares_api.dart';

class PriceChart extends StatelessWidget {
  const PriceChart({
    super.key,
    required this.points,
    required this.semanticLabel,
  });

  final List<PricePoint> points;

  /// Lo que lee el lector de pantalla (TalkBack) en vez de la línea.
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        height: 160,
        width: double.infinity,
        // La gráfica siempre va de izquierda (antes) a derecha (ahora),
        // también en árabe: es un eje de tiempo, no texto.
        child: CustomPaint(painter: _ChartPainter(points)),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter(this.points);

  final List<PricePoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const double pad = 8;
    final int lo = points.map((PricePoint p) => p.minMinor).reduce(math.min);
    final int hi = points.map((PricePoint p) => p.minMinor).reduce(math.max);
    final double span = math.max(1, hi - lo).toDouble();
    final double w = size.width - pad * 2;
    final double h = size.height - pad * 2;

    Offset at(int i) {
      final double x = points.length == 1
          ? size.width / 2
          : pad + w * i / (points.length - 1);
      final double y = pad + h * (1 - (points[i].minMinor - lo) / span);
      return Offset(x, y);
    }

    // Líneas de guía (arriba = el más caro, abajo = el más barato).
    final Paint grid = Paint()
      ..color = NomadColors.outline
      ..strokeWidth = 1;
    canvas
      ..drawLine(Offset(pad, pad), Offset(size.width - pad, pad), grid)
      ..drawLine(
        Offset(pad, size.height - pad),
        Offset(size.width - pad, size.height - pad),
        grid,
      );

    final Path line = Path()..moveTo(at(0).dx, at(0).dy);
    for (int i = 1; i < points.length; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    canvas.drawPath(
      line,
      Paint()
        ..color = NomadColors.flights
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(
      at(points.length - 1),
      6,
      Paint()..color = NomadColors.mint,
    );
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.points != points;
}
