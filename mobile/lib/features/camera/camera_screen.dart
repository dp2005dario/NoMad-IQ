// La pestaña Cámara (maqueta "Modo cámara"): apuntas a un monumento, tocas
// el botón y NomadIQ te dice qué es, cuándo se construyó y su historia.
//
// Cómo lo sabe (ver landmarks_api.dart): manda dónde estás (GPS), hacia
// dónde miras (brújula) y una foto pequeña. El servidor busca los lugares
// famosos de alrededor y elige el que tienes delante.
//
// Estados de la pantalla:
//   - Buscando: el marco "respira" y una línea verde lo recorre.
//   - Reconocido / ¿Es este?: un punto sobre el monumento, la etiqueta
//     arriba y la ficha abajo (Escuchar, sello, Wikipedia).
//   - Nada: "No reconozco ningún lugar famoso aquí" y, si hay, otros cerca.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import 'camera_device.dart';
import 'landmarks_api.dart';
import 'stamps.dart';

enum _Phase { starting, noAccess, noCamera, aiming, working, result }

enum _Problem { outOfScans, busy, network, noLocation }

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AppServices _services;
  late final AnimationController _scan = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 2),
  )..repeat(reverse: true);
  CameraDevice? _camera;
  StreamSubscription<double?>? _compass;
  double? _heading;
  _Phase _phase = _Phase.starting;
  _Problem? _problem;
  Recognition? _result;
  Landmark? _shown;
  bool _speaking = false;

  // La cámara solo está encendida mientras ves esta pestaña y la app está
  // delante. Las pestañas siguen "vivas" al cambiar (para no perder lo que
  // tenías), pero una cámara encendida de fondo gasta batería y no es
  // respetuosa: se apaga y se vuelve a encender al volver.
  bool _visible = false;
  bool _foreground = true;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Se guarda ya: en dispose() ya no se puede buscar hacia arriba.
    _services = ServicesScope.of(context);
    // TickerMode es false en las pestañas que no se ven.
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
      unawaited(_start());
    } else if (!want && _running) {
      _running = false;
      unawaited(_stopCamera());
    }
  }

  Future<void> _stopCamera() async {
    final CameraDevice? camera = _camera;
    _camera = null;
    // Lo primero, apagar la cámara; lo demás puede terminar después.
    await camera?.dispose();
    unawaited(_compass?.cancel());
    _compass = null;
    unawaited(_services.speaker.stop());
    if (mounted && _phase != _Phase.result) {
      setState(() => _phase = _Phase.starting);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scan.dispose();
    unawaited(_compass?.cancel());
    unawaited(_camera?.dispose());
    unawaited(_services.speaker.stop());
    super.dispose();
  }

  bool get _guest => SessionScope.of(context).status != SessionStatus.signedIn;

  Future<void> _start() async {
    if (_guest) return; // la pantalla pide iniciar sesión; nada se enciende
    final CameraFactory? factory = _services.newCamera;
    if (factory == null) {
      setState(() => _phase = _Phase.noCamera);
      return;
    }
    final CameraDevice camera = factory();
    final CameraStart started = await camera.start();
    if (!mounted || !_running) {
      // Mientras se encendía, cambiaste de pestaña: se apaga sin más.
      await camera.dispose();
      return;
    }
    if (started != CameraStart.ready) {
      await camera.dispose();
      setState(
        () => _phase = started == CameraStart.denied
            ? _Phase.noAccess
            : _Phase.noCamera,
      );
      return;
    }
    _camera = camera;
    _compass = camera.heading().listen((double? h) => _heading = h);
    setState(() => _phase = _Phase.aiming);
  }

  /// Una posición del GPS (pide permiso si hace falta). null = no hay.
  Future<PositionFix?> _position() async {
    final LocationSource gps = _services.location;
    LocationAccess access = await gps.check();
    if (access == LocationAccess.denied) access = await gps.request();
    if (access != LocationAccess.granted) return null;
    try {
      return await gps.watch().first.timeout(const Duration(seconds: 15));
    } on TimeoutException {
      return null;
    } on StateError {
      return null;
    }
  }

  Future<void> _recognize() async {
    final CameraDevice? camera = _camera;
    if (camera == null || _phase == _Phase.working) return;
    final String language = Localizations.localeOf(context).languageCode;
    setState(() {
      _phase = _Phase.working;
      _problem = null;
    });
    // Foto y GPS a la vez: así se tarda lo que tarde el más lento.
    final Future<Uint8List?> photo = camera.takePhoto().then<Uint8List?>(
      (Uint8List b) => b,
      onError: (Object _) => null,
    );
    final PositionFix? fix = await _position();
    final Uint8List? jpeg = await photo;
    if (!mounted) return;
    if (fix == null) {
      setState(() {
        _phase = _Phase.aiming;
        _problem = _Problem.noLocation;
      });
      return;
    }
    try {
      final Recognition found = await _services.landmarks.recognize(
        lat: fix.point.lat,
        lon: fix.point.lon,
        accuracyM: fix.accuracyM,
        heading: _heading,
        language: language,
        jpeg: jpeg,
      );
      if (!mounted) return;
      setState(() {
        _result = found;
        _shown = found.landmark;
        _phase = _Phase.result;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.aiming;
        _problem = switch (e.error) {
          ApiError.rateLimited => _Problem.outOfScans,
          ApiError.network => _Problem.network,
          _ => _Problem.busy,
        };
      });
    }
  }

  /// "¿No es este?": pide la ficha del que eliges.
  Future<void> _pick(Alternative alt) async {
    final String language = Localizations.localeOf(context).languageCode;
    await _services.speaker.stop();
    try {
      final Landmark card = await _services.landmarks.get(alt.qid, language);
      if (!mounted) return;
      setState(() {
        _shown = Landmark(
          qid: card.qid,
          name: card.name,
          lat: card.lat,
          lon: card.lon,
          description: card.description,
          year: card.year,
          photo: card.photo,
          summary: card.summary,
          articleUrl: card.articleUrl,
          distanceM: alt.distanceM,
        );
        _speaking = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _problem = e.error == ApiError.network
            ? _Problem.network
            : _Problem.busy,
      );
    }
  }

  Future<void> _again() async {
    await _services.speaker.stop();
    setState(() {
      _phase = _Phase.aiming;
      _result = null;
      _shown = null;
      _speaking = false;
      _problem = null;
    });
  }

  Future<void> _listen(Landmark l) async {
    if (_speaking) {
      await _services.speaker.stop();
      if (mounted) setState(() => _speaking = false);
      return;
    }
    final String text = <String?>[
      l.name,
      l.description,
      l.summary,
    ].whereType<String>().join('. ');
    setState(() => _speaking = true);
    await _services.speaker.speak(
      text,
      Localizations.localeOf(context).toLanguageTag(),
    );
    if (mounted) setState(() => _speaking = false);
  }

  Future<void> _stamp(Landmark l) async {
    await StampBook(_services.prefs).add(
      Stamp(
        qid: l.qid,
        name: l.name,
        date: DateTime.now(),
        lat: l.lat,
        lon: l.lon,
        year: l.year,
        description: l.description,
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    if (_guest) {
      return _Message(
        icon: Icons.photo_camera_rounded,
        text: t.cameraSignIn,
        action: t.signInFromGuest,
        onAction: () => context.push(Routes.signIn),
      );
    }
    switch (_phase) {
      case _Phase.starting:
        return const ColoredBox(
          color: NomadColors.background,
          child: Center(child: CircularProgressIndicator()),
        );
      case _Phase.noAccess:
        return _Message(
          icon: Icons.no_photography_rounded,
          text: t.cameraPermission,
          action: t.cameraAllow,
          onAction: () {
            setState(() => _phase = _Phase.starting);
            _running = true;
            unawaited(_start());
          },
        );
      case _Phase.noCamera:
        return _Message(
          icon: Icons.no_photography_rounded,
          text: t.cameraNoCamera,
        );
      case _Phase.aiming:
      case _Phase.working:
      case _Phase.result:
        break;
    }
    final Recognition? result = _phase == _Phase.result ? _result : null;
    final Landmark? shown = _shown;
    final bool recognized =
        result?.status == RecognitionStatus.recognized &&
        shown?.qid == result?.landmark?.qid;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _camera?.preview() ?? const SizedBox.expand(),
          SafeArea(
            child: Stack(
              children: <Widget>[
                // Arriba: el estado y "escanear otra vez".
                PositionedDirectional(
                  start: 16,
                  end: 16,
                  top: 12,
                  child: Row(
                    children: <Widget>[
                      const Spacer(),
                      _StatusPill(
                        text: switch (_phase) {
                          _Phase.result when shown != null =>
                            recognized ? t.cameraRecognized : t.cameraMaybe,
                          _Phase.result => t.cameraNoneShort,
                          _ => t.cameraSearching,
                        },
                      ),
                      const Spacer(),
                      _RoundButton(
                        icon: Icons.refresh_rounded,
                        tooltip: t.cameraRescan,
                        onTap: _phase == _Phase.result ? _again : null,
                      ),
                    ],
                  ),
                ),
                if (result == null)
                  _Scanner(animation: _scan, busy: _phase == _Phase.working),
                if (shown != null)
                  PositionedDirectional(
                    start: 50,
                    end: 50,
                    top: 70,
                    child: _Badge(
                      label: recognized
                          ? t.cameraBadgeRecognized
                          : t.cameraBadgeGuess,
                      name: shown.name,
                    ),
                  ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 16,
                  child: result == null
                      ? _AimBar(
                          hint: _problem == null
                              ? t.cameraHint
                              : switch (_problem!) {
                                  _Problem.outOfScans => t.cameraOutOfScans,
                                  _Problem.busy => t.cameraBusy,
                                  _Problem.network => t.errorNetwork,
                                  _Problem.noLocation => t.cameraNoLocation,
                                },
                          shootLabel: t.cameraShoot,
                          working: _phase == _Phase.working,
                          onShoot: _problem == _Problem.outOfScans
                              ? null
                              : _recognize,
                        )
                      : _ResultCard(
                          landmark: shown,
                          alternatives: <Alternative>[
                            for (final Alternative a in result.alternatives)
                              if (a.qid != shown?.qid) a,
                            if (shown != null &&
                                result.landmark != null &&
                                result.landmark!.qid != shown.qid)
                              Alternative(
                                qid: result.landmark!.qid,
                                name: result.landmark!.name,
                                distanceM: result.landmark!.distanceM ?? 0,
                              ),
                          ],
                          speaking: _speaking,
                          stamped:
                              shown != null &&
                              StampBook(_services.prefs).has(shown.qid),
                          onListen: _listen,
                          onStamp: _stamp,
                          onPick: _pick,
                          onOpen: (Uri url) => _services.openBooking(url),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pantalla de aviso (sin cuenta, sin permiso o sin cámara).
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 56, color: NomadColors.mint),
              const SizedBox(height: 16),
              Text(
                text,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 20),
                FilledButton(onPressed: onAction, child: Text(action!)),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

const Color _glass = Color(0xB30B1217); // negro de la app, translúcido

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: _glass,
        borderRadius: BorderRadius.circular(17),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: NomadColors.mint,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    style: IconButton.styleFrom(
      backgroundColor: _glass,
      disabledBackgroundColor: _glass,
      fixedSize: const Size(44, 44),
    ),
    icon: Icon(icon, color: NomadColors.text),
  );
}

/// El marco de esquinas que "respira" y la línea verde que lo recorre.
class _Scanner extends StatelessWidget {
  const _Scanner({required this.animation, required this.busy});

  final Animation<double> animation;
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
    child: AnimatedBuilder(
      animation: animation,
      builder: (BuildContext context, Widget? child) => Transform.scale(
        scale: 1 + 0.04 * animation.value,
        child: SizedBox(
          width: 250,
          height: 320,
          child: CustomPaint(
            painter: _FramePainter(
              line: animation.value,
              color: busy ? NomadColors.flights : NomadColors.mint,
            ),
          ),
        ),
      ),
    ),
  );
}

class _FramePainter extends CustomPainter {
  _FramePainter({required this.line, required this.color});

  final double line;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint corner = Paint()
      ..color = NomadColors.text
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    const double l = 40;
    final double w = size.width;
    final double h = size.height;
    for (final List<Offset> c in <List<Offset>>[
      <Offset>[const Offset(0, l), Offset.zero, const Offset(l, 0)],
      <Offset>[Offset(w - l, 0), Offset(w, 0), Offset(w, l)],
      <Offset>[Offset(0, h - l), Offset(0, h), Offset(l, h)],
      <Offset>[Offset(w - l, h), Offset(w, h), Offset(w, h - l)],
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(c[0].dx, c[0].dy)
          ..lineTo(c[1].dx, c[1].dy)
          ..lineTo(c[2].dx, c[2].dy),
        corner,
      );
    }
    final double y = 10 + (h - 20) * line;
    canvas.drawLine(
      Offset(6, y),
      Offset(w - 6, y),
      Paint()
        ..color = color
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.solid, 6),
    );
  }

  @override
  bool shouldRepaint(_FramePainter old) =>
      old.line != line || old.color != color;
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.name});

  final String label;
  final String name;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: const Color(0xE00B1217),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: NomadColors.mint, width: 2),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: NomadColors.mint,
          ),
        ),
        Text(
          name,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    ),
  );
}

