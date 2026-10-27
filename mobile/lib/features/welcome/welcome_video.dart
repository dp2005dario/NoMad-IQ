// El vídeo de fondo de la Bienvenida. Como con el mapa y el reproductor de
// audioguías, la pantalla usa esta pequeña "interfaz" y no el paquete
// video_player directamente: reproducir vídeo de verdad necesita un móvil, y
// en los tests se usa uno falso (ver FakeWelcomeVideo en test/helpers.dart).
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

abstract interface class WelcomeVideo {
  /// Pasa a `true` cuando el vídeo ya se está viendo. Si falla, se queda en
  /// `false` y la pantalla enseña su fondo oscuro de siempre.
  ValueListenable<bool> get ready;

  /// El vídeo dibujado para cubrir toda la pantalla.
  Widget buildView();

  /// Silencia (o devuelve) la música del vídeo.
  Future<void> setMuted(bool muted);

  Future<void> dispose();
}

/// Cómo crea la app un vídeo nuevo cada vez que se abre la Bienvenida.
typedef WelcomeVideoFactory = WelcomeVideo Function();

/// El vídeo de verdad: el archivo que va dentro de la app, en bucle.
class AssetWelcomeVideo implements WelcomeVideo {
  AssetWelcomeVideo() {
    // mixWithOthers: si ya suena música en el móvil, no la corta.
    _controller = VideoPlayerController.asset(
      'assets/video/bienvenida.mp4',
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _start();
  }

  // Volumen moderado: es música de ambiente, no el protagonista.
  static const double _volume = 0.35;

  late final VideoPlayerController _controller;
  final ValueNotifier<bool> _ready = ValueNotifier<bool>(false);
  bool _disposed = false;

  @override
  ValueListenable<bool> get ready => _ready;

  Future<void> _start() async {
    try {
      await _controller.initialize();
      if (_disposed) return;
      await _controller.setLooping(true);
      await _controller.setVolume(_volume);
      await _controller.play();
      if (!_disposed) _ready.value = true;
    } catch (_) {
      // Sin vídeo no pasa nada: se queda el fondo oscuro estático.
    }
  }

  @override
  Widget buildView() {
    final Size size = _controller.value.size;
    // FittedBox con "cover": llena la pantalla recortando lo que sobre.
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: VideoPlayer(_controller),
      ),
    );
  }

  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _controller.setVolume(muted ? 0 : _volume);
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _ready.dispose();
    await _controller.dispose();
  }
}
