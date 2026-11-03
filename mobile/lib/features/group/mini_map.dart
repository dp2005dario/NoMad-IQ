// Un minimapa dibujado (pantalla Grupo): las chinchetas van en su sitio
// REAL (coordenadas de OpenStreetMap), sobre un fondo de calles dibujado.
// El fondo es decorativo (no son las calles de verdad); lo que importa, dónde
// está cada sitio respecto a ti, sí es real. Sin internet ni mapas de pago.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../map/geo.dart';

class MapPin {
  const MapPin({
    required this.at,
    required this.color,
    this.label,
    this.number,
    this.icon,
  });

  final GeoPoint at;
  final Color color;

  /// El nombre en una etiqueta encima ("Alfama").
  final String? label;

  /// El número dentro de la chincheta (el mismo que en la lista).
  final int? number;
  final IconData? icon;
}

class MiniMap extends StatelessWidget {
  const MiniMap({
    super.key,
    required this.center,
    required this.pins,
    this.radiusM = 1000,
    this.ring = false,
    this.youLabel,
    this.height = 190,
    this.badge,
  });

  final GeoPoint center;
  final List<MapPin> pins;

  /// Lo que cabe del centro al borde (en metros).
  final double radiusM;

  /// Dibujar el círculo de "a un paseo".
  final bool ring;

  /// "TÚ" en el centro (null = sin chincheta en el centro).
  final String? youLabel;
  final double height;