/// Abajo, mientras apuntas: la pista y el botón grande de "Reconocer".
class _AimBar extends StatelessWidget {
  const _AimBar({
    required this.hint,
    required this.shootLabel,
    required this.working,
    required this.onShoot,
  });

  final String hint;
  final String shootLabel;
  final bool working;
  final VoidCallback? onShoot;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xCC0B1217),
            borderRadius: BorderRadius.circular(22),
          ),
          child: Text(
            hint,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      const SizedBox(height: 16),
      Tooltip(
        message: shootLabel,
        child: Semantics(
          button: true,
          label: shootLabel,
          excludeSemantics: true,
          child: GestureDetector(
            onTap: working ? null : onShoot,
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: NomadColors.text, width: 4),
              ),
              padding: const EdgeInsets.all(5),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: onShoot == null
                      ? NomadColors.textMuted
                      : NomadColors.mint,
                ),
                child: working
                    ? const Padding(
                        padding: EdgeInsets.all(18),
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: NomadColors.background,
                        ),
                      )
                    : const Icon(
                        Icons.center_focus_strong_rounded,
                        color: NomadColors.background,
                        size: 30,
                      ),
              ),
            ),
          ),
        ),
      ),
      // Hueco para el botón verde de la barra de pestañas.
      const SizedBox(height: 70),
    ],
  );
}

