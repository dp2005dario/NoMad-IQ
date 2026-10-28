// La pestaña Cámara (maqueta "Modo cámara"): apuntas a un monumento, tocas
// el botón y ECLIPTA te dice qué es, cuándo se construyó y su historia.
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

enum _Problem { outOfScans, busy, network, noLocation, off }

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
          ApiError.notFound =>
            _Problem.off, // el servidor no tiene este servicio
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

  /// Activa o apaga el modo identificar. Al activarlo se mira UNA vez qué
  /// monumento hay delante; al apagarlo la cámara vuelve a ser normal.
  Future<void> _toggleIdentify() async {
    if (_identify) {
      await _services.speaker.stop();
      if (!mounted) return;
      setState(() {
        _identify = false;
        _phase = _Phase.aiming;
        _result = null;
        _shown = null;
        _speaking = false;
        _problem = null;
      });
      return;
    }
    setState(() => _identify = true);
    await _recognize();
  }

  /// Hace la foto (sin buscar nada) y enseña las opciones.
  Future<void> _shoot() async {
    final CameraDevice? camera = _camera;
    if (camera == null || _phase != _Phase.aiming) return;
    try {
      final Uint8List bytes = await camera.takePhoto();
      if (!mounted) return;
      setState(() {
        _photo = bytes;
        _saved = null;
        _phase = _Phase.photo;
      });
    } on Object {
      _toast(AppLocalizations.of(context).memFailed);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Guarda la foto en Recuerdos (una sola vez). true = ya está guardada.
  Future<bool> _saveMemory() async {
    if (_saved != null) return true;
    final Uint8List? bytes = _photo;
    if (bytes == null) return false;
    final AppLocalizations t = AppLocalizations.of(context);
    if (_services.memories.full) {
      _toast(t.memFull);
      return false;
    }
    try {
      final DateTime now = DateTime.now();
      final String name = 'm_${now.microsecondsSinceEpoch}.jpg';
      await _services.memoryFiles.write(name, bytes);
      final Memory m = Memory(file: name, kind: MemoryKind.photo, at: now);
      await _services.memories.add(m);
      if (!mounted) return true;
      setState(() => _saved = m);
      _toast(t.cameraMemorySaved);
      return true;
    } on Object {
      _toast(t.memFailed);
      return false;
    }
  }

  /// Compartir abre el menú del móvil (Instagram, WhatsApp...). Hace falta un
  /// archivo, así que la foto también queda en Recuerdos.
  Future<void> _sharePhoto() async {
    if (!await _saveMemory()) return;
    final Memory? m = _saved;
    if (m == null) return;
    await _services.share(<String>[await _services.memoryFiles.pathOf(m.file)]);
  }

  /// Vuelve a la cámara (la foto ya guardada se queda en Recuerdos).
  void _backToCamera() {
    setState(() {
      _photo = null;
      _saved = null;
      _phase = _Phase.aiming;
    });
    // Si la pestaña apagó la cámara mientras mirabas la foto, se enciende.
    if (_camera == null && _running) {
      setState(() => _phase = _Phase.starting);
      unawaited(_start());
    }
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
      case _Phase.photo:
        return _PhotoReview(
          photo: _photo!,
          saved: _saved != null,
          onSave: () => unawaited(_saveMemory()),
          onShare: () => unawaited(_sharePhoto()),
          onRetake: _backToCamera,
        );
      case _Phase.aiming:
      case _Phase.working:
      case _Phase.result:
        break;
    }
    final Recognition? result = _phase == _Phase.result ? _result : null;
    final Landmark? shown = _phase == _Phase.result ? _shown : null;
    final bool recognized =
        result?.status == RecognitionStatus.recognized &&
        shown?.qid == result?.landmark?.qid;
    final bool working = _phase == _Phase.working;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _camera?.preview() ?? const SizedBox.expand(),
          SafeArea(
            child: Stack(
              children: <Widget>[
                // Arriba: el botón de identificar y, solo con ese modo
                // activo, una etiqueta discreta y "escanear otra vez".
                PositionedDirectional(
                  start: 16,
                  end: 16,
                  top: 12,
                  child: Row(
                    children: <Widget>[
                      _RoundButton(
                        icon: Icons.center_focus_strong_rounded,
                        tooltip: t.cameraIdentifyMode,
                        selected: _identify,
                        onTap: working ? null : _toggleIdentify,
                      ),
                      const Spacer(),
                      if (_identify)
                        _StatusPill(
                          text: switch (_phase) {
                            _Phase.result when shown != null =>
                              recognized ? t.cameraRecognized : t.cameraMaybe,
                            _Phase.result => t.cameraNoneShort,
                            _Phase.working => t.cameraSearching,
                            _ => t.cameraIdentifyOn,
                          },
                        ),
                      const Spacer(),
                      if (_identify)
                        _RoundButton(
                          icon: Icons.refresh_rounded,
                          tooltip: t.cameraRescan,
                          onTap: working || _problem == _Problem.outOfScans
                              ? null
                              : _recognize,
                        )
                      else
                        const SizedBox(width: 44),
                    ],
                  ),
                ),
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
                          // Sin problema y sin modo identificar: una pista
                          // sencilla de cómo hacer la foto.
                          hint: _problem == null
                              ? (_identify ? t.cameraHint : t.cameraNormalHint)
                              : switch (_problem!) {
                                  _Problem.outOfScans => t.cameraOutOfScans,
                                  _Problem.busy => t.cameraBusy,
                                  _Problem.network => t.errorNetwork,
                                  _Problem.noLocation => t.cameraNoLocation,
                                  _Problem.off => t.errorFeatureOff,
                                },
                          shootLabel: t.cameraTakePhoto,
                          working: working,
                          onShoot: _shoot,
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
    this.selected = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  /// Activado (el modo identificar): fondo verde.
  final bool selected;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    style: IconButton.styleFrom(
      backgroundColor: selected ? NomadColors.mint : _glass,
      disabledBackgroundColor: selected ? NomadColors.mint : _glass,
      fixedSize: const Size(44, 44),
    ),
    icon: Icon(
      icon,
      color: selected ? NomadColors.background : NomadColors.text,
    ),
  );
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

/// Abajo, mientras apuntas: la pista y el botón verde grande de hacer foto.
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
  final VoidCallback onShoot;

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
                  color: working ? NomadColors.textMuted : NomadColors.mint,
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
                        Icons.photo_camera_rounded,
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

/// La foto recién hecha: guardarla en Recuerdos, compartirla o repetir.
class _PhotoReview extends StatelessWidget {
  const _PhotoReview({
    required this.photo,
    required this.saved,
    required this.onSave,
    required this.onShare,
    required this.onRetake,
  });

  final Uint8List photo;
  final bool saved;
  final VoidCallback onSave;
  final VoidCallback onShare;
  final VoidCallback onRetake;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 86),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.memory(
                    photo,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) =>
                        const ColoredBox(color: NomadColors.surface),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: saved ? null : onSave,
                icon: Icon(
                  saved ? Icons.check_rounded : Icons.bookmark_add_rounded,
                ),
                label: Text(saved ? t.cameraMemorySaved : t.cameraSaveMemory),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: onShare,
                icon: const Icon(Icons.ios_share_rounded),
                label: Text(t.memShare),
              ),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: onRetake, child: Text(t.memRetake)),
              const SizedBox(height: 8),
              Text(
                t.memInstagramNote,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }
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
