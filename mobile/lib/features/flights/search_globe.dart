// El GLOBO del buscador de vuelos (maqueta "Vuelos"): una bola del mundo
// que gira y apunta al aeropuerto que escribes. Pones MAD y se centra en
// España; pones HND y gira hasta Japón.
//
// Se dibuja "a mano" con un CustomPainter y los contornos que ya van dentro
// de la app (assets/geo/world.bin): sin internet y sin paquetes nuevos.
//
// Proyección "ortográfica": es cómo ves la Tierra desde el espacio, una
// bola con una sola cara a la vista. Analogía: un balón con el mapa
// pintado; lo giras con la mano hasta tener delante el país que buscas.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../route/geo.dart';
import '../route/world_data.dart';

/// Dónde cae un punto del planeta dentro del círculo del globo.
/// [x] e [y] van de -1 a 1 (0,0 = el centro del globo) y [front] dice si
/// el punto está en la cara que vemos (true) o por detrás (false).
({double x, double y, bool front}) projectOrtho(LatLon p, LatLon center) {
  final double lat = p.lat * math.pi / 180;
  final double lat0 = center.lat * math.pi / 180;
  final double dLon = (p.lon - center.lon) * math.pi / 180;
  final double x = math.cos(lat) * math.sin(dLon);
  final double y =
      math.cos(lat0) * math.sin(lat) -
      math.sin(lat0) * math.cos(lat) * math.cos(dLon);
  final double depth =
      math.sin(lat0) * math.sin(lat) +
      math.cos(lat0) * math.cos(lat) * math.cos(dLon);
  return (x: x, y: y, front: depth > 0);
}

class SearchGlobe extends StatefulWidget {
  const SearchGlobe({super.key, required this.world, this.from, this.to});

  final WorldData world;

  /// Los aeropuertos escritos (null si el código no existe todavía).
  final Airport? from;
  final Airport? to;

  @override
  State<SearchGlobe> createState() => _SearchGlobeState();
}

class _SearchGlobeState extends State<SearchGlobe>
    with SingleTickerProviderStateMixin {
  // Una sola animación que termina (no se repite): así los tests y el
  // móvil no se quedan "pintando para siempre" y gasta menos batería.
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  late LatLon _start = _target;
  late LatLon _end = _target;

  /// A dónde mira el globo: al destino; si no hay, al origen; si no, al
  /// Atlántico para que se vean Europa y América.
  LatLon get _target =>
      widget.to?.position ?? widget.from?.position ?? const LatLon(25, -20);

  LatLon get _now {
    final double t = Curves.easeInOutCubic.transform(_turn.value);
    // Se gira por el lado corto: de 170° a -170° son 20°, no 340°.
    double dLon = (_end.lon - _start.lon) % 360;
    if (dLon > 180) dLon -= 360;
    return LatLon(
      _start.lat + (_end.lat - _start.lat) * t,
      _start.lon + dLon * t,
    );
  }

  @override
  void didUpdateWidget(SearchGlobe old) {
    super.didUpdateWidget(old);
    final LatLon target = _target;
    if (target.lat == _end.lat && target.lon == _end.lon) return;
    _start = _now;
    _end = target;
    _turn.forward(from: 0);
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: AspectRatio(
      aspectRatio: 1,
      child: AnimatedBuilder(
        animation: _turn,
        builder: (BuildContext context, Widget? _) => CustomPaint(
          painter: GlobePainter(
            shapes: widget.world.shapes,
            center: _now,
            from: widget.from?.position,
            to: widget.to?.position,
          ),
        ),
      ),
    ),
  );
}

class GlobePainter extends CustomPainter {
  GlobePainter({
    required this.shapes,
    required this.center,
    this.from,
    this.to,
  });

  final WorldShapes shapes;
  final LatLon center;
  final LatLon? from;
  final LatLon? to;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = math.min(size.width, size.height) / 2 - 4;
    final Offset c = size.center(Offset.zero);
    Offset at(({double x, double y, bool front}) p) =>
        Offset(c.dx + p.x * r, c.dy - p.y * r);

    // El mar: un círculo azul oscuro con un borde suave.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.4),
          colors: <Color>[Color(0xFF1B3550), Color(0xFF0F1D2B)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // Los países, recortados al círculo. Los puntos de detrás se pegan al
    // borde: así el contorno no se rompe al girar.
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: r)));
    final Path land = Path();
    for (final Float32List ring in shapes.rings) {
      for (int i = 0; i < ring.length; i += 2) {
        final p = projectOrtho(LatLon(ring[i + 1], ring[i]), center);
        double x = p.x, y = p.y;
        if (!p.front) {
          final double len = math.sqrt(x * x + y * y);
          if (len > 0) {
            x /= len;
            y /= len;
          }
        }
        final Offset o = Offset(c.dx + x * r, c.dy - y * r);
        if (i == 0) {
          land.moveTo(o.dx, o.dy);
        } else {
          land.lineTo(o.dx, o.dy);
        }
      }
      land.close();
    }
    canvas.drawPath(land, Paint()..color = const Color(0xFF2C4A4A));
    canvas.restore();

    // La ruta (si hay origen y destino): una curva azul por delante.
    final LatLon? a = from, b = to;
    if (a != null && b != null && distanceKm(a, b) > 1) {
      final Path arc = Path();
      bool pen = false;
      for (int i = 0; i <= 48; i++) {
        final p = projectOrtho(intermediate(a, b, i / 48), center);
        if (!p.front) {
          pen = false;
          continue;
        }
        final Offset o = at(p);
        if (pen) {
          arc.lineTo(o.dx, o.dy);
        } else {
          arc.moveTo(o.dx, o.dy);
        }
        pen = true;
      }
      canvas.drawPath(
        arc,
        Paint()
          ..color = NomadColors.flights
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round,
      );
    }

    // Los puntos: azul el origen, menta el destino (con un halo).
    void dot(LatLon? place, Color color) {
      if (place == null) return;
      final p = projectOrtho(place, center);
      if (!p.front) return;
      final Offset o = at(p);
      canvas.drawCircle(o, 11, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawCircle(o, 5, Paint()..color = color);
    }

    dot(a, NomadColors.flights);
    dot(b, NomadColors.mint);

    // El borde del globo.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = NomadColors.outline,
    );
  }

  @override
  bool shouldRepaint(GlobePainter old) =>
      old.center.lat != center.lat ||
      old.center.lon != center.lon ||
      old.from != from ||
      old.to != to ||
      !identical(old.shapes, shapes);
}