  /// Una etiqueta abajo a la izquierda ("Radio a pie · 1 km").
  final String? badge;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(18),
    child: SizedBox(
      height: height,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            // Las chinchetas "caen" una detrás de otra al aparecer.
            child: TweenAnimationBuilder<double>(
              key: ValueKey<int>(Object.hashAll(pins.map((MapPin p) => p.at))),
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (BuildContext context, double t, Widget? _) =>
                  CustomPaint(
                    painter: _MiniMapPainter(
                      center: center,
                      pins: pins,
                      radiusM: radiusM,
                      ring: ring,
                      youLabel: youLabel,
                      t: t,
                      // La letra de la app (si no, el lienzo usa otra).
                      font: DefaultTextStyle.of(context).style.fontFamily,
                    ),
                  ),
            ),
          ),
          if (badge != null)
            PositionedDirectional(
              start: 10,
              bottom: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: NomadColors.background.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: NomadColors.outline),
                ),
                child: Text(
                  badge!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class _MiniMapPainter extends CustomPainter {
  _MiniMapPainter({
    required this.center,
    required this.pins,
    required this.radiusM,
    required this.ring,
    required this.youLabel,
    required this.t,
    this.font,
  });

  final GeoPoint center;
  final List<MapPin> pins;
  final double radiusM;
  final bool ring;
  final String? youLabel;
  final double t;
  final String? font;

  Offset _project(GeoPoint p, Size size, double metersPerPx) {
    final double dx =
        (p.lon - center.lon) *
        math.cos(center.lat * math.pi / 180) *
        111320 /
        metersPerPx;
    final double dy = -(p.lat - center.lat) * 110540 / metersPerPx;
    return Offset(
      (size.width / 2 + dx).clamp(16, size.width - 16),
      (size.height / 2 + dy).clamp(22, size.height - 14),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Fondo: manzanas de una ciudad vista desde arriba (decorativo, fijo).
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF0E1A21),
    );
    final math.Random r = math.Random(11);
    const double block = 26;
    final Paint b = Paint();
    for (double y = -6; y < size.height; y += block + 6) {
      final double shift = r.nextDouble() * 10;
      for (double x = -6 + shift; x < size.width; x += block + 6) {
        final double v = r.nextDouble();
        b.color = v < 0.08
            ? const Color(0xFF16352A) // un parque
            : Color.lerp(
                const Color(0xFF15232B),
                const Color(0xFF1C2D36),
                r.nextDouble(),
              )!;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, block * (0.7 + v * 0.6), block),
            const Radius.circular(3),
          ),
          b,
        );
      }
    }
    // Dos avenidas en diagonal.
    final Paint avenue = Paint()
      ..color = const Color(0xFF2A3B45)
      ..strokeWidth = 5;
    canvas
      ..drawLine(
        Offset(0, size.height * 0.75),
        Offset(size.width, size.height * 0.2),
        avenue,
      )
      ..drawLine(
        Offset(size.width * 0.15, 0),
        Offset(size.width * 0.6, size.height),
        avenue,
      );

    // Sin círculo, el mapa se acerca a los sitios (que no salgan apiñados).
    double fit = radiusM;
    if (!ring && pins.isNotEmpty) {
      double far = 0;
      for (final MapPin p in pins) {
        final double dx =
            (p.at.lon - center.lon) *
            math.cos(center.lat * math.pi / 180) *
            111320;
        final double dy = (p.at.lat - center.lat) * 110540;
        far = math.max(far, math.sqrt(dx * dx + dy * dy));
      }
      fit = (far * 1.4).clamp(250, radiusM);
    }
    final double metersPerPx = fit * 1.15 / (size.shortestSide / 2);
    final Offset mid = Offset(size.width / 2, size.height / 2);
    if (ring) {
      final double rPx = radiusM / metersPerPx * t;
      canvas
        ..drawCircle(
          mid,
          rPx,
          Paint()..color = NomadColors.mint.withValues(alpha: 0.08),
        )
        ..drawCircle(
          mid,
          rPx,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = NomadColors.mint.withValues(alpha: 0.6),
        );
    }

    for (int i = 0; i < pins.length; i++) {
      // Cada chincheta cae un poco después de la anterior.
      final double start = (i * 0.12).clamp(0.0, 0.6);
      final double p = ((t - start) / (1 - start)).clamp(0.0, 1.0);
      if (p <= 0) continue;
      final MapPin pin = pins[i];
      final Offset at = _project(pin.at, size, metersPerPx);
      final Offset drop = at.translate(0, -18 * (1 - p));
      _pin(canvas, drop, pin, p);
    }

    if (youLabel != null) {
      canvas.drawCircle(mid, 9, Paint()..color = Colors.white);
      canvas.drawCircle(mid, 6, Paint()..color = NomadColors.mint);
      _label(canvas, mid.translate(0, -20), youLabel!, NomadColors.mint);
    }
  }

  void _pin(Canvas canvas, Offset at, MapPin pin, double p) {
    canvas.drawCircle(
      at.translate(0, 3),
      13,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas
      ..drawCircle(at, 13 * p, Paint()..color = Colors.white)
      ..drawCircle(at, 11 * p, Paint()..color = pin.color);
    final String? inside = pin.number?.toString();
    if (inside != null && p > 0.6) {
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: inside,
          style: TextStyle(
            fontFamily: font,
            color: NomadColors.background,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    } else if (pin.icon != null && p > 0.6) {
      final TextPainter tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(pin.icon!.codePoint),
          style: TextStyle(
            fontFamily: pin.icon!.fontFamily,
            package: pin.icon!.fontPackage,
            color: NomadColors.background,
            fontSize: 13,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at - Offset(tp.width / 2, tp.height / 2));
    }
    if (pin.label != null && p > 0.8) {
      // La etiqueta va debajo: arriba del centro está la de "TÚ".
      _label(canvas, at.translate(0, 25), pin.label!, pin.color);
    }
  }

  void _label(Canvas canvas, Offset at, String text, Color color) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: font,
          color: NomadColors.text,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 130);
    final Rect box = Rect.fromCenter(
      center: at,
      width: tp.width + 16,
      height: tp.height + 8,
    );
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(10)),
        Paint()..color = NomadColors.background.withValues(alpha: 0.9),
      )
      ..drawRRect(
        RRect.fromRectAndRadius(box, const Radius.circular(10)),
        Paint()
          ..style = PaintingStyle.stroke
          ..color = color,
      );
    tp.paint(canvas, box.topLeft + const Offset(8, 4));
  }

  @override
  bool shouldRepaint(_MiniMapPainter old) =>
      old.t != t || old.pins != pins || old.center != center;
}
