// El reproductor de la audioguía. Como con el mapa, la pantalla usa esta
// pequeña "interfaz" y no el paquete just_audio directamente: el audio de
// verdad necesita el móvil, y en los tests se usa un reproductor falso.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Una foto del reproductor en este instante.
@immutable
class Playback {
  const Playback({
    this.part = 0,
    this.position = Duration.zero,
    this.playing = false,
    this.loading = false,
    this.completed = false,
    this.failed = false,
  });

  /// Parte que suena (0 = la primera).
  final int part;

  /// Posición dentro de esa parte.
  final Duration position;
  final bool playing;
  final bool loading;

  /// Terminó la última parte.
  final bool completed;

  /// Un archivo no se pudo reproducir (sin red, o se retiró: 410).
  final bool failed;

  Playback copyWith({
    int? part,
    Duration? position,
    bool? playing,
    bool? loading,
    bool? completed,
    bool? failed,
  }) => Playback(
    part: part ?? this.part,
    position: position ?? this.position,
    playing: playing ?? this.playing,
    loading: loading ?? this.loading,
    completed: completed ?? this.completed,
    failed: failed ?? this.failed,
  );
}

abstract interface class GuidePlayer {
  ValueListenable<Playback> get playback;

  /// Prepara la lista de partes (una URL por parte), sin empezar a sonar.
  Future<void> load(List<Uri> parts, {int part = 0, Duration? position});
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position, {int? part});

  /// Velocidad: 1.0 normal, 1.5 más rápido...
  Future<void> setSpeed(double speed);
  Future<void> dispose();
}

typedef GuidePlayerFactory = GuidePlayer Function();

/// El reproductor de verdad. En Android usa ExoPlayer, que reproduce los
/// .opus del servidor sin problema.
class JustAudioGuidePlayer implements GuidePlayer {
  JustAudioGuidePlayer() {
    _subs.addAll(<StreamSubscription<Object?>>[
      _player.currentIndexStream.listen((int? i) {
        if (i != null) _update(_value.copyWith(part: i));
      }),
      // La posición se refresca 5 veces por segundo: suficiente para la
      // barra de progreso sin gastar batería de más.
      _player
          .createPositionStream(
            minPeriod: const Duration(milliseconds: 200),
            maxPeriod: const Duration(milliseconds: 200),
          )
          .listen((Duration p) => _update(_value.copyWith(position: p))),
      _player.playerStateStream.listen((PlayerState s) {
        final ProcessingState ps = s.processingState;
        _update(
          _value.copyWith(
            playing: s.playing && ps != ProcessingState.completed,
            loading:
                ps == ProcessingState.loading ||
                ps == ProcessingState.buffering,
            completed: ps == ProcessingState.completed,
          ),
        );
      }),
      _player.errorStream.listen(
        (PlayerException _) =>
            _update(_value.copyWith(failed: true, playing: false)),
      ),
    ]);
  }

  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  final ValueNotifier<Playback> _state = ValueNotifier<Playback>(
    const Playback(),
  );

  Playback get _value => _state.value;
  void _update(Playback p) => _state.value = p;

  @override
  ValueListenable<Playback> get playback => _state;

  @override
  Future<void> load(List<Uri> parts, {int part = 0, Duration? position}) async {
    _update(Playback(part: part, position: position ?? Duration.zero));
    try {
      await _player.setAudioSources(
        <AudioSource>[for (final Uri url in parts) AudioSource.uri(url)],
        initialIndex: part,
        initialPosition: position,
      );
    } on PlayerException {
      _update(_value.copyWith(failed: true));
    } on PlayerInterruptedException {
      // Se pidió otra carga antes de terminar esta: no es un error.
    }
  }

  @override
  Future<void> play() async {
    // Si ya había terminado, "play" vuelve a empezar desde el principio.
    if (_value.completed) await _player.seek(Duration.zero, index: 0);
    unawaited(_player.play()); // play() solo termina cuando acaba el audio
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position, {int? part}) =>
      _player.seek(position, index: part);

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  @override
  Future<void> dispose() async {
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    await _player.dispose();
    _state.dispose();
  }
}
