// Cámara de viaje (maqueta "Recuerdo"): foto o vídeo, con la pegatina del
// viaje ("ECLIPTA · DÍA 2 · MADRID · 22 oct · atardecer") pintada en la foto.
// Lo que haces se guarda solo en tus Recuerdos (en este móvil) y "Compartir"
// abre el menú del móvil: de ahí a una historia de Instagram, WhatsApp...
//
// La música, los stickers y el texto se ponen en Instagram: ECLIPTA solo le
// pasa la foto o el vídeo.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/camera_device.dart' show CameraStart;
import '../map/geo.dart';
import '../map/location.dart';
import '../sos/where_am_i.dart';
import '../shell/app_shell.dart';
import 'memories.dart';
import 'travel_camera.dart';

String dayPartLabel(AppLocalizations t, DayPart p) => switch (p) {
  DayPart.morning => t.memMorning,
  DayPart.afternoon => t.memAfternoon,
  DayPart.sunset => t.memSunset,
  DayPart.night => t.memNight,
};

/// Las líneas de la pegatina.
List<String> stickerLines(
  AppLocalizations t,
  String locale, {
  required int day,
  required DateTime at,
  String? city,
}) => <String>[
  t.memStickerDay(day),
  if (city != null) city.toUpperCase(),
  '${DateFormat.yMMMd(locale).format(at)} · ${dayPartLabel(t, dayPartOf(at))}',
];

class TravelCameraScreen extends StatefulWidget {
  const TravelCameraScreen({
    super.key,
    this.locate = whereabouts,
    this.onScanner,
  });

  final Future<Whereabouts> Function(GeoPoint) locate;

  /// En la pestaña Cámara: deslizar a la derecha abre el escáner de
  /// monumentos (null = no hay escáner, p. ej. abierta desde Recuerdos).
  final VoidCallback? onScanner;

  @override
  State<TravelCameraScreen> createState() => _TravelCameraScreenState();
}

enum _Phase { starting, live, recording, review, failed }

