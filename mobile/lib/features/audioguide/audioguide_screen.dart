// La pantalla de la audioguía de una zona (maqueta 4): el guion por partes,
// el reproductor con el círculo verde que se desliza para avanzar o
// retroceder, y el texto de lo que suena (útil con ruido o sin cascos).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../../core/api_client.dart';
import '../../core/languages.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../offline/saved_guides.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import 'audioguide_api.dart';
import 'guide_player.dart';

/// En qué punto está la carga.
enum _Stage { loading, preparing, ready, failed }

class AudioguideScreen extends StatefulWidget {
  const AudioguideScreen({
    super.key,
    required this.zoneId,
    required this.zoneName,
    this.retryEvery = const Duration(seconds: 5),
  });

  final String zoneId;
  final String zoneName;

  /// Si el guion aún se está escribiendo, cada cuánto se vuelve a preguntar.
  final Duration retryEvery;

  @override
  State<AudioguideScreen> createState() => _AudioguideScreenState();
}

class _AudioguideScreenState extends State<AudioguideScreen> {
  late AppServices _services;
  late String _language;
  bool _started = false;

  _Stage _stage = _Stage.loading;
  ApiError? _error;
  GuideScript? _script;
  AudioManifest? _audio;
  GuidePlayer? _player;
  Timer? _retry;
  int _attempts = 0;
  bool _reloadedAudio = false;

  /// true si lo que se está oyendo es la copia guardada en el móvil (la
  /// descargó "Sin conexión"): se avisa con una etiqueta.
  bool _fromPhone = false;

  /// Velocidades que se van alternando al pulsar el botón "1×".
  static const List<double> _speeds = <double>[1, 1.25, 1.5, 0.75];
  int _speed = 0;

  /// Mientras arrastras el círculo verde: cuántos segundos vas a saltar.
  double? _seekDelta;

