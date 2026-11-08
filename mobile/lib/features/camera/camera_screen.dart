// La pestaña Cámara, igual que la maqueta "Cámara" (a pantalla completa,
// sin la barra de abajo): apuntas a un monumento y la cámara lo reconoce
// SOLA (no hay botón de disparar): Flyra te pregunta si quieres su
// audioguía, y luego la ficha (qué es, cuándo se construyó, su historia,
// Escuchar y Ver mi sello).
//
// Cómo lo sabe (ver landmarks_api.dart): manda dónde estás (GPS), hacia
// dónde miras (brújula) y una foto pequeña. El servidor busca los lugares
// famosos de alrededor y elige el que tienes delante.
//
// Estados de la pantalla (los 4 de la maqueta):
//   - Buscando: el marco "respira", una línea verde lo recorre y salen las
//     pistas que ya tiene (GPS y brújula).
//   - ¡Monumento detectado!: un recuadro sobre él y Flyra pregunta con
//     Aceptar / Cancelar (la barra de 8 s: si no tocas nada, se cierra).
//   - Abriendo…: la audioguía arranca (la ficha leída en voz alta).
//   - Reconocido: la etiqueta arriba y la ficha abajo.
//
// Cada pocos segundos la cámara mira sola SI tienes el móvil quieto y
// apuntas a otro sitio. Para no gastar los usos del día, como mucho
// [maxAutoScans] miradas por sesión. Al reconocer un monumento ganas su
// sello.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../../core/motion.dart';
import '../passport/passport.dart' show rarityOf, Rarity;
import '../shell/app_shell.dart';
import '../sos/where_am_i.dart';
import 'camera_device.dart';
import 'landmarks_api.dart';
import 'stamps.dart';

enum _Phase { starting, noAccess, noCamera, aiming, working, opening, result }

enum _Problem { outOfScans, busy, network, noLocation, off }

/// Miradas automáticas como mucho cada vez que abres la cámara.
const int maxAutoScans = 12;

class CameraScreen extends StatefulWidget {
  const CameraScreen({
    super.key,
    this.autoEvery = const Duration(seconds: 3),
    this.askFor = const Duration(seconds: 8),
  });

  /// Cada cuánto mira sola (null = nunca, solo con "Escanear otra vez").
  final Duration? autoEvery;