class _TravelCameraScreenState extends State<TravelCameraScreen>
    with WidgetsBindingObserver {
  late final AppServices _services = ServicesScope.of(context);
  TravelCamera? _camera;
  _Phase _phase = _Phase.starting;
  CameraStart? _start;
  bool _sticker = true;

  /// "Guardado en Recuerdos" un momento después de cada foto o vídeo.
  bool _flash = false;

  /// El dedo sigue en el botón (si lo suelta antes de que empiece el vídeo,
  /// se para nada más empezar).
  bool _holding = false;
  Timer? _flashOff;
  String? _city;

  /// Lo último que hiciste (ya guardado en Recuerdos).
  Memory? _last;
  Uint8List? _lastPhoto;
  int _seconds = 0;
  Timer? _tick;

  // Como el escáner: la cámara solo está encendida mientras se ve esta
  // pantalla (en la pestaña Cámara, las otras pestañas siguen vivas) y la app
  // está delante. Así no gasta batería de fondo.
  bool _visible = false;
  bool _foreground = true;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_findCity());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    final bool want = _visible && _foreground;
    if (want && !_running) {
      _running = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _running) unawaited(_open());
      });
    } else if (!want && _running) {
      _running = false;
      unawaited(_sleep());
    }
  }

  /// Apaga la cámara (si estaba grabando, el vídeo se guarda antes).
  Future<void> _sleep() async {
    if (_phase == _Phase.recording) {
      _holding = false;
      await _stop();
    }
    final TravelCamera? camera = _camera;
    _camera = null;
    await camera?.dispose();
    if (mounted && _phase != _Phase.review) {
      setState(() => _phase = _Phase.starting);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _flashOff?.cancel();
    unawaited(_camera?.dispose());
    super.dispose();
  }

  Future<void> _open() async {
    final TravelCameraFactory? make = _services.newTravelCamera;
    if (make == null) {
      setState(() {
        _start = CameraStart.missing;
        _phase = _Phase.failed;
      });
      return;
    }
    final TravelCamera camera = _camera ??= make();
    // Siempre con micrófono: mantener pulsado graba vídeo sin cambiar de modo.
    final CameraStart got = await camera.start(video: true);
    if (!mounted) return;
    setState(() {
      _start = got;
      _phase = got == CameraStart.ready ? _Phase.live : _Phase.failed;
    });
  }

  /// La ciudad para la pegatina (si hay GPS; si no, la pegatina va sin ella).
  Future<void> _findCity() async {
    final LocationSource gps = _services.location;
    try {
      if (await gps.check() != LocationAccess.granted) return;
      final PositionFix fix = await positionNow(
        gps,
        wait: const Duration(seconds: 10),
      );
      final String? city = (await widget.locate(fix.point)).city;
      if (mounted) setState(() => _city = city);
    } on Object {
      // Sin GPS: pegatina sin ciudad.
    }
  }

  /// Lo hecho ya está en Recuerdos: se dice un momento y se sigue con la
  /// cámara (la miniatura de abajo abre "Compartir" y "Repetir").
  void _saved(Memory m, Uint8List? photo) {
    _flashOff?.cancel();
    setState(() {
      _last = m;
      _lastPhoto = photo;
      _phase = _Phase.live;
      _flash = true;
    });
    _flashOff = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _flash = false);
    });
  }

  String _name(String ext) => 'm_${DateTime.now().microsecondsSinceEpoch}.$ext';

  Future<void> _shoot() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final TravelCamera? camera = _camera;
    if (camera == null || _services.memories.full) {
      _toast(t.memFull);
      return;
    }
    final DateTime now = DateTime.now();
    try {
      Uint8List bytes = await camera.takePhoto();
      String ext = 'jpg';
      if (_sticker) {
        bytes = await _services.sticker(
          bytes,
          stickerLines(
            t,
            locale,
            day: tripDay(_services.memories.tripStart(now), now),
            at: now,
            city: _city,
          ),
        );
        ext = 'png';
      }
      final String name = _name(ext);
      await _services.memoryFiles.write(name, bytes);
      final Memory m = Memory(
        file: name,
        kind: MemoryKind.photo,
        at: now,
        city: _city,
      );
      await _services.memories.add(m);
      if (!mounted) return;
      unawaited(HapticFeedback.lightImpact());
      _saved(m, bytes);
    } on Object {
      _toast(t.memFailed);
    }
  }

  /// Mantener pulsado: empieza el vídeo (al soltar, [_stop]).
  Future<void> _record() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final TravelCamera? camera = _camera;
    if (camera == null || _phase != _Phase.live) return;
    _holding = true;
    if (_services.memories.full) {
      _toast(t.memFull);
      return;
    }
    try {
      await camera.startVideo();
    } on Object {
      _toast(t.memFailed);
      return;
    }
    if (!mounted) return;
    unawaited(HapticFeedback.mediumImpact());
    setState(() {
      _phase = _Phase.recording;
      _seconds = 0;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) return;
      setState(() => _seconds++);
      if (_seconds >= maxVideo.inSeconds) unawaited(_stop());
    });
    if (!_holding) await _stop();
  }

  void _release() {
    _holding = false;
    unawaited(_stop());
  }

  Future<void> _stop() async {
    final AppLocalizations t = AppLocalizations.of(context);
    _tick?.cancel();
    final TravelCamera? camera = _camera;
    if (camera == null || _phase != _Phase.recording) return;
    try {
      final String temp = await camera.stopVideo();
      final String name = _name('mp4');
      await _services.memoryFiles.import(temp, name);
      final Memory m = Memory(
        file: name,
        kind: MemoryKind.video,
        at: DateTime.now(),
        city: _city,
      );
      await _services.memories.add(m);
      if (!mounted) return;
      _saved(m, null);
    } on Object {
      if (mounted) setState(() => _phase = _Phase.live);
      _toast(t.memFailed);
    }
  }

  Future<void> _share() async {
    final Memory? m = _last;
    if (m == null) return;
    await _services.share(<String>[await _services.memoryFiles.pathOf(m.file)]);
  }

  Future<void> _retake() async {
    final Memory? m = _last;
    if (m != null) await _services.memories.remove(m);
    if (!mounted) return;
    setState(() {
      _last = null;
      _lastPhoto = null;
      _phase = _camera == null ? _Phase.starting : _Phase.live;
    });
    if (_camera == null) await _open();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(t.memCameraTitle),
        backgroundColor: Colors.transparent,
        // En la pestaña Cámara (a pantalla completa): la X vuelve a la
        // pestaña de donde venías, como en el escáner.
        leading: widget.onScanner == null
            ? null
            : IconButton(
                tooltip: 'Cerrar la cámara',
                icon: const Icon(Icons.close_rounded),
                onPressed: () {
                  final StatefulNavigationShellState? shell =
                      StatefulNavigationShell.maybeOf(context);
                  if (shell != null) {
                    shell.goBranch(AppShell.lastTab);
                  } else if (context.canPop()) {
                    context.pop();
                  }
                },
              ),
        actions: <Widget>[
          if (_phase == _Phase.live)
            IconButton(
              tooltip: t.memFlip,
              icon: const Icon(Icons.cameraswitch_rounded),
              onPressed: () async {
                await _camera?.flip();
                if (mounted) setState(() {});
              },
            ),
        ],
      ),
      extendBodyBehindAppBar: true,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // Deslizar a la derecha (el dedo va hacia la derecha) = escáner.
        onHorizontalDragEnd:
            widget.onScanner == null || _phase == _Phase.recording
            ? null
            : (DragEndDetails d) {
                if ((d.primaryVelocity ?? 0) > 250) widget.onScanner!();
              },
        child: switch (_phase) {
          _Phase.starting => const Center(child: CircularProgressIndicator()),
          _Phase.failed => _Failed(
            denied: _start == CameraStart.denied,
            onRetry: () => unawaited(_open()),
          ),
          _Phase.review => _Review(
            photo: _lastPhoto,
            video: _last?.kind == MemoryKind.video,
            seconds: _seconds,
            onShare: () => unawaited(_share()),
            onRetake: () => unawaited(_retake()),
            onAnother: () {
              if (_camera == null) {
                setState(() => _phase = _Phase.starting);
                unawaited(_open());
              } else {
                setState(() => _phase = _Phase.live);
              }
            },
          ),
          _Phase.live || _Phase.recording => _Live(
            camera: _camera!,
            recording: _phase == _Phase.recording,
            seconds: _seconds,
            sticker: _sticker,
            onSticker: () => setState(() => _sticker = !_sticker),
            onPhoto: () => unawaited(_shoot()),
            onHold: () => unawaited(_record()),
            onRelease: _release,
            last: _last,
            lastPhoto: _lastPhoto,
            flash: _flash,
            onLast: () => setState(() => _phase = _Phase.review),
            onScanner: widget.onScanner,
          ),
        },
      ),
    );
  }
}