  /// En el PRIMER intento se espera hasta 1 minuto a que Flyra prepare
  /// el guion (6 reintentos de 5 s). Después, botón "Reintentar".
  static const int _maxAttempts = 6;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _services = ServicesScope.of(context);
    _language = Localizations.localeOf(context).languageCode;
    unawaited(_load());
  }

  @override
  void dispose() {
    _retry?.cancel();
    _player?.playback.removeListener(_onPlayback);
    unawaited(_player?.dispose());
    super.dispose();
  }

  // --- Carga -----------------------------------------------------------------

  Future<void> _load() async {
    _retry?.cancel();
    setState(() {
      // Mientras se espera a Flyra se sigue enseñando "preparando".
      if (_stage != _Stage.preparing) _stage = _Stage.loading;
      _error = null;
    });
    try {
      final GuideScript script = await _services.audioguides.script(
        widget.zoneId,
        _language,
      );
      if (!mounted) return;
      _script = script;
      _stage = _Stage.ready;
      setState(() {});
      await _loadAudio();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.error == ApiError.notFound && _attempts < _maxAttempts) {
        // Aún no está: el servidor la escribe en cuanto alguien entra en la
        // zona. Se vuelve a preguntar en unos segundos.
        _attempts++;
        setState(() => _stage = _Stage.preparing);
        _retry = Timer(widget.retryEvery, () => unawaited(_load()));
        return;
      }
      // Antes de rendirse: ¿está descargada en el móvil? Si la bajaste con
      // "Sin conexión", funciona igual en modo avión.
      if (await _loadSaved()) return;
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _error = e.error;
      });
    }
  }

  /// Abre la copia guardada en el móvil. Devuelve true si la había.
  Future<bool> _loadSaved() async {
    final SavedGuide? saved = await _services.saved.of(
      widget.zoneId,
      _language,
    );
    if (saved == null || !mounted) return false;
    _retry?.cancel();
    _script = saved.script;
    _stage = _Stage.ready;
    _fromPhone = true;
    setState(() {});
    final AudioManifest? audio = saved.audio;
    if (audio != null) await _play(audio);
    return true;
  }

  Future<void> _loadAudio() async {
    try {
      final AudioManifest audio = await _services.audioguides.audio(
        widget.zoneId,
        _language,
      );
      if (!mounted) return;
      await _play(audio);
    } on ApiException {
      // Sin audio del servidor: si lo tienes descargado, se oye ese.
      final SavedGuide? saved = await _services.saved.of(
        widget.zoneId,
        _language,
      );
      final AudioManifest? phone = saved?.audio;
      if (phone != null && mounted) {
        _fromPhone = true;
        await _play(phone);
        return;
      }
      // Y si tampoco, se puede leer el texto.
      if (mounted) setState(() => _audio = null);
    }
  }

  /// Carga el audio en el reproductor (venga del servidor o del móvil).
  Future<void> _play(AudioManifest audio) async {
    try {
      final Playback? before = _player?.playback.value;
      GuidePlayer? player = _player;
      if (player == null) {
        player = _services.newPlayer();
        player.playback.addListener(_onPlayback);
        _player = player;
      }
      _audio = audio;
      setState(() {});
      final AppLocalizations t = AppLocalizations.of(context);
      final int n = audio.parts.length;
      final String? guideTitle = _script?.title;
      // Si es una recarga (el audio viejo se retiró), se sigue donde ibas.
      await player.load(
        <Uri>[for (final AudioPart p in audio.parts) p.url],
        part: before == null ? 0 : before.part.clamp(0, n - 1),
        position: before?.position,
        info: NowPlaying(
          album: _script?.zoneName ?? widget.zoneName,
          titles: <String>[
            for (int i = 0; i < n; i++)
              <String?>[
                t.guidePartOf(i + 1, n),
                guideTitle,
              ].whereType<String>().join(' · '),
          ],
        ),
      );
      await player.setSpeed(_speeds[_speed]);
    } on ApiException {
      if (mounted) setState(() => _audio = null);
    }
  }

  void _onPlayback() {
    final Playback p = _player!.playback.value;
    // Un archivo falló: puede que se retirara (410) porque hay versión
    // nueva. Se pide el manifiesto otra vez, UNA vez.
    if (p.failed && !_reloadedAudio) {
      _reloadedAudio = true;
      unawaited(_loadAudio());
    }
    if (mounted) setState(() {});
  }

  // --- Acciones del reproductor --------------------------------------------

  Duration _partLength(int part) {
    final List<AudioPart> parts = _audio?.parts ?? const <AudioPart>[];
    return part < parts.length ? parts[part].duration : Duration.zero;
  }

  void _toggle() {
    final GuidePlayer? player = _player;
    if (player == null) return;
    unawaited(player.playback.value.playing ? player.pause() : player.play());
  }

  void _seekBy(Duration delta) {
    final GuidePlayer? player = _player;
    if (player == null) return;
    final Playback p = player.playback.value;
    final Duration length = _partLength(p.part);
    Duration target = p.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > length) target = length;
    unawaited(player.seek(target, part: p.part));
  }

  void _goPart(int part) {
    final int count = _audio?.parts.length ?? 0;
    if (part < 0 || part >= count) return;
    unawaited(_player?.seek(Duration.zero, part: part));
  }

  void _cycleSpeed() {
    setState(() => _speed = (_speed + 1) % _speeds.length);
    unawaited(_player?.setSpeed(_speeds[_speed]));
  }

  // --- Dibujo ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final GuideScript? script = _script;
    final String title = script?.zoneName ?? widget.zoneName;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.shortcutAudioguides),
        actions: <Widget>[
          if (_audio != null)
            TextButton(
              onPressed: _cycleSpeed,
              child: Text(
                t.guideSpeed(_speedLabel(context, _speeds[_speed])),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: switch (_stage) {
          _Stage.loading => const Center(child: CircularProgressIndicator()),
          _Stage.preparing => _Message(text: t.guidePreparing, busy: true),
          _Stage.failed => _failure(t),
          _Stage.ready => _ready(t, title, script!),
        },
      ),
    );
  }

  Widget _failure(AppLocalizations t) {
    if (_error == ApiError.signedOut) {
      return _Message(
        text: t.guideSignIn,
        action: t.signInFromGuest,
        onAction: () => unawaited(context.push(Routes.signIn)),
      );
    }
    return _Message(
      text: switch (_error) {
        ApiError.network => t.errorNetwork,
        ApiError.rateLimited => t.errorRateLimited,
        ApiError.notFound => t.guidePreparingSlow,
        _ => t.errorUnavailable,
      },
      action: t.guideRetry,
      onAction: () {
        _attempts = 0;
        unawaited(_load());
      },
    );
  }

  Widget _ready(AppLocalizations t, String title, GuideScript script) {
    final AudioManifest? audio = _audio;
    final Playback? p = _player?.playback.value;
    final TextTheme text = Theme.of(context).textTheme;
    final String? otherLanguage = script.contentLanguage != _language
        ? endonymFor(script.contentLanguage)
        : null;
    final int partCount = audio?.parts.length ?? script.segments.length;
    final int part = (p?.part ?? 0).clamp(0, partCount - 1);
    final String partText = audio != null
        ? audio.parts[part].text
        : script.segments[part.clamp(0, script.segments.length - 1)].text;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: <Widget>[
        Text(
          // "SONANDO" solo mientras suena (como en la maqueta).
          (p?.playing ?? false) ? t.guideNowPlaying : '',
          style: const TextStyle(
            color: NomadColors.mint,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 6),
        Text(title, style: text.displaySmall),
        const SizedBox(height: 6),
        Text(
          script.title,
          style: text.bodyLarge?.copyWith(color: NomadColors.textMuted),
        ),
        if (otherLanguage != null) ...<Widget>[
          const SizedBox(height: 12),
          _Note(
            icon: Icons.translate_rounded,
            text: t.guideOtherLanguage(otherLanguage),
          ),
        ],
        if (_fromPhone) ...<Widget>[
          const SizedBox(height: 12),
          _Note(icon: Icons.download_done_rounded, text: t.offlineSaved),
        ],
        if (audio?.stale ?? false) ...<Widget>[
          const SizedBox(height: 12),
          _Note(icon: Icons.update_rounded, text: t.guideOldVersion),
        ],
        const SizedBox(height: 24),
        if (audio != null && p != null)
          _Player(
            playback: p,
            partCount: partCount,
            partLength: _partLength(part),
            seekDelta: _seekDelta,
            onToggle: _toggle,
            onSeekBy: _seekBy,
            onDrag: (double? d) => setState(() => _seekDelta = d),
            onPart: _goPart,
          )
        else
          _Note(icon: Icons.mic_rounded, text: t.guideRecording),
        if (p?.failed ?? false) ...<Widget>[
          const SizedBox(height: 12),
          _Note(icon: Icons.wifi_off_rounded, text: t.guideAudioFailed),
        ],
        const SizedBox(height: 24),
        if (audio != null)
          // Solo el texto de la parte que suena (como subtítulos).
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Text(partText, style: text.bodyLarge),
            ),
          )
        else
          // Sin audio: el guion completo, para leerlo.
          for (final GuideSegment s in script.segments)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(s.text, style: text.bodyLarge),
            ),
        if (audio != null) ...<Widget>[
          const SizedBox(height: 16),
          _PartChips(count: partCount, current: part, onPick: _goPart),
        ],
      ],
    );
  }

  /// "1", "1,25", "1.5"... con la coma o el punto de cada idioma.
  static String _speedLabel(BuildContext context, double speed) =>
      NumberFormat.decimalPattern(Localizations.localeOf(context).toString())
          .format(speed);
}

