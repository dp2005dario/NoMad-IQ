// Aeropuerto, igual que la maqueta "Aeropuerto": la cámara de fondo con
// flechas verdes que van hacia donde tienes que ir, arriba qué hacer ("Gira
// a la derecha"), Flyra que te lo dice (voz y vibración) y abajo a dónde
// vas (tu puerta, el baño o un café) con los minutos y los metros.
//
// Funciona como una brújula: el GPS dice dónde estás, la brújula hacia dónde
// miras y la guía (OpenStreetMap) dónde está cada sitio. No es navegación
// giro a giro con pasillos (para eso haría falta un mapa de interiores que
// no existe gratis para todos los aeropuertos), pero dentro de una terminal
// "por ahí y a 300 m" ya ayuda mucho; y la pantalla avisa de que sigas
// también los carteles.
//
// Abajo, Flyra te dice el giro ("Gira a la izquierda") en voz alta y con
// una vibración distinta para cada lado, por si no sabes leer las flechas
// o vas mirando la maleta. La voz se puede apagar con el altavoz.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../route/geo.dart' show LatLon;
import '../route/world_data.dart';
import '../sos/where_am_i.dart' show nearestAirport;
import '../../core/motion.dart';
import '../camera/camera_device.dart';
import 'airport_guide.dart';

/// El texto de cada indicación (en la tarjeta y en el aviso de Flyra).
String cueText(AppLocalizations t, Cue cue, int meters) => switch (cue) {
  Cue.arrived => t.airportArrived,
  Cue.straight => t.airportStraight(meters),
  Cue.left => t.airportLeft,
  Cue.right => t.airportRight,
  Cue.back => t.airportBack,
};

/// La vibración de cada giro: izquierda = 1 toque, derecha = 2, darse la
/// vuelta = 3 y llegar = uno suave. Así se nota sin mirar el móvil.
Future<void> vibrateFor(Cue cue) async {
  final int times = switch (cue) {
    Cue.left => 1,
    Cue.right => 2,
    Cue.back => 3,
    Cue.arrived || Cue.straight => 0,
  };
  if (cue == Cue.arrived) {
    await HapticFeedback.lightImpact();
    return;
  }
  for (int i = 0; i < times; i++) {
    if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 220));
    await HapticFeedback.heavyImpact();
  }
}

String spotKindLabel(AppLocalizations t, SpotKind k) => switch (k) {
  SpotKind.gate => t.airportKindGate,
  SpotKind.toilets => t.airportKindToilets,
  SpotKind.cafe => t.airportKindCafe,
  SpotKind.food => t.airportKindFood,
  SpotKind.pharmacy => t.airportKindPharmacy,
  SpotKind.atm => t.airportKindAtm,
  SpotKind.water => t.airportKindWater,
  SpotKind.info => t.airportKindInfo,
  SpotKind.charging => t.airportKindCharging,
  SpotKind.lounge => t.airportKindLounge,
  SpotKind.train => t.transportModeTrain,
  SpotKind.metro => t.transportModeMetro,
  SpotKind.tram => t.transportModeTram,
  SpotKind.bus => t.transportModeBus,
  SpotKind.taxi => t.transportModeTaxi,
};

IconData spotKindIcon(SpotKind k) => switch (k) {
  SpotKind.gate => Icons.flight_takeoff_rounded,
  SpotKind.toilets => Icons.wc_rounded,
  SpotKind.cafe => Icons.local_cafe_rounded,
  SpotKind.food => Icons.restaurant_rounded,
  SpotKind.pharmacy => Icons.local_pharmacy_rounded,
  SpotKind.atm => Icons.local_atm_rounded,
  SpotKind.water => Icons.water_drop_rounded,
  SpotKind.info => Icons.info_rounded,
  SpotKind.charging => Icons.power_rounded,
  SpotKind.lounge => Icons.weekend_rounded,
  SpotKind.train => Icons.train_rounded,
  SpotKind.metro => Icons.subway_rounded,
  SpotKind.tram => Icons.tram_rounded,
  SpotKind.bus => Icons.directions_bus_rounded,
  SpotKind.taxi => Icons.local_taxi_rounded,
};

