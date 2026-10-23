// La foto de perfil de Flyra (la IA de la app): una golondrina sobre un
// círculo que pasa del verde menta al violeta, como en las maquetas.
//
// Se dibuja con código (CustomPainter) en vez de con una imagen: pesa cero
// bytes, se ve nítida a cualquier tamaño y no hace falta un PNG por pantalla.
import 'package:flutter/material.dart';

import '../core/theme.dart';

class FlyraAvatar extends StatelessWidget {
  const FlyraAvatar({super.key, this.size = 48, this.semanticLabel});

  final double size;

  /// Texto que lee el lector de pantalla (personas ciegas). Si es null, la
  /// imagen se considera decoración y el lector la salta.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final Widget avatar = SizedBox.square(
      dimension: size,
      child: const DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[NomadColors.mint, NomadColors.group],
          ),
        ),
        child: CustomPaint(painter: _SwallowPainter()),
      ),
    );
    if (semanticLabel == null) return ExcludeSemantics(child: avatar);
    return Semantics(label: semanticLabel, image: true, child: avatar);
  }
}

/// Dibuja la golondrina. Las coordenadas van de 0 a 1 (fracciones del tamaño),
/// así el mismo dibujo sirve para un avatar de 24 o de 200 píxeles.
class _SwallowPainter extends CustomPainter {
  const _SwallowPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    Offset p(double x, double y) => Offset(x * w, y * h);

    final Path bird = Path()
      ..moveTo(p(0.72, 0.30).dx, p(0.72, 0.30).dy) // pico
      ..quadraticBezierTo(
        p(0.62, 0.30).dx,
        p(0.62, 0.30).dy,
        p(0.56, 0.38).dx,
        p(0.56, 0.38).dy,
      )
      // ala de arriba, larga y afilada
      ..quadraticBezierTo(
        p(0.40, 0.20).dx,
        p(0.40, 0.20).dy,
        p(0.18, 0.22).dx,
        p(0.18, 0.22).dy,
      )
      ..quadraticBezierTo(
        p(0.36, 0.34).dx,
        p(0.36, 0.34).dy,
        p(0.46, 0.48).dx,
        p(0.46, 0.48).dy,
      )
      // cola en tijera, lo que distingue a una golondrina
      ..lineTo(p(0.24, 0.78).dx, p(0.24, 0.78).dy)
      ..lineTo(p(0.42, 0.62).dx, p(0.42, 0.62).dy)
      ..lineTo(p(0.40, 0.82).dx, p(0.40, 0.82).dy)
      ..quadraticBezierTo(
        p(0.52, 0.64).dx,
        p(0.52, 0.64).dy,
        p(0.62, 0.56).dx,
        p(0.62, 0.56).dy,
      )
      // ala de abajo y vuelta a la cabeza
      ..quadraticBezierTo(
        p(0.80, 0.62).dx,
        p(0.80, 0.62).dy,
        p(0.86, 0.74).dx,
        p(0.86, 0.74).dy,
      )
      ..quadraticBezierTo(
        p(0.80, 0.50).dx,
        p(0.80, 0.50).dy,
        p(0.68, 0.42).dx,
        p(0.68, 0.42).dy,
      )
      ..quadraticBezierTo(
        p(0.74, 0.36).dx,
        p(0.74, 0.36).dy,
        p(0.72, 0.30).dx,
        p(0.72, 0.30).dy,
      )
      ..close();

    canvas.drawPath(bird, Paint()..color = NomadColors.background);
    // El ojo: un punto blanco que le da vida.
    canvas.drawCircle(p(0.66, 0.34), w * 0.022, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_SwallowPainter oldDelegate) => false;
}
