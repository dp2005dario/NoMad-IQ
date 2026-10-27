// Cámara de viaje (maqueta "Recuerdo"): foto o vídeo, con la pegatina del
// viaje ("ECLIPTA · DÍA 2 · MADRID · 22 oct · atardecer") pintada en la foto.
// Lo que haces se guarda solo en tus Recuerdos (en este móvil) y "Compartir"
// abre el menú del móvil: de ahí a una historia de Instagram, WhatsApp...
//
// La música, los stickers y el texto se ponen en Instagram: ECLIPTA solo le
// pasa la foto o el vídeo.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/camera_device.dart' show CameraStart;
import '../map/geo.dart';
import '../map/location.dart';
import '../sos/where_am_i.dart';
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
  const TravelCameraScreen({super.key, this.locate = whereabouts});

  final Future<Whereabouts> Function(GeoPoint) locate;

  @override
  State<TravelCameraScreen> createState() => _TravelCameraScreenState();
}

enum _Phase { starting, live, recording, review, failed }

class _TravelCameraScreenState extends State<TravelCameraScreen> {
  late final AppServices _services = ServicesScope.of(context);
  TravelCamera? _camera;
  _Phase _phase = _Phase.starting;
  CameraStart? _start;
  bool _video = false;
  bool _sticker = true;
  String? _city;

  /// Lo último que hiciste (ya guardado en Recuerdos).
  Memory? _last;
  Uint8List? _lastPhoto;
  int _seconds = 0;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_open());
      unawaited(_findCity());
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
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
    final CameraStart got = await camera.start(video: _video);
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
      final PositionFix fix = await gps.watch().first.timeout(
        const Duration(seconds: 10),
      );
      final String? city = (await widget.locate(fix.point)).city;
      if (mounted) setState(() => _city = city);
    } on Object {
      // Sin GPS: pegatina sin ciudad.
    }
  }

  Future<void> _mode(bool video) async {
    if (video == _video || _phase == _Phase.recording) return;
    setState(() {
      _video = video;
      _phase = _Phase.starting;
    });
    // Para vídeo hace falta el micrófono: se vuelve a encender la cámara.
    await _open();
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
      setState(() {
        _last = m;
        _lastPhoto = bytes;
        _phase = _Phase.review;
      });
    } on Object {
      _toast(t.memFailed);
    }
  }

  Future<void> _record() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final TravelCamera? camera = _camera;
    if (camera == null) return;
    if (_phase == _Phase.recording) {
      await _stop();
      return;
    }
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
    setState(() {
      _phase = _Phase.recording;
      _seconds = 0;
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) return;
      setState(() => _seconds++);
      if (_seconds >= maxVideo.inSeconds) unawaited(_stop());
    });
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
      setState(() {
        _last = m;
        _lastPhoto = null;
        _phase = _Phase.review;
      });
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
      _phase = _Phase.live;
    });
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
      body: switch (_phase) {
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
          onAnother: () => setState(() => _phase = _Phase.live),
        ),
        _Phase.live || _Phase.recording => _Live(
          camera: _camera!,
          video: _video,
          recording: _phase == _Phase.recording,
          seconds: _seconds,
          sticker: _sticker,
          onSticker: () => setState(() => _sticker = !_sticker),
          onMode: (bool v) => unawaited(_mode(v)),
          onShutter: () => unawaited(_video ? _record() : _shoot()),
        ),
      },
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
    required this.video,
    required this.recording,
    required this.seconds,
    required this.sticker,
    required this.onSticker,
    required this.onMode,
    required this.onShutter,
  });

  final TravelCamera camera;
  final bool video;
  final bool recording;
  final int seconds;
  final bool sticker;
  final VoidCallback onSticker;
  final ValueChanged<bool> onMode;
  final VoidCallback onShutter;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
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
                  else if (!video)
                    FilterChip(
                      selected: sticker,
                      onSelected: (_) => onSticker(),
                      label: Text(t.memSticker),
                    ),
                ],
              ),
              const Spacer(),
              if (video && !recording)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    t.memVideoNoSticker,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              if (!recording)
                SegmentedButton<bool>(
                  segments: <ButtonSegment<bool>>[
                    ButtonSegment<bool>(value: false, label: Text(t.memPhoto)),
                    ButtonSegment<bool>(value: true, label: Text(t.memVideo)),
                  ],
                  selected: <bool>{video},
                  onSelectionChanged: (Set<bool> s) => onMode(s.first),
                ),
              const SizedBox(height: 16),
              Semantics(
                button: true,
                label: video
                    ? (recording ? t.memStop : t.memRecord)
                    : t.memShoot,
                child: GestureDetector(
                  onTap: onShutter,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 4),
                    ),
                    padding: const EdgeInsets.all(6),
                    child: Container(
                      decoration: BoxDecoration(
                        color: video ? const Color(0xFFFF3B5C) : Colors.white,
                        borderRadius: BorderRadius.circular(recording ? 8 : 40),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }
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
