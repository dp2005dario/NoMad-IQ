// Clima del mapa (maqueta v7): Sol, Nubes o Lluvia. Es un adorno visual que
// se dibuja ENCIMA del mapa (no cambia el mapa ni usa internet): nubes que
// se mueven con su sombra, o gotas de lluvia cayendo. No toca la pantalla
// (IgnorePointer): el mapa se sigue pudiendo mover y tocar.
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum MapWeather { sun, clouds, rain }

class WeatherOverlay extends StatefulWidget {
  const WeatherOverlay({super.key, required this.weather});

  final MapWeather weather;

  @override
  State<WeatherOverlay> createState() => _WeatherOverlayState();
}

class _WeatherOverlayState extends State<WeatherOverlay>
    with SingleTickerProviderStateMixin {
  // Una vuelta cada 20 s; el pintor usa el valor 0..1 para mover las cosas.
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(WeatherOverlay old) {
    super.didUpdateWidget(old);
    _sync();
  }

  /// Con Sol no hace falta animar nada (ahorra batería).
  void _sync() {
    if (widget.weather == MapWeather.sun) {
      _loop.stop();
    } else if (!_loop.isAnimating) {
      _loop.repeat();
    }
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _loop,
        builder: (BuildContext context, Widget? _) => CustomPaint(
          size: Size.infinite,
          painter: WeatherPainter(widget.weather, _loop.value),
        ),
      ),
    ),
  );
}

/// Dibuja el clima. [t] va de 0 a 1 y se repite.
class WeatherPainter extends CustomPainter {
  WeatherPainter(this.weather, this.t);

  final MapWeather weather;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    switch (weather) {
      case MapWeather.sun:
        // Un resplandor cálido arriba a la derecha.
        final Rect r = Rect.fromCircle(
          center: Offset(size.width * 0.85, size.height * 0.05),
          radius: size.shortestSide * 0.7,
        );
        canvas.drawRect(
          r,
          Paint()
            ..shader = RadialGradient(
              colors: <Color>[const Color(0x55FFD36B), const Color(0x00FFD36B)],
            ).createShader(r),
        );
      case MapWeather.clouds:
        _clouds(canvas, size, 0.18);
      case MapWeather.rain:
        _clouds(canvas, size, 0.30);
        _rain(canvas, size);
    }
  }

  /// Nubes blandas que cruzan la pantalla, cada una con su sombra en el suelo.
  void _clouds(Canvas canvas, Size size, double darkness) {
    final math.Random rnd = math.Random(7); // siempre las mismas posiciones
    for (int i = 0; i < 6; i++) {
      final double speed = 0.6 + rnd.nextDouble() * 0.8;
      final double w = size.width * (0.35 + rnd.nextDouble() * 0.3);
      final double x = ((rnd.nextDouble() + t * speed) % 1.3) * size.width - w;
      final double y = size.height * (0.05 + rnd.nextDouble() * 0.8);
      final Rect cloud = Rect.fromCenter(
        center: Offset(x + w / 2, y),
        width: w,
        height: w * 0.35,
      );
      // La sombra va desplazada hacia abajo-derecha.
      canvas.drawOval(
        cloud.shift(Offset(w * 0.15, w * 0.25)),
        Paint()..color = Colors.black.withValues(alpha: 0.10),
      );
      canvas.drawOval(
        cloud,
        Paint()..color = Colors.white.withValues(alpha: darkness),
      );
    }
  }

  /// Gotas: rayitas inclinadas que caen y vuelven a empezar arriba.
  void _rain(Canvas canvas, Size size) {
    final math.Random rnd = math.Random(3);
    final Paint drop = Paint()
      ..color = const Color(0xAAB8D4F0)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 90; i++) {
      final double x0 = rnd.nextDouble() * size.width;
      final double speed = 2.5 + rnd.nextDouble() * 2; // vueltas por ciclo
      final double y = ((rnd.nextDouble() + t * speed) % 1.0) * size.height;
      canvas.drawLine(Offset(x0, y), Offset(x0 - 4, y + 14), drop);
    }
  }

  @override
  bool shouldRepaint(WeatherPainter old) =>
      old.t != t || old.weather != weather;
}
