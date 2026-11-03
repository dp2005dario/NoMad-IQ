// Las animaciones "de adorno" que no se acaban (como en la maqueta: Flyra
// que respira, las estrellas, la tarjeta que flota...).
//
// Para no gastar batería:
// - Flutter ya las para solo cuando otra pantalla las tapa o la app está en
//   segundo plano.
// - [OnScreenOnly] las para cuando su trozo de pantalla sale de la vista al
//   hacer scroll.
// - Con "reducir movimiento" (ajuste del móvil) no se mueven.
import 'dart:async';

import 'package:flutter/material.dart';

class Motion {
  /// true en la app: las animaciones de adorno no se acaban.
  ///
  /// Las pruebas lo ponen a false (test/flutter_test_config.dart): si no,
  /// "esperar a que todo se quede quieto" esperaría para siempre.
  static bool forever = true;

  /// Repite [c] sin fin (en las pruebas, solo [testCount] veces).
  static void loop(
    AnimationController c, {
    bool reverse = false,
    int testCount = 2,
  }) {
    unawaited(
      forever
          ? c.repeat(reverse: reverse)
          : c.repeat(reverse: reverse, count: testCount),
    );
  }
}

/// Para las animaciones de [child] mientras no se ve en la pantalla (por
/// ejemplo, Flyra cuando bajas en Inicio). Al volver a verse, siguen.
class OnScreenOnly extends StatefulWidget {
  const OnScreenOnly({super.key, required this.child});

  final Widget child;

  @override
  State<OnScreenOnly> createState() => _OnScreenOnlyState();
}

class _OnScreenOnlyState extends State<OnScreenOnly> {
  ScrollPosition? _position;
  bool _visible = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ScrollPosition? p = Scrollable.maybeOf(context)?.position;
    if (p != _position) {
      _position?.removeListener(_check);
      _position = p?..addListener(_check);
    }
  }

  @override
  void dispose() {
    _position?.removeListener(_check);
    super.dispose();
  }

  /// ¿Algún trozo de este widget está dentro de la pantalla?
  void _check() {
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    final double top = box.localToGlobal(Offset.zero).dy;
    final double screen = MediaQuery.sizeOf(context).height;
    final bool visible = top < screen && top + box.size.height > 0;
    if (visible != _visible) setState(() => _visible = visible);
  }

  @override
  Widget build(BuildContext context) =>
      TickerMode(enabled: _visible, child: widget.child);
}