  /// Cuánto espera Flyra la respuesta antes de cerrar el aviso.
  final Duration askFor;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late AppServices _services;
  late final AnimationController _scan = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );
  CameraDevice? _camera;
  StreamSubscription<double?>? _compass;
  double? _heading;
  _Phase _phase = _Phase.starting;
  _Problem? _problem;
  Recognition? _result;
  Landmark? _shown;
  bool _speaking = false;

  /// Dónde estás (para la pista "GPS: estás en…"), si ya se sabe.
  PositionFix? _fix;
  String? _city;

  // Detección automática.
  Timer? _autoTimer;
  Timer? _askTimer;
  int _autoScans = 0;
  double? _lastAutoHeading;
  double? _headingAtTick;

  /// Lo que encontró la mirada automática y Flyra está preguntando.
  Recognition? _offer;

  /// Los que ya dijiste que no (no se vuelve a preguntar por ellos).
  final Set<String> _declined = <String>{};

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
    Motion.loop(_scan, reverse: true, testCount: 1);
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
    _stopAuto();
    unawaited(_services.speaker.stop());
    if (mounted && _phase != _Phase.result) {
      setState(() => _phase = _Phase.starting);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scan.dispose();
    _stopAuto();
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
    _compass = camera.heading().listen((double? h) {
      final bool first = _heading == null && h != null;
      _heading = h;
      if (first && mounted) setState(() {});
    });
    setState(() => _phase = _Phase.aiming);
    _startAuto();
    unawaited(_whereAmI());
  }

  void _startAuto() {
    final Duration? every = widget.autoEvery;
    if (every == null || _autoTimer != null) return;
    _autoTimer = Timer.periodic(every, (_) => _autoTick());
  }

  void _stopAuto() {
    _autoTimer?.cancel();
    _autoTimer = null;
    _askTimer?.cancel();
    _askTimer = null;
  }

  /// ¿Toca mirar sola? Solo apuntando, sin avisos pendientes, con el móvil
  /// quieto (la brújula casi no se ha movido desde la vez anterior) y
  /// mirando a otro sitio que la última vez.
  void _autoTick() {
    final double? h = _heading;
    final double? before = _headingAtTick;
    _headingAtTick = h;
    if (!mounted ||
        _phase != _Phase.aiming ||
        _offer != null ||
        _problem == _Problem.outOfScans ||
        _problem == _Problem.off ||
        _autoScans >= maxAutoScans) {
      return;
    }
    bool near(double? a, double? b, double deg) =>
        a == null || b == null || ((a - b + 540) % 360 - 180).abs() < deg;
    final bool steady = before == null ? h == null : near(h, before, 12);
    final bool sameView =
        _lastAutoHeading != null && near(h, _lastAutoHeading, 20);
    if (!steady || (sameView && _autoScans > 0)) return;
    _autoScans++;
    _lastAutoHeading = h;
    unawaited(_recognize(auto: true));
  }

  /// Flyra pregunta por [found] (un monumento que la cámara vio sola).
  void _ask(Recognition found) {
    setState(() => _offer = found);
    _askTimer?.cancel();
    _askTimer = Timer(widget.askFor, () => _answer(accept: false));
    // Un "toc-toc" suave: Flyra ha visto algo.
    unawaited(HapticFeedback.mediumImpact());
  }

  void _answer({required bool accept}) {
    _askTimer?.cancel();
    _askTimer = null;
    final Recognition? found = _offer;
    final Landmark? l = found?.landmark;
    if (!mounted || found == null || l == null) return;
    // Cancelar (o no tocar nada) enseña la ficha sin leerla; Aceptar pone
    // la audioguía: "Abriendo…" y la ficha leída en voz alta.
    _declined.add(l.qid);
    setState(() {
      _offer = null;
      _result = found;
      _shown = l;
      _phase = accept ? _Phase.opening : _Phase.result;
    });
    unawaited(_earn(found));
    if (!accept) return;
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 1100), () {
        if (!mounted || _phase != _Phase.opening) return;
        setState(() => _phase = _Phase.result);
        unawaited(_listen(l));
      }),
    );
  }

  /// Al reconocer un monumento (visto en la foto) ganas su sello.
  Future<void> _earn(Recognition found) async {
    final Landmark? l = found.landmark;
    if (l == null || found.status != RecognitionStatus.recognized) return;
    if (StampBook(_services.prefs).has(l.qid)) return;
    await _stamp(l);
  }

  /// Dónde estás, para la pista del GPS (pide permiso si hace falta).
  Future<void> _whereAmI() async {
    final PositionFix? fix = await _position();
    if (!mounted || fix == null) return;
    setState(() => _fix = fix);
    final Whereabouts w = await whereabouts(fix.point);
    if (mounted) setState(() => _city = w.city);
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

  Future<void> _recognize({bool auto = false}) async {
    final CameraDevice? camera = _camera;
    if (camera == null || _phase == _Phase.working) return;
    if (!auto) {
      // Si tocas el botón, el aviso de Flyra sobra.
      _askTimer?.cancel();
      _offer = null;
    }
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
    if (fix != null) _fix = fix;
    if (fix == null) {
      setState(() {
        _phase = _Phase.aiming;
        // Sin GPS no se puede saber qué tienes delante: se dice abajo.
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
      if (auto) {
        // Mirando sola: solo se dice algo si hay un monumento nuevo.
        setState(() => _phase = _Phase.aiming);
        final Landmark? l = found.landmark;
        if (l != null && !_declined.contains(l.qid)) _ask(found);
        return;
      }
      setState(() {
        _result = found;
        _shown = found.landmark;
        _phase = _Phase.result;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.aiming;
        // Mirando sola, un fallo de red pasajero no se enseña.
        if (auto && e.error != ApiError.rateLimited) return;
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

  /// "Escanear otra vez": vuelve a buscar y mira ya mismo.
  Future<void> _rescan() async {
    _askTimer?.cancel();
    _askTimer = null;
    await _services.speaker.stop();
    if (!mounted) return;
    setState(() {
      _phase = _phase == _Phase.working ? _Phase.working : _Phase.aiming;
      _offer = null;
      _result = null;
      _shown = null;
      _speaking = false;
      if (_problem != _Problem.outOfScans) _problem = null;
    });
    _lastAutoHeading = null;
    if (_autoScans < maxAutoScans && _problem == null) {
      _autoScans++;
      unawaited(_recognize(auto: true));
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

  /// "Brújula: miras al sur" (8 direcciones).
  static String _facing(double h) {
    const List<String> dirs = <String>[
      'norte',
      'noreste',
      'este',
      'sureste',
      'sur',
      'suroeste',
      'oeste',
      'noroeste',
    ];
    return dirs[((h % 360) / 45).round() % 8];
  }

  /// Las pistas de la maqueta: GPS, brújula y (si la foto coincide) forma.
  List<(String, Color)> _signals({bool shape = false}) => <(String, Color)>[
    if (_fix case final PositionFix f)
      (
        _city == null
            ? '📍 GPS: ±${f.accuracyM.round()} m'
            : '📍 GPS: estás en $_city',
        NomadColors.flights,
      ),
    if (_heading case final double h)
      ('🧭 Brújula: miras al ${_facing(h)}', NomadColors.money),
    if (shape) ('👁️ La forma coincide', NomadColors.group),
  ];

  /// "en español", para "Abriendo la audioguía…".
  String _inLanguage() =>
      switch (Localizations.localeOf(context).languageCode) {
        'es' => 'en español',
        'en' => 'en inglés',
        'fr' => 'en francés',
        'de' => 'en alemán',
        'it' => 'en italiano',
        'pt' => 'en portugués',
        final String code => 'en ${code.toUpperCase()}',
      };

  void _close() {
    final StatefulNavigationShellState? shell = StatefulNavigationShell.maybeOf(
      context,
    );
    if (shell != null) {
      shell.goBranch(AppShell.lastTab);
    } else if (context.canPop()) {
      context.pop();
    }
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
        onClose: _close,
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
          onClose: _close,
        );
      case _Phase.noCamera:
        return _Message(
          icon: Icons.no_photography_rounded,
          text: t.cameraNoCamera,
          onClose: _close,
        );
      case _Phase.aiming:
      case _Phase.working:
      case _Phase.opening:
      case _Phase.result:
        break;
    }
    final Recognition? offer = _offer;
    final Landmark? asking = offer?.landmark;
    final bool showing = _phase == _Phase.result || _phase == _Phase.opening;
    final Landmark? shown = showing ? _shown : null;
    final bool recognized =
        _result?.status == RecognitionStatus.recognized &&
        shown?.qid == _result?.landmark?.qid;
    final String status = switch (_phase) {
      _Phase.opening => 'Abriendo…',
      _Phase.result => 'Monumento reconocido',
      _ when asking != null => '¡Monumento detectado!',
      _ => 'Buscando monumentos cerca…',
    };
    final String hint = _problem == null
        ? 'Apunta a un monumento…'
        : switch (_problem!) {
            _Problem.outOfScans => t.cameraOutOfScans,
            _Problem.busy => t.cameraBusy,
            _Problem.network => t.errorNetwork,
            _Problem.noLocation => t.cameraNoLocation,
            _Problem.off => t.errorFeatureOff,
          };
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _camera?.preview() ?? const SizedBox.expand(),
          SafeArea(
            child: Stack(
              children: <Widget>[
                if (asking == null && shown == null) ...<Widget>[
                  _Scanner(animation: _scan),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 176,
                    child: Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final (String text, Color c) in _signals())
                          _Chip(text: text, color: c),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 120,
                    child: Center(
                      child: Semantics(
                        liveRegion: true,
                        child: Container(
                          constraints: const BoxConstraints(minHeight: 44),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xCC0B1217),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          child: Text(
                            hint,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFF2F5F3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
                if (asking != null) ...<Widget>[
                  _Lock(name: asking.name),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 18,
                    child: _FlyraAsk(
                      name: asking.name,
                      signals: _signals(
                        shape: offer!.status == RecognitionStatus.recognized,
                      ),
                      wait: widget.askFor,
                      onYes: () => _answer(accept: true),
                      onNo: () => _answer(accept: false),
                    ),
                  ),
                ],
                if (shown != null && _phase == _Phase.result) ...<Widget>[
                  _Pin(
                    label: recognized ? 'RECONOCIDO' : '¿ES ESTE?',
                    name: shown.name,
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 16,
                    child: _Card(
                      landmark: shown,
                      speaking: _speaking,
                      onListen: () => unawaited(_listen(shown)),
                      onStamp: () async {
                        if (!StampBook(_services.prefs).has(shown.qid)) {
                          await _stamp(shown);
                        }
                        if (context.mounted) {
                          unawaited(context.push(Routes.passport));
                        }
                      },
                    ),
                  ),
                ],
                // Arriba: cerrar, el estado y "escanear otra vez".
                Positioned(
                  left: 16,
                  right: 16,
                  top: 18,
                  child: Row(
                    children: <Widget>[
                      _Round(
                        tooltip: 'Cerrar la cámara',
                        onTap: _close,
                        icon: 'M6 6l12 12M18 6L6 18',
                        width: 2.4,
                      ),
                      Expanded(
                        child: Center(child: _StatusPill(text: status)),
                      ),
                      _Round(
                        tooltip: t.cameraRescan,
                        onTap: () => unawaited(_rescan()),
                        icon: 'M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_phase == _Phase.opening && shown != null)
            Positioned.fill(
              child: _Opening(name: shown.name, language: _inLanguage()),
            ),
        ],
      ),
    );
  }
}

/// Un icono de la maqueta (sus mismas líneas, de 24×24).
Widget _svg(
  String d,
  Color color, {
  double size = 20,
  double width = 2,
  bool fill = false,
}) {
  final String hex = (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0');
  return SvgPicture.string(
    fill
        ? '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
              '<path d="$d" fill="#$hex"/></svg>'
        : '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
              'fill="none" stroke="#$hex" stroke-width="$width" '
              'stroke-linecap="round" stroke-linejoin="round">'
              '<path d="$d"/></svg>',
    width: size,
    height: size,
  );
}

const Color _accent = NomadColors.mint;
const Color _ink = Color(0xFFF2F5F3);

/// Pantalla de aviso (sin cuenta, sin permiso o sin cámara), con su X.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.text,
    required this.onClose,
    this.action,
    this.onAction,
  });

  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: NomadColors.background,
    body: SafeArea(
      child: Stack(
        children: <Widget>[
          Center(
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
          Positioned(
            left: 16,
            top: 18,
            child: _Round(
              tooltip: 'Cerrar la cámara',
              onTap: onClose,
              icon: 'M6 6l12 12M18 6L6 18',
              width: 2.4,
            ),
          ),
        ],
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
              color: _accent,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Los botones redondos de arriba (cerrar y escanear otra vez).
class _Round extends StatelessWidget {
  const _Round({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.width = 2,
  });

  final String icon;
  final String tooltip;
  final VoidCallback onTap;
  final double width;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      excludeSemantics: true,
      child: Material(
        color: _glass,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(child: _svg(icon, _ink, width: width)),
          ),
        ),
      ),
    ),
  );
}

/// Una pista (GPS, brújula o forma) con su borde de color.
class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: const Duration(milliseconds: 350),
    builder: (BuildContext context, double v, Widget? child) => Opacity(
      opacity: v,
      child: Transform.translate(
        offset: Offset(0, 8 * (1 - v)),
        child: Transform.scale(scale: 0.9 + 0.1 * v, child: child),
      ),
    ),
    child: Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xD90B1217),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontSize: 11.5,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// El marco de esquinas que "respira" y la línea verde que lo recorre.
class _Scanner extends StatelessWidget {
  const _Scanner({required this.animation});

  final Animation<double> animation;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    top: 170,
    child: Center(
      child: AnimatedBuilder(
        animation: animation,
        builder: (BuildContext context, Widget? child) {
          final double v = Curves.easeInOut.transform(animation.value);
          return SizedBox(
            width: 250,
            height: 320,
            child: Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Positioned.fill(
                  child: Transform.scale(
                    // 1 → 1,04 → 1 cada 1,6 s.
                    scale: 1 + 0.04 * v,
                    child: const CustomPaint(painter: _CornersPainter()),
                  ),
                ),
                // La línea baja de 10 a 300 y vuelve (2 s ida y vuelta).
                Positioned(
                  left: 6,
                  right: 6,
                  top: 10 + 290 * v,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: _accent,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: const <BoxShadow>[
                        BoxShadow(
                          color: _accent,
                          blurRadius: 16,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

class _CornersPainter extends CustomPainter {
  const _CornersPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = _ink
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;
    const double l = 40;
    const double r = 12;
    final double w = size.width;
    final double h = size.height;
    // Cada esquina: dos rayas y la curva de 12 px.
    canvas
      ..drawPath(
        Path()
          ..moveTo(2, l)
          ..lineTo(2, r)
          ..arcToPoint(const Offset(r, 2), radius: const Radius.circular(r - 2))
          ..lineTo(l, 2),
        p,
      )
      ..drawPath(
        Path()
          ..moveTo(w - l, 2)
          ..lineTo(w - r, 2)
          ..arcToPoint(Offset(w - 2, r), radius: const Radius.circular(r - 2))
          ..lineTo(w - 2, l),
        p,
      )
      ..drawPath(
        Path()
          ..moveTo(2, h - l)
          ..lineTo(2, h - r)
          ..arcToPoint(
            Offset(r, h - 2),
            radius: const Radius.circular(r - 2),
            clockwise: false,
          )
          ..lineTo(l, h - 2),
        p,
      )
      ..drawPath(
        Path()
          ..moveTo(w - l, h - 2)
          ..lineTo(w - r, h - 2)
          ..arcToPoint(
            Offset(w - 2, h - r),
            radius: const Radius.circular(r - 2),
            clockwise: false,
          )
          ..lineTo(w - 2, h - l),
        p,
      );
  }

  @override
  bool shouldRepaint(_CornersPainter old) => false;
}

/// "¡Monumento detectado!": el recuadro que se cierra sobre él, con su
/// nombre encima y un aro que late; lo de fuera se oscurece.
class _Lock extends StatefulWidget {
  const _Lock({required this.name});

  final String name;

  @override
  State<_Lock> createState() => _LockState();
}

class _LockState extends State<_Lock> with TickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 500),
  )..forward();
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    Motion.loop(_ring, testCount: 1);
  }

  @override
  void dispose() {
    _in.dispose();
    _ring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge(<Listenable>[_in, _ring]),
        builder: (BuildContext context, Widget? _) {
          final double t = _in.value;
          // 1,25 → 0,96 → 1, como cm-lock.
          final double scale = t < 0.6
              ? 1.25 - 0.29 * (t / 0.6)
              : 0.96 + 0.04 * ((t - 0.6) / 0.4);
          final double ring = _ring.value;
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned.fill(
                child: CustomPaint(
                  painter: _DimPainter(
                    hole: (Size s) =>
                        Rect.fromLTWH(s.width / 2 - 75, 100, 150, 220),
                    opacity: 0.35 * t.clamp(0, 1),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                top: 100,
                child: Center(
                  child: Opacity(
                    opacity: (t / 0.6).clamp(0, 1),
                    child: Transform.scale(
                      scale: scale,
                      child: SizedBox(
                        width: 150,
                        height: 220,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: <Widget>[
                            Positioned.fill(
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(18),
                                  border: Border.all(color: _accent, width: 4),
                                ),
                              ),
                            ),
                            Positioned.fill(
                              child: Transform.scale(
                                scale: 0.8 + 1.1 * ring,
                                child: Opacity(
                                  opacity: (0.9 * (1 - ring)).clamp(0, 1),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(
                                        color: _accent,
                                        width: 3,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              left: -60,
                              right: -60,
                              top: -34,
                              child: Center(
                                child: Container(
                                  height: 26,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: _accent,
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                  child: Text(
                                    widget.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Manrope',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: NomadColors.background,
                                    ),
                                  ),
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
            ],
          );
        },
      ),
    ),
  );
}

/// Oscurece todo menos el recuadro del monumento.
class _DimPainter extends CustomPainter {
  _DimPainter({required this.hole, required this.opacity});

  final Rect Function(Size) hole;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(
          RRect.fromRectAndRadius(hole(size), const Radius.circular(18)),
        ),
      ),
      Paint()..color = NomadColors.background.withValues(alpha: opacity),
    );
  }

  @override
  bool shouldRepaint(_DimPainter old) => old.opacity != opacity;
}

/// El aviso de Flyra: "Estás mirando… ¿Quieres escuchar su audioguía?",
/// las pistas, la barra de 8 s y Cancelar / Aceptar. Flyra vuela al lado.
class _FlyraAsk extends StatefulWidget {
  const _FlyraAsk({
    required this.name,
    required this.signals,
    required this.wait,
    required this.onYes,
    required this.onNo,
  });

  final String name;
  final List<(String, Color)> signals;
  final Duration wait;
  final VoidCallback onYes;
  final VoidCallback onNo;

  @override
  State<_FlyraAsk> createState() => _FlyraAskState();
}

class _FlyraAskState extends State<_FlyraAsk> with TickerProviderStateMixin {
  late final AnimationController _bar = AnimationController(
    vsync: this,
    duration: widget.wait,
  )..forward();
  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    Motion.loop(_fly, reverse: true, testCount: 1);
  }

  @override
  void dispose() {
    _bar.dispose();
    _fly.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 500),
    curve: Curves.easeOutBack,
    builder: (BuildContext context, double v, Widget? child) => Opacity(
      opacity: v.clamp(0, 1),
      child: Transform.translate(offset: Offset(0, 40 * (1 - v)), child: child),
    ),
    child: Semantics(
      liveRegion: true,
      container: true,
      label: 'Monumento detectado',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xF7121B21),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(22),
                  topRight: Radius.circular(22),
                  bottomRight: Radius.circular(6),
                  bottomLeft: Radius.circular(22),
                ),
                border: Border.all(color: const Color(0xFF2E8A5E)),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x8C000000),
                    blurRadius: 40,
                    offset: Offset(0, 16),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Text(
                    'FLYRA · MONUMENTO DETECTADO',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.66,
                      color: Color(0xFF7FF0BF),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        const TextSpan(text: 'Estás mirando '),
                        TextSpan(
                          text: widget.name,
                          style: const TextStyle(color: _accent),
                        ),
                        const TextSpan(
                          text: '. ¿Quieres escuchar su audioguía?',
                        ),
                      ],
                    ),
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 17,
                      height: 1.3,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                    ),
                  ),
                  if (widget.signals.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: <Widget>[
                        for (final (String text, Color c) in widget.signals)
                          _Chip(text: text, color: c),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  // Lo que queda para que el aviso se cierre solo.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: SizedBox(
                      height: 4,
                      child: AnimatedBuilder(
                        animation: _bar,
                        builder: (BuildContext context, Widget? _) =>
                            LinearProgressIndicator(
                              value: _bar.value,
                              minHeight: 4,
                              color: _accent,
                              backgroundColor: const Color(0xFF26363F),
                            ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        flex: 10,
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton(
                            onPressed: widget.onNo,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFDCE5E9),
                              side: const BorderSide(color: Color(0xFF33444E)),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(15),
                              ),
                              textStyle: const TextStyle(
                                fontFamily: 'Manrope',
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            child: const Text('Cancelar'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 14,
                        child: SizedBox(
                          height: 48,
                          child: FilledButton(
                            onPressed: widget.onYes,
                            style: FilledButton.styleFrom(
                              backgroundColor: _accent,
                              foregroundColor: NomadColors.background,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(15),
                              ),
                              textStyle: const TextStyle(
                                fontFamily: 'Manrope',
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                _svg(
                                  'M8 5v14l11-7z',
                                  NomadColors.background,
                                  size: 16,
                                  fill: true,
                                ),
                                const SizedBox(width: 8),
                                const Flexible(
                                  child: Text(
                                    'Aceptar',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Si no tocas nada, el aviso se cierra solo.',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 10.5,
                      color: Color(0xFF6F8490),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          AnimatedBuilder(
            animation: _fly,
            builder: (BuildContext context, Widget? child) {
              final double v = Curves.easeInOut.transform(_fly.value);
              return Transform.translate(
                offset: Offset(0, -5 * v),
                child: Transform.rotate(
                  angle: (-4 + 8 * v) * 3.14159 / 180,
                  child: child,
                ),
              );
            },
            child: Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: NomadColors.background,
                border: Border.all(color: _accent, width: 2),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.asset(
                'assets/map/flyra.webp',
                fit: BoxFit.cover,
                excludeFromSemantics: true,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// "Abriendo la audioguía…": la pantalla verde oscura con las barras que
/// suben y bajan, como en la maqueta.
class _Opening extends StatefulWidget {
  const _Opening({required this.name, required this.language});

  final String name;
  final String language;

  @override
  State<_Opening> createState() => _OpeningState();
}

class _OpeningState extends State<_Opening> with TickerProviderStateMixin {
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  )..forward();

  @override
  void initState() {
    super.initState();
    Motion.loop(_wave, testCount: 1);
  }

  @override
  void dispose() {
    _wave.dispose();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable>[_wave, _in]),
    builder: (BuildContext context, Widget? child) {
      final double z = Curves.easeOutBack.transform(_in.value);
      return Opacity(
        opacity: _in.value,
        child: Transform.scale(
          scale: 0.6 + 0.4 * z,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0, -0.2),
                radius: 0.9,
                colors: <Color>[Color(0xFF13342A), NomadColors.background],
                stops: <double>[0, 0.7],
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  height: 60,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int k = 0; k < 7; k++) ...<Widget>[
                        if (k > 0) const SizedBox(width: 5),
                        Transform.scale(
                          scaleY: _barScale((_wave.value - k * 0.11) % 1),
                          child: Container(
                            width: 7,
                            height: 60,
                            decoration: BoxDecoration(
                              color: _accent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Abriendo la audioguía…',
                  style: TextStyle(
                    fontFamily: 'BricolageGrotesque',
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  '${widget.name} · ${widget.language}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 13,
                    color: Color(0xFF9FB0B8),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  /// 0,3 → 1 → 0,3 a lo largo de la vuelta (cm-wave).
  static double _barScale(double t) =>
      0.3 + 0.7 * Curves.easeInOut.transform(t < 0.5 ? t * 2 : (1 - t) * 2);
}

/// "RECONOCIDO": un punto sobre el monumento, una raya que sube y la
/// etiqueta con su nombre arriba.
class _Pin extends StatelessWidget {
  const _Pin({required this.label, required this.name});

  final String label;
  final String name;

  @override
  Widget build(BuildContext context) => Positioned.fill(
    child: IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 850),
        builder: (BuildContext context, double t, Widget? _) {
          double pop(double from) {
            final double x = ((t - from) / (500 / 850)).clamp(0, 1);
            return x < 0.7
                ? 0.6 + 0.45 * (x / 0.7)
                : 1.05 - 0.05 * ((x - 0.7) / 0.3);
          }

          double seen(double from) => ((t - from) / (350 / 850)).clamp(0, 1);
          final double grow = ((t - 0.2 / 0.85) / (0.5 / 0.85)).clamp(0, 1);
          return Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // El punto sobre el monumento.
              Positioned(
                left: 0,
                right: 0,
                top: 188,
                child: Center(
                  child: Opacity(
                    opacity: seen(0),
                    child: Transform.scale(
                      scale: pop(0),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: _accent, width: 3),
                          boxShadow: const <BoxShadow>[
                            BoxShadow(
                              color: Color(0x403DDC97),
                              spreadRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // La raya que sube del punto a la etiqueta.
              Positioned(
                left: 0,
                right: 0,
                top: 102,
                child: Center(
                  child: Container(width: 3, height: 86 * grow, color: _accent),
                ),
              ),
              Positioned(
                left: 50,
                right: 50,
                top: 50,
                child: Opacity(
                  opacity: seen(0.35 / 0.85),
                  child: Transform.scale(
                    scale: pop(0.35 / 0.85),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xE00B1217),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: _accent, width: 2),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Text(
                            label,
                            style: const TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.66,
                              color: _accent,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: _ink,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ),
  );
}

/// La ficha de abajo: nombre, qué es, 3 datos, su historia, Escuchar y
/// Ver mi sello.
class _Card extends StatelessWidget {
  const _Card({
    required this.landmark,
    required this.speaking,
    required this.onListen,
    required this.onStamp,
  });

  final Landmark landmark;
  final bool speaking;
  final VoidCallback onListen;
  final VoidCallback onStamp;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Landmark l = landmark;
    final int? year = l.year;
    final int? meters = l.distanceM;
    final String rarity = switch (rarityOf(year)) {
      Rarity.common => 'Común',
      Rarity.rare => 'Raro',
      Rarity.epic => 'Épico',
      Rarity.legendary => 'Legendario',
    };
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 500),
      builder: (BuildContext context, double v, Widget? child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 40 * (1 - v)),
          child: child,
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: Container(
          padding: const EdgeInsets.all(16),
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
                Text(
                  l.name,
                  style: const TextStyle(
                    fontFamily: 'BricolageGrotesque',
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.24,
                    color: _ink,
                  ),
                ),
                if (l.description case final String d) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    d,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 13,
                      color: Color(0xFF9FB0B8),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _Fact(
                        label: 'Construida',
                        value: year == null ? 'Sin datos' : '$year',
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _Fact(
                        label: t.cameraDistance,
                        value: meters == null
                            ? 'Sin datos'
                            : t.cameraMeters(meters),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _Fact(label: 'Cromo', value: rarity),
                    ),
                  ],
                ),
                if (l.summary case final String s) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(
                    s,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
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
                      child: SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: onListen,
                          style: FilledButton.styleFrom(
                            backgroundColor: _accent,
                            foregroundColor: NomadColors.background,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            textStyle: const TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              _svg(
                                speaking ? 'M7 6h10v12H7z' : 'M8 5v14l11-7z',
                                NomadColors.background,
                                size: 16,
                                fill: true,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  speaking
                                      ? t.cameraStopListening
                                      : t.cameraListen,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 48,
                        child: OutlinedButton(
                          onPressed: onStamp,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: _ink,
                            side: const BorderSide(color: Color(0xFF33444E)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            textStyle: const TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          child: const Text('Ver mi sello'),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Lo pide la licencia de los textos y las fotos.
                Text(
                  t.cameraCredits,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Manrope',
                    fontSize: 10.5,
                    color: Color(0xFF6F8490),
                  ),
                ),
              ],
            ),
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
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
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
            fontFamily: 'Manrope',
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Color(0xFF9FB0B8),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'Manrope',
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: _ink,
          ),
        ),
      ],
    ),
  );
}