class _Failed extends StatelessWidget {
  const _Failed({required this.denied, required this.onRetry});

  final bool denied;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.no_photography_rounded, size: 48),
            const SizedBox(height: 12),
            Text(
              denied ? t.memDenied : t.memNoCamera,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: onRetry, child: Text(t.memRetry)),
          ],
        ),
      ),
    );
  }
}

String _mmss(int s) => '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';

class _Live extends StatelessWidget {
  const _Live({
    required this.camera,
    required this.recording,
    required this.seconds,
    required this.sticker,
    required this.onSticker,
    required this.onPhoto,
    required this.onHold,
    required this.onRelease,
    required this.last,
    required this.lastPhoto,
    required this.flash,
    required this.onLast,
    required this.onScanner,
  });

  final TravelCamera camera;
  final bool recording;
  final int seconds;
  final bool sticker;
  final VoidCallback onSticker;
  final VoidCallback onPhoto;
  final VoidCallback onHold;
  final VoidCallback onRelease;
  final Memory? last;
  final Uint8List? lastPhoto;
  final bool flash;
  final VoidCallback onLast;
  final VoidCallback? onScanner;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final VoidCallback? scanner = onScanner;
    final Uint8List? thumb = lastPhoto;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        camera.preview(),
        SafeArea(
          child: Column(
            children: <Widget>[
              const SizedBox(height: 56),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  if (recording)
                    Chip(
                      backgroundColor: const Color(0xFFFF3B5C),
                      label: Text(
                        '● ${_mmss(seconds)} / ${_mmss(maxVideo.inSeconds)}',
                      ),
                    )
                  else
                    FilterChip(
                      selected: sticker,
                      onSelected: (_) => onSticker(),
                      label: Text(t.memSticker),
                    ),
                ],
              ),
              const Spacer(),
              AnimatedOpacity(
                opacity: flash ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xCC0B1217),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Icon(
                        Icons.check_circle_rounded,
                        size: 18,
                        color: NomadColors.mint,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        t.memSavedFlash,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: <Widget>[
                  // La miniatura de lo último: abre Compartir / Repetir.
                  Expanded(
                    child: Align(
                      child: last == null
                          ? const SizedBox.shrink()
                          : Semantics(
                              button: true,
                              label: t.memShare,
                              child: GestureDetector(
                                onTap: onLast,
                                child: Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                    color: NomadColors.surface,
                                  ),
                                  clipBehavior: Clip.antiAlias,
                                  child: thumb != null
                                      ? Image.memory(
                                          thumb,
                                          fit: BoxFit.cover,
                                          cacheWidth: 160,
                                          errorBuilder: (_, _, _) =>
                                              const SizedBox.shrink(),
                                        )
                                      : const Icon(
                                          Icons.play_arrow_rounded,
                                          color: Colors.white,
                                        ),
                                ),
                              ),
                            ),
                    ),
                  ),
                  _Shutter(
                    recording: recording,
                    label: recording ? t.memStop : t.memShoot,
                    onTap: onPhoto,
                    onHold: onHold,
                    onRelease: onRelease,
                  ),
                  const Expanded(child: SizedBox.shrink()),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                t.memShutterHint,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  shadows: <Shadow>[Shadow(blurRadius: 6)],
                ),
              ),
              if (scanner != null) ...<Widget>[
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: scanner,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          t.memSwipeScanner,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            shadows: <Shadow>[Shadow(blurRadius: 6)],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      const Icon(
                        Icons.arrow_forward_rounded,
                        size: 16,
                        color: Colors.white70,
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 18),
            ],
          ),
        ),
      ],
    );
  }
}

