// La pestaña Cámara (el botón verde de abajo): primero la cámara normal, con
// el botón blanco (tocar = foto, mantener = vídeo) que lo guarda todo en tus
// Recuerdos. Deslizando a la derecha se pasa al escáner de monumentos (la
// cámara que reconoce lo que tienes delante y te da el sello); deslizando a
// la izquierda se vuelve.
//
// Solo una de las dos está encendida a la vez: el móvil no deja abrir la
// cámara dos veces.
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../memories/travel_camera_screen.dart';
import 'camera_screen.dart';

class CameraTab extends StatefulWidget {
  const CameraTab({super.key, this.scan = false});

  /// Abrir directamente el escáner (p. ej. desde el Pasaporte).
  final bool scan;

  @override
  State<CameraTab> createState() => _CameraTabState();
}

class _CameraTabState extends State<CameraTab> {
  late bool _scan = widget.scan;

  @override
  void didUpdateWidget(CameraTab old) {
    super.didUpdateWidget(old);
    if (widget.scan != old.scan) _scan = widget.scan;
  }

  void _go(bool scan) {
    if (scan != _scan) setState(() => _scan = scan);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Widget page = _scan
        ? Stack(
            fit: StackFit.expand,
            children: <Widget>[
              GestureDetector(
                // Deslizar a la izquierda (el dedo va hacia la izquierda).
                onHorizontalDragEnd: (DragEndDetails d) {
                  if ((d.primaryVelocity ?? 0) < -250) _go(false);
                },
                child: const CameraScreen(),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 6,
                child: SafeArea(
                  top: false,
                  child: Center(
                    child: Semantics(
                      button: true,
                      child: GestureDetector(
                        onTap: () => _go(false),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x990B1217),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              const Icon(
                                Icons.arrow_back_rounded,
                                size: 16,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  t.memSwipeCamera,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          )
        : TravelCameraScreen(onScanner: () => _go(true));
    // Un deslizamiento corto (solo transform y opacidad, sin tirones).
    return TweenAnimationBuilder<double>(
      key: ValueKey<bool>(_scan),
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (BuildContext context, double v, Widget? child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset((_scan ? -40 : 40) * (1 - v), 0),
          child: child,
        ),
      ),
      child: KeyedSubtree(key: ValueKey<String>('cam$_scan'), child: page),
    );
  }
}