/// Los 3 botones de abajo, como en la maqueta: Puerta, Baño y Café.
const List<SpotKind> _order = <SpotKind>[
  SpotKind.gate,
  SpotKind.toilets,
  SpotKind.cafe,
];

class AirportScreen extends StatefulWidget {
  const AirportScreen({super.key, this.iata, this.gate});

  final String? iata;
  final String? gate;

  @override
  State<AirportScreen> createState() => _AirportScreenState();
}

class _AirportScreenState extends State<AirportScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final EasyTrip _trip = loadEasyTrip(_services.prefs);
  late final TextEditingController _code = TextEditingController(
    text: widget.iata ?? '',
  );
  late final TextEditingController _gate = TextEditingController(
    text: widget.gate ?? _trip.gate ?? '',
  );

  String? _iata;
  AirportGuide? _guide;
  ApiError? _error;
  bool _unknown = false;
  bool _loading = false;
  SpotKind _target = SpotKind.gate;

  LocationAccess? _access;
  GeoPoint? _here;
  double? _heading;
  StreamSubscription<PositionFix>? _fixes;
  StreamSubscription<double?>? _compass;

  /// Flyra habla (true) o solo enseña el aviso (false). Como en la
  /// maqueta, empieza callada y vibrando.
  bool _voice = false;
  bool _vibrate = true;

  /// El aviso de Flyra se puede esconder ("Dime los giros" lo vuelve a
  /// poner).
  bool _flyra = true;

  /// Los metros que había al elegir el destino (para la barra de avance).
  int? _startM;

  /// La cámara de fondo (si el móvil tiene y nos deja).
  CameraDevice? _camera;

  /// El nombre del aeropuerto para arriba ("Madrid · MAD").
  String? _place;
  final TurnAnnouncer _announcer = TurnAnnouncer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_start());
      unawaited(_startCamera());
    });
  }

  /// La cámara de fondo, como en la maqueta. Sin cámara o sin permiso, el
  /// fondo es oscuro y todo lo demás funciona igual.
  Future<void> _startCamera() async {
    final CameraFactory? make = _services.newCamera;
    if (make == null) return;
    final CameraDevice camera = make();
    final CameraStart started = await camera.start();
    if (!mounted || started != CameraStart.ready) {
      await camera.dispose();
      return;
    }
    setState(() => _camera = camera);
  }

  @override
  void dispose() {
    unawaited(_camera?.dispose());
    unawaited(_fixes?.cancel());
    unawaited(_compass?.cancel());
    _code.dispose();
    _gate.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final LocationSource gps = _services.location;
    final LocationAccess access = await gps.check();
    if (!mounted) return;
    setState(() => _access = access);
    if (access == LocationAccess.granted) _listen();

    // ¿Qué aeropuerto? El que te pasan, el de tu vuelo de hoy o el más
    // cercano a donde estás.
    String? iata = widget.iata;
    final DateTime? dep = _trip.departure;
    if (iata == null &&
        _trip.from != null &&
        dep != null &&
        dep.isAfter(DateTime.now().subtract(const Duration(hours: 2))) &&
        dep.isBefore(DateTime.now().add(const Duration(hours: 24)))) {
      iata = _trip.from;
    }
    if (iata == null && access == LocationAccess.granted) {
      try {
        final PositionFix fix = await gps.watch().first.timeout(
          const Duration(seconds: 8),
        );
        final Airports airports = await _services.loadAirports();
        final Airport? a = nearestAirport(
          airports.all,
          LatLon(fix.point.lat, fix.point.lon),
        );
        if (a != null &&
            fix.point.distanceTo(GeoPoint(a.position.lat, a.position.lon)) <
                15000) {
          iata = a.iata;
        }
      } on Object {
        // Sin GPS a tiempo: se pregunta el aeropuerto.
      }
    }
    if (iata != null) await _open(iata);
  }

  void _listen() {
    _fixes ??= _services.location.watch().listen((PositionFix f) {
      setState(() => _here = f.point);
      _announce();
    }, onError: (Object _) {});
    _compass ??= _services.compass().listen((double? h) {
      setState(() => _heading = h);
      _announce();
    }, onError: (Object _) {});
  }

  Future<void> _allow() async {
    final LocationAccess a = await _services.location.request();
    if (!mounted) return;
    setState(() => _access = a);
    if (a == LocationAccess.granted) _listen();
  }

  Future<void> _open(String raw) async {
    final String iata = raw.trim().toUpperCase();
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(iata)) return;
    setState(() {
      _iata = iata;
      _code.text = iata;
      _loading = true;
      _error = null;
      _unknown = false;
      _guide = null;
    });
    try {
      final AirportGuide g = await _services.airportGuide.get(iata);
      if (!mounted) return;
      unawaited(_name(iata));
      setState(() {
        _guide = g;
        // Sin número de puerta, empieza por el baño.
        if (_gate.text.trim().isEmpty) _target = SpotKind.toilets;
      });
      _announcer.reset();
      _announce();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _unknown = e.error == ApiError.notFound;
        _error = e.error == ApiError.notFound ? null : e.error;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// "Madrid · MAD" para arriba (la ciudad sale de la lista de aeropuertos).
  Future<void> _name(String iata) async {
    try {
      final Airports all = await _services.loadAirports();
      final Airport? a = all[iata];
      if (mounted && a != null) setState(() => _place = '${a.city} · $iata');
    } on Object {
      // Sin la lista: solo el código.
    }
  }

  /// La indicación de ahora (y a cuántos metros), o null si falta algo.
  (Cue, int)? _cue() {
    final AirportGuide? g = _guide;
    final GeoPoint? me = _here;
    if (g == null || me == null) return null;
    final AirportSpot? s = _targetSpot(g);
    if (s == null) return null;
    final double bearing = bearingTo(me, s.point);
    final double? facing = _heading;
    final double relative = facing == null ? bearing : bearing - facing;
    final double meters = me.distanceTo(s.point);
    return (cueFor(meters, relative), meters.round());
  }

  /// Si toca, Flyra dice el giro en voz alta y el móvil vibra.
  void _announce() {
    if (!mounted) return;
    final (Cue, int)? now = _cue();
    if (now == null) return;
    _startM ??= now.$2;
    final Cue? say = _announcer.update(now.$1, DateTime.now());
    if (say == null) return;
    if (_vibrate) unawaited(vibrateFor(say));
    if (!_voice) return;
    final AppLocalizations t = AppLocalizations.of(context);
    unawaited(
      _services.speaker.speak(
        cueText(t, say, now.$2),
        Localizations.localeOf(context).languageCode,
      ),
    );
  }

  void _retarget(SpotKind k) {
    setState(() {
      _target = k;
      _startM = null;
    });
    _announcer.reset();
    _announce();
  }

  AirportSpot? _targetSpot(AirportGuide g) {
    if (_target == SpotKind.gate) {
      final String ref = _gate.text.trim();
      return ref.isEmpty ? null : g.gate(ref);
    }
    final GeoPoint? here = _here;
    return here == null
        ? g.spots.where((AirportSpot s) => s.kind == _target).firstOrNull
        : g.nearest(_target, here);
  }

  // --- Dibujo ----------------------------------------------------------------

  /// Lo de arriba (la tarjeta grande): qué hacer ahora y una línea más.
  (String, String, Cue?, VoidCallback?) _instruction(AppLocalizations t) {
    final AirportGuide? g = _guide;
    if (_loading) return ('Buscando el aeropuerto…', '', null, null);
    if (g == null) {
      return (
        t.airportPick,
        _unknown
            ? t.airportUnknown
            : _error == null
            ? 'Escribe abajo su código de 3 letras'
            : _error == ApiError.unavailable
            ? t.airportBusy
            : _error == ApiError.network
            ? t.errorNetwork
            : t.errorUnavailable,
        null,
        null,
      );
    }
    if (g.spots.isEmpty) return (t.airportEmpty, '', null, null);
    final AirportSpot? s = _targetSpot(g);
    if (s == null) {
      final String gate = _gate.text.trim();
      return (
        _target == SpotKind.gate
            ? (gate.isEmpty ? t.airportGateField : t.airportGateNotFound(gate))
            : t.airportNone,
        '',
        null,
        null,
      );
    }
    final (Cue, int)? cue = _cue();
    if (cue == null) {
      return (
        t.airportNoGps,
        _access == LocationAccess.granted ? '' : t.airportAllowGps,
        null,
        _access == LocationAccess.granted ? null : () => unawaited(_allow()),
      );
    }
    final String level = s.level == null
        ? ''
        : '${t.airportLevel(s.level!)} · ';
    return (
      cueText(t, cue.$1, cue.$2),
      cue.$1 == Cue.arrived ? 'Ya estás' : '${level}Sigue también los carteles',
      cue.$1,
      null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final AirportGuide? g = _guide;
    final (Cue, int)? cue = _cue();
    final (String, String, Cue?, VoidCallback?) top = _instruction(t);
    final AirportSpot? spot = g == null ? null : _targetSpot(g);
    final int? m = cue?.$2;
    final int? start = _startM;
    final double pct = m == null || start == null || start == 0
        ? 0
        : (1 - m / start).clamp(0, 1).toDouble();
    final DateTime? board = g != null && _trip.from == g.iata
        ? _trip.departure?.subtract(const Duration(minutes: 40))
        : null;
    return Scaffold(
      backgroundColor: NomadColors.background,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // La cámara de fondo (o el fondo oscuro si no hay).
          _camera?.preview() ??
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: <Color>[Color(0xFF16232B), NomadColors.background],
                  ),
                ),
              ),
          // Las flechas verdes que van hacia donde tienes que ir.
          if (cue != null && cue.$1 != Cue.arrived) _Arrows(cue: cue.$1),
          SafeArea(
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 16,
                  right: 16,
                  top: 18,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          _Close(onTap: () => Navigator.of(context).maybePop()),
                          Expanded(
                            child: Center(
                              child: _Pill(
                                text: _place ?? _iata ?? t.airportTitle,
                              ),
                            ),
                          ),
                          const SizedBox(width: 44),
                        ],
                      ),
                      const SizedBox(height: 10),
                      _TurnCard(
                        text: top.$1,
                        sub: top.$2,
                        cue: top.$3,
                        onTap: top.$4,
                      ),
                    ],
                  ),
                ),
                if (cue != null && _flyra)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 214,
                    child: _FlyraGuide(
                      text: cueText(t, cue.$1, cue.$2),
                      cue: cue.$1,
                      meters: cue.$2,
                      progress: pct,
                      voice: _voice,
                      vibrate: _vibrate,
                      onVoice: () {
                        setState(() => _voice = !_voice);
                        if (_voice) {
                          unawaited(
                            _services.speaker.speak(
                              cueText(t, cue.$1, cue.$2),
                              Localizations.localeOf(context).languageCode,
                            ),
                          );
                        } else {
                          unawaited(_services.speaker.stop());
                        }
                      },
                      onVibrate: () => setState(() => _vibrate = !_vibrate),
                      onHide: () => setState(() => _flyra = false),
                    ),
                  ),
                if (cue != null && !_flyra)
                  Positioned(
                    right: 16,
                    bottom: 214,
                    child: _TellMe(onTap: () => setState(() => _flyra = true)),
                  ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 16,
                  child: _Destination(
                    kind: g == null
                        ? 'TU AEROPUERTO'
                        : switch (_target) {
                            SpotKind.gate => 'TU PUERTA',
                            final SpotKind k => spotKindLabel(
                              t,
                              k,
                            ).toUpperCase(),
                          },
                    field: g == null
                        ? _code
                        : _target == SpotKind.gate
                        ? _gate
                        : null,
                    fieldHint: g == null ? 'MAD' : 'K42',
                    onField: (String v) {
                      if (g == null) {
                        unawaited(_open(v));
                      } else {
                        _retarget(SpotKind.gate);
                      }
                    },
                    name: spot == null
                        ? ''
                        : spot.kind == SpotKind.gate
                        ? (spot.ref ?? '')
                        : spot.name ?? spotKindLabel(t, spot.kind),
                    minutes: m == null
                        ? ''
                        : cue!.$1 == Cue.arrived
                        ? 'Ya estás'
                        : '${walkMinutes(m.toDouble())} min',
                    meters: m == null
                        ? ''
                        : <String>[
                            '$m m',
                            if (board != null && _target == SpotKind.gate)
                              'embarque ${DateFormat.Hm(locale).format(board)}',
                          ].join(' · '),
                    progress: pct,
                    stops: g == null || g.spots.isEmpty
                        ? const <SpotKind>[]
                        : _order,
                    target: _target,
                    onStop: _retarget,
                    credits: g?.attribution,
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

/// La flecha de cada giro (las de la maqueta).
String _turnIcon(Cue? cue) => switch (cue) {
  Cue.left => 'M19 12H5M11 6l-6 6 6 6',
  Cue.right => 'M5 12h14M13 6l6 6-6 6',
  Cue.back => 'M12 4v16M6 14l6 6 6-6',
  Cue.arrived => 'M5 13l4 4L19 7',
  Cue.straight || null => 'M12 20V4M6 10l6-6 6 6',
};

const Color _accent = NomadColors.mint;
const Color _ink = Color(0xFFF2F5F3);

class _Close extends StatelessWidget {
  const _Close({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: MaterialLocalizations.of(context).closeButtonTooltip,
    child: Material(
      color: const Color(0xBF0B1217),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(child: _svg('M6 6l12 12M18 6L6 18', _ink, width: 2.4)),
        ),
      ),
    ),
  );
}

/// "Madrid · MAD" con el punto verde que parpadea.
class _Pill extends StatefulWidget {
  const _Pill({required this.text});

  final String text;

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> with SingleTickerProviderStateMixin {
  late final AnimationController _blink = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    Motion.loop(_blink, reverse: true);
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    height: 34,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: const Color(0xBF0B1217),
      borderRadius: BorderRadius.circular(17),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        FadeTransition(
          opacity: Tween<double>(begin: 1, end: 0.3).animate(_blink),
          child: Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: _accent,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            widget.text,
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
  );
}

/// La tarjeta de arriba: la flecha que se balancea y qué hacer.
class _TurnCard extends StatefulWidget {
  const _TurnCard({
    required this.text,
    required this.sub,
    required this.cue,
    this.onTap,
  });

  final String text;
  final String sub;
  final Cue? cue;
  final VoidCallback? onTap;

  @override
  State<_TurnCard> createState() => _TurnCardState();
}

class _TurnCardState extends State<_TurnCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _sway = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  );

  @override
  void initState() {
    super.initState();
    Motion.loop(_sway, reverse: true);
  }

  @override
  void dispose() {
    _sway.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    child: Semantics(
      liveRegion: true,
      button: widget.onTap != null,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xE60B1217),
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(
          children: <Widget>[
            AnimatedBuilder(
              animation: _sway,
              builder: (BuildContext context, Widget? child) =>
                  Transform.translate(
                    offset: Offset(
                      4 * Curves.easeInOut.transform(_sway.value),
                      0,
                    ),
                    child: child,
                  ),
              child: Container(
                width: 52,
                height: 52,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _svg(
                  _turnIcon(widget.cue),
                  NomadColors.background,
                  size: 30,
                  width: 2.6,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    widget.text,
                    style: const TextStyle(
                      fontFamily: 'BricolageGrotesque',
                      fontSize: 20,
                      height: 1.1,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                    ),
                  ),
                  if (widget.sub.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      widget.sub,
                      style: TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 13,
                        fontWeight: widget.onTap == null
                            ? FontWeight.w400
                            : FontWeight.w800,
                        color: widget.onTap == null
                            ? const Color(0xFFB7C5CC)
                            : _accent,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Las 4 flechas verdes que suben y se alejan, giradas hacia donde vas.
class _Arrows extends StatefulWidget {
  const _Arrows({required this.cue});

  final Cue cue;

  @override
  State<_Arrows> createState() => _ArrowsState();
}

class _ArrowsState extends State<_Arrows> with SingleTickerProviderStateMixin {
  late final AnimationController _go = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    Motion.loop(_go, testCount: 1);
  }

  @override
  void dispose() {
    _go.dispose();
    super.dispose();
  }

  static const String _arrow =
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 110 70">'
      '<path d="M55 4 L104 50 L80 50 L80 66 L30 66 L30 50 L6 50 Z" '
      'fill="#3DDC97" fill-opacity="0.85" stroke="#B5F3D6" '
      'stroke-width="2"/></svg>';

  @override
  Widget build(BuildContext context) {
    final double turn = switch (widget.cue) {
      Cue.left => -35,
      Cue.right => 35,
      Cue.back => 180,
      _ => 0,
    };
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) =>
            TweenAnimationBuilder<double>(
              tween: Tween<double>(end: turn),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutBack,
              builder: (BuildContext context, double deg, Widget? child) =>
                  Transform.rotate(
                    angle: deg * 3.14159265 / 180,
                    // Gira alrededor de un punto abajo (50 % 85 %).
                    origin: Offset(0, box.maxHeight * 0.35),
                    child: child,
                  ),
              child: AnimatedBuilder(
                animation: _go,
                builder: (BuildContext context, Widget? _) => Stack(
                  children: <Widget>[
                    for (int i = 0; i < 4; i++)
                      _one((_go.value + 1 - i * 0.25) % 1, box.maxWidth),
                  ],
                ),
              ),
            ),
      ),
    );
  }

  /// Una flecha en su momento [t] (0 → 1): sube 260, se encoge y se apaga.
  Widget _one(double t, double width) {
    final double opacity = t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85;
    return Positioned(
      left: width / 2 - 55,
      bottom: 150,
      child: Opacity(
        opacity: opacity.clamp(0, 1),
        child: Transform.translate(
          offset: Offset(0, -260 * t),
          child: Transform.scale(
            scale: 1 - 0.65 * t,
            child: SvgPicture.string(_arrow, width: 110, height: 70),
          ),
        ),
      ),
    );
  }
}

/// El aviso de Flyra: el giro en grande, la barra de avance, la voz, la
/// vibración y la X para esconderla.
class _FlyraGuide extends StatefulWidget {
  const _FlyraGuide({
    required this.text,
    required this.cue,
    required this.meters,
    required this.progress,
    required this.voice,
    required this.vibrate,
    required this.onVoice,
    required this.onVibrate,
    required this.onHide,
  });

  final String text;
  final Cue cue;
  final int meters;
  final double progress;
  final bool voice;
  final bool vibrate;
  final VoidCallback onVoice;
  final VoidCallback onVibrate;
  final VoidCallback onHide;

  @override
  State<_FlyraGuide> createState() => _FlyraGuideState();
}

class _FlyraGuideState extends State<_FlyraGuide>
    with TickerProviderStateMixin {
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );
  late final AnimationController _ring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void initState() {
    super.initState();
    Motion.loop(_bob, reverse: true);
    Motion.loop(_ring);
    _syncWave();
  }

  @override
  void didUpdateWidget(_FlyraGuide old) {
    super.didUpdateWidget(old);
    if (old.voice != widget.voice) _syncWave();
  }

  /// Las ondas de "Voz" solo se mueven con la voz puesta.
  void _syncWave() {
    if (widget.voice) {
      Motion.loop(_wave);
    } else {
      _wave
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _bob.dispose();
    _ring.dispose();
    _wave.dispose();
    super.dispose();
  }

  Widget _toggle({
    required bool on,
    required Widget child,
    required VoidCallback onTap,
    required String label,
  }) => Semantics(
    button: true,
    toggled: on,
    label: label,
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: on ? _accent : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: on ? null : Border.all(color: const Color(0xFF33444E)),
        ),
        child: DefaultTextStyle.merge(
          style: TextStyle(
            fontFamily: 'Manrope',
            fontSize: 12,
            fontWeight: FontWeight.w800,
            color: on ? NomadColors.background : const Color(0xFFDCE5E9),
          ),
          child: child,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final Cue cue = widget.cue;
    final Color waveColor = widget.voice
        ? NomadColors.background
        : const Color(0xFFDCE5E9);
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          AnimatedBuilder(
            animation: Listenable.merge(<Listenable>[_bob, _ring]),
            builder: (BuildContext context, Widget? child) {
              final double v = Curves.easeInOut.transform(_bob.value);
              return Transform.translate(
                offset: Offset(0, -4 * v),
                child: Transform.rotate(
                  angle: (-4 + 8 * v) * 3.14159265 / 180,
                  child: SizedBox(
                    width: 54,
                    height: 54,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: <Widget>[
                        Positioned.fill(
                          child: Transform.scale(
                            scale: 0.8 + 0.9 * _ring.value,
                            child: Opacity(
                              opacity: 0.8 * (1 - _ring.value),
                              child: Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: _accent, width: 2),
                                ),
                              ),
                            ),
                          ),
                        ),
                        child!,
                      ],
                    ),
                  ),
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
          const SizedBox(width: 10),
          Expanded(
            child: TweenAnimationBuilder<double>(
              key: ValueKey<Cue>(cue),
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 450),
              curve: Curves.easeOutBack,
              builder: (BuildContext context, double v, Widget? child) =>
                  Opacity(
                    opacity: v.clamp(0, 1),
                    child: Transform.translate(
                      offset: Offset(0, 16 * (1 - v)),
                      child: child,
                    ),
                  ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xF7121B21),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(18),
                    bottomRight: Radius.circular(6),
                    bottomLeft: Radius.circular(18),
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
                    Row(
                      children: <Widget>[
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: cue == Cue.arrived
                                ? const Color(0xFFFFD166)
                                : cue == Cue.straight
                                ? const Color(0xFF7FF0BF)
                                : _accent,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: _svg(
                            _turnIcon(cue),
                            NomadColors.background,
                            size: 28,
                            width: 2.8,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'FLYRA TE GUÍA · A ${widget.meters} M',
                                style: const TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.55,
                                  color: Color(0xFF7FF0BF),
                                ),
                              ),
                              const SizedBox(height: 1),
                              Text(
                                widget.text,
                                style: const TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 17,
                                  height: 1.2,
                                  fontWeight: FontWeight.w800,
                                  color: _ink,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: widget.progress,
                        minHeight: 4,
                        color: _accent,
                        backgroundColor: const Color(0xFF26363F),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        // Si no caben (letra grande), se encogen un poco.
                        Expanded(
                          child: Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  _toggle(
                                    on: widget.voice,
                                    label: AppLocalizations.of(context)
                                        .airportVoice,
                                    onTap: widget.onVoice,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        AnimatedBuilder(
                                          animation: _wave,
                                          builder: (BuildContext context, Widget? _) => Row(
                                            children: <Widget>[
                                              for (
                                                int k = 0;
                                                k < 3;
                                                k++
                                              ) ...<Widget>[
                                                if (k > 0)
                                                  const SizedBox(width: 2),
                                                Transform.scale(
                                                  scaleY: widget.voice
                                                      ? 0.35 +
                                                            0.65 *
                                                                Curves.easeInOut.transform(
                                                                  ((_wave.value + k * 0.21) %
                                                                              1 <
                                                                          0.5)
                                                                      ? ((_wave.value + k * 0.21) %
                                                                                1) *
                                                                            2
                                                                      : (1 - (_wave.value + k * 0.21) % 1) * 2,
                                                                )
                                                      : 0.4,
                                                  child: Container(
                                                    width: 3,
                                                    height: 14,
                                                    decoration: BoxDecoration(
                                                      color: waveColor,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            2,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          widget.voice ? 'Voz' : 'Voz apagada',
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _toggle(
                                    on: widget.vibrate,
                                    label: 'Vibrar',
                                    onTap: widget.onVibrate,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: <Widget>[
                                        Text(
                                          widget.vibrate
                                              ? '📳 Vibrar'
                                              : '📳 Sin vibrar',
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message: 'Ocultar a Flyra',
                          child: GestureDetector(
                            onTap: widget.onHide,
                            child: Container(
                              width: 32,
                              height: 32,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFF33444E),
                                ),
                              ),
                              child: const Text(
                                '✕',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Color(0xFF9FB0B8),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Dime los giros": vuelve a poner el aviso de Flyra.
class _TellMe extends StatelessWidget {
  const _TellMe({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Que Flyra me diga los giros',
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        padding: const EdgeInsets.fromLTRB(4, 0, 12, 0),
        decoration: BoxDecoration(
          color: NomadColors.background,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: _accent, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ClipOval(
              child: Image.asset(
                'assets/map/flyra.webp',
                width: 34,
                height: 34,
                excludeFromSemantics: true,
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Dime los giros',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: _ink,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// El panel de abajo: a dónde vas (o el campo para escribirlo), minutos,
/// metros, la barra de avance y Puerta / Baño / Café.
class _Destination extends StatelessWidget {
  const _Destination({
    required this.kind,
    required this.field,
    required this.fieldHint,
    required this.onField,
    required this.name,
    required this.minutes,
    required this.meters,
    required this.progress,
    required this.stops,
    required this.target,
    required this.onStop,
    required this.credits,
  });

  final String kind;

  /// Para escribir el aeropuerto o tu puerta (null = no se escribe).
  final TextEditingController? field;
  final String fieldHint;
  final ValueChanged<String> onField;
  final String name;
  final String minutes;
  final String meters;
  final double progress;
  final List<SpotKind> stops;
  final SpotKind target;
  final ValueChanged<SpotKind> onStop;
  final String? credits;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    const TextStyle big = TextStyle(
      fontFamily: 'BricolageGrotesque',
      fontSize: 34,
      height: 1,
      fontWeight: FontWeight.w800,
      color: _ink,
    );
    final TextEditingController? f = field;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xF5141E25),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF26363F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      kind,
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.66,
                        color: Color(0xFF9FB0B8),
                      ),
                    ),
                    if (f != null)
                      TextField(
                        controller: f,
                        style: big,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.go,
                        onChanged: kind == 'TU AEROPUERTO' ? null : onField,
                        onSubmitted: onField,
                        decoration: InputDecoration(
                          hintText: fieldHint,
                          hintStyle: big.copyWith(
                            color: const Color(0xFF3A4C56),
                          ),
                          isCollapsed: true,
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                        ),
                      )
                    else
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: big,
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text(
                    minutes,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: _ink,
                    ),
                  ),
                  Text(
                    meters,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 12,
                      color: Color(0xFF9FB0B8),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: progress),
              duration: const Duration(milliseconds: 600),
              builder: (BuildContext context, double v, Widget? _) =>
                  LinearProgressIndicator(
                    value: v,
                    minHeight: 8,
                    color: _accent,
                    backgroundColor: const Color(0xFF26363F),
                  ),
            ),
          ),
          if (stops.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                for (final SpotKind k in stops) ...<Widget>[
                  if (k != stops.first) const SizedBox(width: 6),
                  Expanded(
                    child: Semantics(
                      button: true,
                      selected: k == target,
                      child: GestureDetector(
                        onTap: () => onStop(k),
                        child: Container(
                          height: 38,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: k == target
                                ? _accent
                                : const Color(0xFF1C2A33),
                            borderRadius: BorderRadius.circular(12),
                            border: k == target
                                ? null
                                : Border.all(color: const Color(0xFF26363F)),
                          ),
                          child: Text(
                            spotKindLabel(t, k),
                            style: TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: k == target
                                  ? NomadColors.background
                                  : _ink,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (credits case final String c) ...<Widget>[
            const SizedBox(height: 6),
            // Lo pide la licencia de OpenStreetMap.
            Text(
              c,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontSize: 10,
                color: Color(0xFF6F8490),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
