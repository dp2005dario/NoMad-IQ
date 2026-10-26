// El dibujo de cada tipo de enchufe (A, B, C... G...), visto de frente.
//
// Son dibujos sencillos para reconocer la forma en la tienda ("¿es este el
// adaptador?"), no planos a escala. Las letras son las de la tabla oficial
// de la IEC (la organización que pone nombre a cada tipo).
import 'package:flutter/material.dart';

class PlugIcon extends StatelessWidget {
  const PlugIcon(this.type, {super.key, this.size = 56, this.color});

  /// La letra del tipo ("G").
  final String type;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _PlugPainter(
        type,
        color ?? Theme.of(context).colorScheme.onSurface,
      ),
    ),
  );
}

class _PlugPainter extends CustomPainter {
  _PlugPainter(this.type, this.color);

  final String type;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width;
    final Paint face = Paint()
      ..color = color.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;
    final Paint edge = Paint()
      ..color = color.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.03;
    final Paint pin = Paint()..color = color;
    final RRect body = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(s * 0.22),
    );
    canvas
      ..drawRRect(body, face)
      ..drawRRect(body.deflate(s * 0.015), edge);

    // Ayudantes: un agujero redondo o una ranura en (x, y) relativos (0-1).
    void round(double x, double y, [double r = 0.07]) =>
        canvas.drawCircle(Offset(x * s, y * s), r * s, pin);
    void slot(double x, double y, double w, double h, [double angle = 0]) {
      canvas
        ..save()
        ..translate(x * s, y * s)
        ..rotate(angle);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: w * s, height: h * s),
          Radius.circular(s * 0.02),
        ),
        pin,
      );
      canvas.restore();
    }

    switch (type) {
      case 'A':
        slot(0.35, 0.5, 0.08, 0.3);
        slot(0.65, 0.5, 0.08, 0.3);
      case 'B':
        slot(0.35, 0.4, 0.08, 0.26);
        slot(0.65, 0.4, 0.08, 0.26);
        round(0.5, 0.74, 0.07);
      case 'C':
        round(0.33, 0.5);
        round(0.67, 0.5);
      case 'D' || 'M':
        round(0.5, 0.28, 0.1);
        round(0.3, 0.66, 0.08);
        round(0.7, 0.66, 0.08);
      case 'E':
        round(0.33, 0.55);
        round(0.67, 0.55);
        round(0.5, 0.24, 0.05);
      case 'F':
        round(0.33, 0.5);
        round(0.67, 0.5);
        slot(0.5, 0.12, 0.16, 0.05);
        slot(0.5, 0.88, 0.16, 0.05);
      case 'G':
        slot(0.5, 0.3, 0.09, 0.22);
        slot(0.3, 0.68, 0.2, 0.08);
        slot(0.7, 0.68, 0.2, 0.08);
      case 'H':
        slot(0.32, 0.42, 0.07, 0.22, -0.5);
        slot(0.68, 0.42, 0.07, 0.22, 0.5);
        slot(0.5, 0.74, 0.07, 0.2);
      case 'I':
        slot(0.32, 0.38, 0.07, 0.24, 0.55);
        slot(0.68, 0.38, 0.07, 0.24, -0.55);
        slot(0.5, 0.74, 0.07, 0.2);
      case 'J':
        round(0.28, 0.45);
        round(0.72, 0.45);
        round(0.5, 0.68);
      case 'K':
        round(0.3, 0.4);
        round(0.7, 0.4);
        canvas.drawArc(
          Rect.fromCenter(
            center: Offset(0.5 * s, 0.68 * s),
            width: 0.2 * s,
            height: 0.2 * s,
          ),
          0,
          3.1416,
          true,
          pin,
        );
      case 'L':
        round(0.25, 0.5, 0.06);
        round(0.5, 0.5, 0.06);
        round(0.75, 0.5, 0.06);
      case 'N':
        round(0.3, 0.6);
        round(0.7, 0.6);
        round(0.5, 0.32);
      case 'O':
        round(0.32, 0.4);
        round(0.68, 0.4);
        round(0.5, 0.7);
      default:
        // Un tipo que no sabemos dibujar: solo la letra.
        break;
    }
  }

  @override
  bool shouldRepaint(_PlugPainter old) =>
      old.type != type || old.color != color;
}