/// El botón blanco: tocar = foto; mantener = vídeo (se suelta = para). Al
/// grabar se pone rojo y crece, con el anillo blanco alrededor.
class _Shutter extends StatelessWidget {
  const _Shutter({
    required this.recording,
    required this.label,
    required this.onTap,
    required this.onHold,
    required this.onRelease,
  });

  final bool recording;
  final String label;
  final VoidCallback onTap;
  final VoidCallback onHold;
  final VoidCallback onRelease;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    child: GestureDetector(
      onTap: recording ? onRelease : onTap,
      onLongPressStart: (_) => onHold(),
      onLongPressEnd: (_) => onRelease(),
      child: AnimatedScale(
        scale: recording ? 1.18 : 1,
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 5),
          ),
          padding: const EdgeInsets.all(6),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: recording ? const Color(0xFFFF3B5C) : Colors.white,
              borderRadius: BorderRadius.circular(recording ? 12 : 40),
            ),
          ),
        ),
      ),
    ),
  );
}

class _Review extends StatelessWidget {
  const _Review({
    required this.photo,
    required this.video,
    required this.seconds,
    required this.onShare,
    required this.onRetake,
    required this.onAnother,
  });

  final Uint8List? photo;
  final bool video;
  final int seconds;
  final VoidCallback onShare;
  final VoidCallback onRetake;
  final VoidCallback onAnother;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Uint8List? bytes = photo;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 64, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: bytes != null
                    ? Image.memory(
                        bytes,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) =>
                            const ColoredBox(color: NomadColors.surface),
                      )
                    : ColoredBox(
                        color: NomadColors.surface,
                        child: Center(
                          child: Text(
                            t.memVideoSaved(_mmss(seconds)),
                            style: const TextStyle(fontSize: 18),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              t.memSavedHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onShare,
              icon: const Icon(Icons.ios_share_rounded),
              label: Text(t.memShare),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: onRetake,
                    child: Text(t.memRetake),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onAnother,
                    child: Text(t.memAnother),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              t.memInstagramNote,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
