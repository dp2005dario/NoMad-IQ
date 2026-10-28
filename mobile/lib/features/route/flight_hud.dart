// El "HUD" del vuelo (como la barra de arriba de la maqueta "En vuelo"):
// MAD ——✈—— HND, con el avioncito avanzando por la barra, y debajo
// dos casillas con los km recorridos y el tiempo que queda.
//
// Analogía: es el cartelito de la pantalla del asiento del avión. Solo
// enseña datos reales de la ruta (no se inventa altitud ni velocidad).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme.dart';

class FlightHud extends StatelessWidget {
  const FlightHud({
    super.key,
    required this.fromCode,
    required this.toCode,
    required this.progress,
    required this.traveled,
    required this.remaining,
  });

  /// Códigos IATA ("MAD", "HND").
  final String fromCode;
  final String toCode;

  /// De 0 (despegue) a 1 (aterrizaje).
  final double progress;

  /// Textos ya traducidos: "Recorrido: 540 km" y "Quedan 12 h".
  final String traveled;
  final String remaining;

  static const TextStyle _code = TextStyle(
    fontWeight: FontWeight.w800,
    fontSize: 18,
    letterSpacing: 0.5,
  );

  @override
  Widget build(BuildContext context) {
    final double done = progress.clamp(0.0, 1.0);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(fromCode, style: _code),
            const SizedBox(width: 10),
            Expanded(child: _Track(progress: done)),
            const SizedBox(width: 10),
            Text(toCode, style: _code),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(child: _Stat(text: traveled)),
            const SizedBox(width: 8),
            Expanded(child: _Stat(text: remaining)),
          ],
        ),
      ],
    );
  }
}

/// La barra con el avión encima. El avión mide 24 de ancho y no se sale
/// de la barra (por eso se resta 24 al ancho disponible).
class _Track extends StatelessWidget {
  const _Track({required this.progress});

  final double progress;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 28,
    child: LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double x = (box.maxWidth - 24) * progress;
        return Stack(
          alignment: Alignment.centerLeft,
          children: <Widget>[
            Container(
              height: 4,
              decoration: BoxDecoration(
                color: NomadColors.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Container(
              width: x + 12,
              height: 4,
              decoration: BoxDecoration(
                color: NomadColors.flights,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Positioned(
              left: x,
              child: Transform.rotate(
                // El icono mira arriba: se gira 90° para ir a la derecha.
                angle: math.pi / 2,
                child: const Icon(
                  Icons.flight_rounded,
                  size: 24,
                  color: NomadColors.flights,
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: NomadColors.background.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
      ),
    ),
  );
}