// --- Piezas ------------------------------------------------------------------

class _Player extends StatelessWidget {
  const _Player({
    required this.playback,
    required this.partCount,
    required this.partLength,
    required this.seekDelta,
    required this.onToggle,
    required this.onSeekBy,
    required this.onDrag,
    required this.onPart,
  });

  final Playback playback;
  final int partCount;
  final Duration partLength;
  final double? seekDelta;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeekBy;
  final ValueChanged<double?> onDrag;
  final ValueChanged<int> onPart;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final int part = playback.part;
    final double total = partLength.inMilliseconds.toDouble();
    final double shownMs =
        (playback.position.inMilliseconds + (seekDelta ?? 0) * 1000).clamp(
          0,
          total,
        );
    final double progress = total <= 0 ? 0 : shownMs / total;
    final Duration shown = Duration(milliseconds: shownMs.round());

    return Column(
      children: <Widget>[
        Text(
          t.guidePartOf(part + 1, partCount),
          style: const TextStyle(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 12),
        _Waveform(progress: progress),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            Text(_clock(shown)),
            const Spacer(),
            Text(_clock(partLength)),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: <Widget>[
            IconButton(
              tooltip: t.guidePrev,
              onPressed: part > 0 ? () => onPart(part - 1) : null,
              icon: const Icon(Icons.skip_previous_rounded, size: 32),
            ),
            IconButton(
              tooltip: t.guideBack10,
              onPressed: () => onSeekBy(const Duration(seconds: -10)),
              icon: const Icon(Icons.replay_10_rounded, size: 32),
            ),
            _Knob(
              playing: playback.playing,
              loading: playback.loading,
              onToggle: onToggle,
              onSeekBy: onSeekBy,
              onDrag: onDrag,
            ),
            IconButton(
              tooltip: t.guideForward10,
              onPressed: () => onSeekBy(const Duration(seconds: 10)),
              icon: const Icon(Icons.forward_10_rounded, size: 32),
            ),
            IconButton(
              tooltip: t.guideNext,
              onPressed: part < partCount - 1 ? () => onPart(part + 1) : null,
              icon: const Icon(Icons.skip_next_rounded, size: 32),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          seekDelta == null || seekDelta!.abs() < 1
              ? t.guideSeekHint
              : t.guideSeekBy(
                  '${seekDelta! > 0 ? '+' : '−'}${seekDelta!.abs().round()}',
                ),
          style: const TextStyle(color: NomadColors.textMuted, fontSize: 13),
        ),
      ],
    );
  }

  static String _clock(Duration d) {
    final int s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }
}

/// El círculo verde de la maqueta: tócalo para reproducir o pausar, o
/// deslízalo a los lados para avanzar o retroceder (3 px = 1 segundo).
class _Knob extends StatelessWidget {
  const _Knob({
    required this.playing,
    required this.loading,
    required this.onToggle,
    required this.onSeekBy,
    required this.onDrag,
  });

