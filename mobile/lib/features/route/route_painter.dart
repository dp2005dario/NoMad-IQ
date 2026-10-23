// El dibujo del mapa de la Ruta del vuelo: países, la ruta del avión, los dos
// aeropuertos y el avión. Se pinta "a mano" con un CustomPainter (sin
// servidores de mapas): rápido, sin conexión y con nuestros colores.
//
// Proyección "equirrectangular": la longitud es la X y la latitud la Y, como
// en un mapamundi de colegio. Es la más sencilla y para ver una ruta basta.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../core/theme.dart';
import 'geo.dart';
import 'world_data.dart';

/// Dónde mira la cámara: el centro del mapa (en grados) y el zoom. Con
/// zoom 1 cabe el mundo entero (360°) a lo ancho de la pantalla.
class MapCamera {
  const MapCamera(this.center, this.zoom);

  final LatLon center;
  final double zoom;

  /// Un punto intermedio entre dos cámaras (para animar el movimiento). El
  /// zoom se mezcla "en logaritmos": así acercarse se ve a ritmo constante.
  static MapCamera lerp(MapCamera a, MapCamera b, double t) => MapCamera(
    LatLon(
      a.center.lat + (b.center.lat - a.center.lat) * t,
      a.center.lon + (b.center.lon - a.center.lon) * t,
    ),
    math.exp(math.log(a.zoom) + (math.log(b.zoom) - math.log(a.zoom)) * t),
  );

  /// Píxeles por grado para una pantalla de [width] de ancho.
  double scale(double width) => width / 360 * zoom;

  /// De coordenadas del planeta a la pantalla.
  Offset toScreen(LatLon p, Size size) {
    final double s = scale(size.width);
    return Offset(
      size.width / 2 + (p.lon - center.lon) * s,
      size.height / 2 - (p.lat - center.lat) * s,
    );
  }
}

/// La silueta de los países se convierte en un Path una sola vez y se
/// reutiliza en cada fotograma (son ~125.000 puntos).
class _LandCache {
  static WorldShapes? _for;
  static Path? _path;

  static Path of(WorldShapes shapes) {
    if (identical(_for, shapes) && _path != null) return _path!;
    final Path path = Path();
    for (final Float32List ring in shapes.rings) {
      path.moveTo(ring[0], -ring[1]);
      for (int i = 2; i < ring.length; i += 2) {
        path.lineTo(ring[i], -ring[i + 1]);
      }
      path.close();
    }
    _for = shapes;
    _path = path;
    return path;
  }
}

class RoutePainter extends CustomPainter {
  RoutePainter({
    required this.shapes,
    required this.camera,
    required this.route,
    required this.progress,
    required this.pulse,
    required this.showPlane,
  });

  final WorldShapes shapes;
  final MapCamera camera;

  /// El camino del avión (círculo máximo, longitudes desenrolladas).
  final List<LatLon> route;

  /// Cuánto lleva recorrido (0 a 1).
  final double progress;

  /// 0 a 1 en bucle: el "latido" de los puntos de origen y destino.
  final double pulse;
  final bool showPlane;