/// La ficha de abajo: nombre, datos, historia y los botones.
class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.landmark,
    required this.alternatives,
    required this.speaking,
    required this.stamped,
    required this.onListen,
    required this.onStamp,
    required this.onPick,
    required this.onOpen,
  });

  final Landmark? landmark;
  final List<Alternative> alternatives;
  final bool speaking;
  final bool stamped;
  final ValueChanged<Landmark> onListen;
  final ValueChanged<Landmark> onStamp;
  final ValueChanged<Alternative> onPick;
  final ValueChanged<Uri> onOpen;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Landmark? l = landmark;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.62,
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 70),
        decoration: BoxDecoration(
          color: const Color(0xF5141E25),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xFF26363F)),
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (l == null)
                Text(t.cameraNothing, style: text.bodyLarge)
              else ...<Widget>[
                Text(l.name, style: text.headlineSmall),
                if (l.description != null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    l.description!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: NomadColors.textMuted,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    if (l.year != null)
                      Expanded(
                        child: _Fact(label: t.cameraBuilt, value: '${l.year}'),
                      ),
                    if (l.year != null && l.distanceM != null)
                      const SizedBox(width: 6),
                    if (l.distanceM != null)
                      Expanded(
                        child: _Fact(
                          label: t.cameraDistance,
                          value: t.cameraMeters(l.distanceM!),
                        ),
                      ),
                  ],
                ),
                if (l.summary != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    l.summary!,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.5,
                      color: Color(0xFFDCE5E9),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => onListen(l),
                        icon: Icon(
                          speaking
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(
                          speaking ? t.cameraStopListening : t.cameraListen,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: stamped ? null : () => onStamp(l),
                        icon: Icon(
                          stamped
                              ? Icons.verified_rounded
                              : Icons.approval_rounded,
                        ),
                        label: Text(
                          stamped ? t.cameraStampSaved : t.cameraSaveStamp,
                        ),
                      ),
                    ),
                  ],
                ),
                if (l.articleUrl != null)
                  TextButton(
                    onPressed: () => onOpen(l.articleUrl!),
                    child: Text(t.cameraWikipedia),
                  ),
              ],
              if (alternatives.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  l == null ? t.cameraMaybeOneOf : t.cameraNotThis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final Alternative a in alternatives)
                      ActionChip(
                        label: Text(
                          '${a.name} · ${t.cameraMeters(a.distanceM)}',
                        ),
                        onPressed: () => onPick(a),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              Text(
                t.cameraCredits,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 11,
                  color: NomadColors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: const Color(0xFF1C2A33),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: NomadColors.textMuted,
          ),
        ),
        Text(
          value,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}