  final bool playing;
  final bool loading;
  final VoidCallback onToggle;
  final ValueChanged<Duration> onSeekBy;
  final ValueChanged<double?> onDrag;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    // En árabe o hebreo (de derecha a izquierda), "adelante" es a la izquierda.
    final double dir = Directionality.of(context) == TextDirection.rtl ? -1 : 1;
    double dragged = 0;
    // Para lectores de pantalla: botón con acciones "subir/bajar" que
    // avanzan o retroceden 10 s (deslizar el dedo no es accesible).
    return Semantics(
      button: true,
      label: playing ? t.guidePause : t.guidePlay,
      onIncrease: () => onSeekBy(const Duration(seconds: 10)),
      onDecrease: () => onSeekBy(const Duration(seconds: -10)),
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onToggle,
        onHorizontalDragStart: (_) => dragged = 0,
        onHorizontalDragUpdate: (DragUpdateDetails d) {
          dragged += d.delta.dx * dir;
          onDrag(dragged / 3);
        },
        onHorizontalDragEnd: (_) {
          onDrag(null);
          onSeekBy(Duration(milliseconds: (dragged / 3 * 1000).round()));
        },
        onHorizontalDragCancel: () => onDrag(null),
        child: Container(
          width: 82,
          height: 82,
          decoration: const BoxDecoration(
            color: NomadColors.mint,
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: loading
              ? const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    color: NomadColors.background,
                    strokeWidth: 3,
                  ),
                )
              : Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: NomadColors.background,
                  size: 44,
                ),
        ),
      ),
    );
  }
}

/// Las barritas de la maqueta: se pintan de menta según avanza el audio.
class _Waveform extends StatelessWidget {
  const _Waveform({required this.progress});

  final double progress;

  static const List<double> _heights = <double>[
    10, 18, 26, 14, 32, 22, 38, 28, 16, 30, 40, 24, 12, 34, 20, 28, 36, 18, //
    26, 14, 30, 22, 38, 16, 24, 32, 12, 28, 20, 34, 18, 26, 14, 30, 22, 16,
    24, 12, 20, 10,
  ];

  @override
  Widget build(BuildContext context) {
    final int lit = (progress * _heights.length).round();
    return ExcludeSemantics(
      child: SizedBox(
        height: 44,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            for (int i = 0; i < _heights.length; i++)
              Expanded(
                child: Center(
                  child: Container(
                    height: _heights[i],
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      color: i < lit ? NomadColors.mint : NomadColors.outline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PartChips extends StatelessWidget {
  const _PartChips({
    required this.count,
    required this.current,
    required this.onPick,
  });

  final int count;
  final int current;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (int i = 0; i < count; i++)
          Semantics(
            label: t.guidePart(i + 1),
            selected: i == current,
            excludeSemantics: true,
            child: ChoiceChip(
              label: Text('${i + 1}'),
              selected: i == current,
              showCheckmark: false,
              selectedColor: NomadColors.mint,
              labelStyle: TextStyle(
                fontWeight: FontWeight.w800,
                color: i == current ? NomadColors.background : NomadColors.text,
              ),
              onSelected: (_) => onPick(i),
            ),
          ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NomadColors.outline),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: NomadColors.mint, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

/// Mensaje a pantalla completa con Flyra (cargando, error...).
class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    this.busy = false,
    this.action,
    this.onAction,
  });

  final String text;
  final bool busy;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const FlyraAvatar(size: 64),
            const SizedBox(height: 20),
            Semantics(
              liveRegion: true,
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (busy) ...<Widget>[
              const SizedBox(height: 20),
              const CircularProgressIndicator(),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(height: 20),
              FilledButton(onPressed: onAction, child: Text(action!)),
            ],
          ],
        ),
      ),
    );
  }
}