  static const Color _ocean = Color(0xFF0A1824);
  static const Color _land = Color(0xFF1B2B35);
  static const Color _border = Color(0xFF2C4250);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset.zero,
          Offset(0, size.height),
          const <Color>[Color(0xFF0E2236), _ocean],
        ),
    );
    final double s = camera.scale(size.width);
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(s, s);
    canvas.translate(-camera.center.lon, camera.center.lat);
    _graticule(canvas, s);
    final Path land = _LandCache.of(shapes);
    final Paint fill = Paint()..color = _land;
    final Paint border = Paint()
      ..color = _border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8 / s;
    // El mundo se repite a izquierda y derecha: así una ruta que cruza el
    // Pacífico (Tokio → Los Ángeles) se ve entera.
    final double halfWidthDeg = size.width / 2 / s;
    for (int k = -1; k <= 1; k++) {
      final double dx = k * 360.0;
      if (dx - 180 > camera.center.lon + halfWidthDeg ||
          dx + 180 < camera.center.lon - halfWidthDeg) {
        continue;
      }
      canvas.save();
      canvas.translate(dx, 0);
      canvas.drawPath(land, fill);
      canvas.drawPath(land, border);
      canvas.restore();
    }
    canvas.restore();
    _route(canvas, size, s);
  }

  void _graticule(Canvas canvas, double s) {
    final Paint p = Paint()
      ..color = const Color(0x14FFFFFF)
      ..strokeWidth = 0.6 / s;
    for (int lon = -540; lon <= 540; lon += 30) {
      canvas.drawLine(
        Offset(lon.toDouble(), -90),
        Offset(lon.toDouble(), 90),
        p,
      );
    }
    for (int lat = -60; lat <= 60; lat += 30) {
      canvas.drawLine(
        Offset(-540, -lat.toDouble()),
        Offset(540, -lat.toDouble()),
        p,
      );
    }
  }

  /// El punto de la ruta a una fracción f (interpolando entre los puntos).
  static LatLon pointAt(List<LatLon> route, double f) {
    final double x = f.clamp(0.0, 1.0) * (route.length - 1);
    final int i = x.floor().clamp(0, route.length - 2);
    final double t = x - i;
    final LatLon a = route[i], b = route[i + 1];
    return LatLon(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t);
  }

  void _route(Canvas canvas, Size size, double s) {
    final List<Offset> pts = <Offset>[
      for (final LatLon p in route) camera.toScreen(p, size),
    ];
    // La ruta entera, discontinua y tenue.
    final Paint dashed = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (int i = 0; i < pts.length - 1; i += 2) {
      canvas.drawLine(pts[i], pts[i + 1], dashed);
    }
    // Lo recorrido: azul de Vuelos, con un brillo debajo.
    final int done = (progress * (pts.length - 1)).floor();
    if (progress > 0) {
      final Path flown = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (int i = 1; i <= done; i++) {
        flown.lineTo(pts[i].dx, pts[i].dy);
      }
      final Offset here = camera.toScreen(pointAt(route, progress), size);
      flown.lineTo(here.dx, here.dy);
      canvas.drawPath(
        flown,
        Paint()
          ..color = NomadColors.flights.withValues(alpha: 0.35)
          ..strokeWidth = 8
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
      canvas.drawPath(
        flown,
        Paint()
          ..color = NomadColors.flights
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );
    }
    _airport(canvas, pts.first, NomadColors.mint);
    _airport(canvas, pts.last, NomadColors.flights);
    if (showPlane) _plane(canvas, size);
  }

  void _airport(Canvas canvas, Offset at, Color color) {
    final double r = 6 + 16 * pulse;
    canvas.drawCircle(
      at,
      r,
      Paint()..color = color.withValues(alpha: 0.5 * (1 - pulse)),
    );
    canvas.drawCircle(at, 7, Paint()..color = const Color(0xFF0B1217));
    canvas.drawCircle(at, 5, Paint()..color = color);
  }

  /// El avión visto desde arriba, con sombra, girado hacia donde va.
  void _plane(Canvas canvas, Size size) {
    // La dirección sale de un poco antes y un poco después del avión.
    final Offset at = camera.toScreen(pointAt(route, progress), size);
    final Offset from = camera.toScreen(
      pointAt(route, math.max(0, progress - 0.005)),
      size,
    );
    final Offset to = camera.toScreen(
      pointAt(route, math.min(1, progress + 0.005)),
      size,
    );
    final double angle = math.atan2(to.dy - from.dy, to.dx - from.dx);
    final double len = 34;
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    final Path body = planeSilhouette(len);
    // Sombra en el suelo, desplazada: da sensación de altura.
    canvas.save();
    canvas.translate(6, 10);
    canvas.drawPath(
      body,
      Paint()
        ..color = const Color(0x88000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.restore();
    canvas.drawPath(
      body,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, -len / 2),
          Offset(0, len / 2),
          const <Color>[Color(0xFFFFFFFF), Color(0xFFC9D6E3)],
        ),
    );
    // Franja azul del fuselaje y motores.
    canvas.drawRect(
      Rect.fromLTWH(-len * 0.30, -len * 0.035, len * 0.62, len * 0.07),
      Paint()..color = NomadColors.flights,
    );
    final Paint engine = Paint()..color = const Color(0xFF8FA3B5);
    for (final double side in <double>[-1, 1]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(len * 0.02, side * len * 0.20),
            width: len * 0.14,
            height: len * 0.07,
          ),
          Radius.circular(len * 0.03),
        ),
        engine,
      );
    }
    canvas.restore();
  }

  /// Silueta de un avión de pasajeros mirando a la derecha (eje X), centrada.
  static Path planeSilhouette(double len) {
    final double l = len / 2;
    final double w = len * 0.06; // medio ancho del fuselaje
    return Path()
      // Morro
      ..moveTo(l, 0)
      ..quadraticBezierTo(l * 0.92, -w, l * 0.70, -w)
      // Ala izquierda (arriba en pantalla)
      ..lineTo(l * 0.20, -w)
      ..lineTo(-l * 0.25, -l * 0.95)
      ..lineTo(-l * 0.40, -l * 0.95)
      ..lineTo(-l * 0.15, -w)
      // Cola
      ..lineTo(-l * 0.75, -w)
      ..lineTo(-l * 0.95, -l * 0.38)
      ..lineTo(-l * 1.02, -l * 0.38)
      ..lineTo(-l * 0.92, -w * 0.4)
      ..lineTo(-l * 1.0, 0)
      ..lineTo(-l * 0.92, w * 0.4)
      ..lineTo(-l * 1.02, l * 0.38)
      ..lineTo(-l * 0.95, l * 0.38)
      ..lineTo(-l * 0.75, w)
      // Ala derecha
      ..lineTo(-l * 0.15, w)
      ..lineTo(-l * 0.40, l * 0.95)
      ..lineTo(-l * 0.25, l * 0.95)
      ..lineTo(l * 0.20, w)
      ..lineTo(l * 0.70, w)
      ..quadraticBezierTo(l * 0.92, w, l, 0)
      ..close();
  }

  @override
  bool shouldRepaint(RoutePainter old) =>
      old.camera != camera ||
      old.progress != progress ||
      old.pulse != pulse ||
      old.showPlane != showPlane ||
      !identical(old.route, route) ||
      !identical(old.shapes, shapes);
}
