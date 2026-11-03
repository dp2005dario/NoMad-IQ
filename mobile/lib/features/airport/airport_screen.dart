// Aeropuerto (maqueta "Aeropuerto"): una flecha que apunta a tu puerta, al
// baño más cercano o a un café, con los metros y los minutos andando.
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
import '../../widgets/flyra_avatar.dart';
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

/// Lo que se ofrece en los botones, en este orden (como la maqueta: puerta,
/// baño, café... y el resto detrás).
const List<SpotKind> _order = <SpotKind>[
  SpotKind.gate,
  SpotKind.toilets,
  SpotKind.cafe,
  SpotKind.food,
  SpotKind.water,
  SpotKind.pharmacy,
  SpotKind.atm,
  SpotKind.charging,
  SpotKind.info,
  SpotKind.lounge,
  SpotKind.train,
  SpotKind.metro,
  SpotKind.bus,
  SpotKind.taxi,
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

  /// Flyra habla (true) o solo enseña el aviso (false).
  bool _voice = true;
  final TurnAnnouncer _announcer = TurnAnnouncer();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  @override
  void dispose() {
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
    final Cue? say = _announcer.update(now.$1, DateTime.now());
    if (say == null) return;
    unawaited(vibrateFor(say));
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
    setState(() => _target = k);
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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final AirportGuide? g = _guide;
    final (Cue, int)? cue = _cue();
    return Scaffold(
      appBar: AppBar(title: Text(t.airportTitle)),
      bottomNavigationBar: cue == null
          ? null
          : _FlyraTurn(
              text: cueText(t, cue.$1, cue.$2),
              cue: cue.$1,
              voice: _voice,
              onVoice: () {
                setState(() => _voice = !_voice);
                if (!_voice) unawaited(_services.speaker.stop());
              },
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: <Widget>[
          if (_iata == null || _unknown || g == null && !_loading) ...<Widget>[
            Text(t.airportPick, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _code,
                    maxLength: 3,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: t.airportCode,
                      counterText: '',
                    ),
                    onSubmitted: (String v) => unawaited(_open(v)),
                  ),
                ),
                const SizedBox(width: 8),
                // El tema da a los botones ancho infinito: dentro de una
                // fila hace falta decirle cuánto mide.
                SizedBox(
                  width: 120,
                  child: FilledButton(
                    onPressed: () => unawaited(_open(_code.text)),
                    child: Text(t.airportOpen),
                  ),
                ),
              ],
            ),
            if (_unknown) Text(t.airportUnknown),
            if (_error != null)
              Text(
                _error == ApiError.unavailable
                    ? t.airportBusy
                    : _error == ApiError.network
                    ? t.errorNetwork
                    : t.errorUnavailable,
              ),
            const SizedBox(height: 12),
          ],
          if (_loading) const LinearProgressIndicator(),
          if (g != null) ..._guideView(t, g),
        ],
      ),
    );
  }

  List<Widget> _guideView(AppLocalizations t, AirportGuide g) {
    if (g.spots.isEmpty) {
      return <Widget>[
        Text(g.iata, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(t.airportEmpty),
        TextButton(
          onPressed: () => setState(() => _guide = null),
          child: Text(t.airportChange),
        ),
      ];
    }
    final Set<SpotKind> present = <SpotKind>{
      for (final AirportSpot s in g.spots) s.kind,
    };
    final List<SpotKind> kinds = <SpotKind>[
      for (final SpotKind k in _order)
        if (present.contains(k)) k,
    ];
    final AirportSpot? target = _targetSpot(g);
    return <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              g.iata,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          Flexible(
            child: TextButton(
              onPressed: () => setState(() => _guide = null),
              child: Text(t.airportChange, textAlign: TextAlign.end),
            ),
          ),
        ],
      ),
      if (present.contains(SpotKind.gate))
        TextField(
          controller: _gate,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: t.airportGateField),
          onChanged: (_) => _retarget(_target),
        ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final SpotKind k in kinds)
            ChoiceChip(
              selected: k == _target,
              avatar: Icon(spotKindIcon(k), size: 18),
              label: Text(spotKindLabel(t, k)),
              onSelected: (_) => _retarget(k),
            ),
        ],
      ),
      const SizedBox(height: 16),
      _Navigator(
        target: target,
        kind: _target,
        gate: _gate.text.trim(),
        here: _here,
        heading: _heading,
        access: _access,
        boarding: _trip.from == g.iata ? _trip.departure : null,
        onAllow: () => unawaited(_allow()),
      ),
      const SizedBox(height: 12),
      Text(
        t.airportGpsNote,
        style: const TextStyle(color: NomadColors.textMuted),
      ),
      const SizedBox(height: 8),
      Text(g.attribution, style: Theme.of(context).textTheme.bodySmall),
    ];
  }
}

/// La tarjeta de la maqueta: flecha grande, qué hacer, a cuánto y si te da
/// tiempo a embarcar.
class _Navigator extends StatelessWidget {
  const _Navigator({
    required this.target,
    required this.kind,
    required this.gate,
    required this.here,
    required this.heading,
    required this.access,
    required this.boarding,
    required this.onAllow,
  });

  final AirportSpot? target;
  final SpotKind kind;
  final String gate;
  final GeoPoint? here;
  final double? heading;
  final LocationAccess? access;
  final DateTime? boarding;
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final AirportSpot? s = target;
    if (s == null) {
      return _box(
        Text(
          kind == SpotKind.gate
              ? (gate.isEmpty
                    ? t.airportGateField
                    : t.airportGateNotFound(gate))
              : t.airportNone,
        ),
      );
    }
    final String title = s.kind == SpotKind.gate
        ? '${t.airportKindGate} ${s.ref ?? ''}'
        : s.name ?? spotKindLabel(t, s.kind);
    final GeoPoint? me = here;
    if (me == null) {
      return _box(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            if (s.level != null) Text(t.airportLevel(s.level!)),
            const SizedBox(height: 8),
            Text(t.airportNoGps),
            if (access != LocationAccess.granted)
              TextButton(onPressed: onAllow, child: Text(t.airportAllowGps)),
          ],
        ),
      );
    }
    final double meters = me.distanceTo(s.point);
    final int m = meters.round();
    final double bearing = bearingTo(me, s.point);
    final double? facing = heading;
    // Sin brújula, la flecha apunta al rumbo respecto al norte.
    final double relative = facing == null ? bearing : bearing - facing;
    final String instruction = cueText(t, cueFor(meters, relative), m);
    final int minutes = walkMinutes(meters);
    final DateTime? board = boarding?.subtract(const Duration(minutes: 40));
    String? timing;
    if (board != null && s.kind == SpotKind.gate) {
      final int left = board.difference(DateTime.now()).inMinutes;
      if (left >= 0) {
        timing = left > minutes + 10 ? t.airportInTime : t.airportHurry;
      }
    }
    return _box(
      Row(
        children: <Widget>[
          Transform.rotate(
            angle: relative * 3.141592653589793 / 180,
            child: const Icon(
              Icons.navigation_rounded,
              size: 96,
              color: NomadColors.mint,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  instruction,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(title),
                if (s.level != null) Text(t.airportLevel(s.level!)),
                const SizedBox(height: 6),
                Text(
                  t.airportDistance(minutes, m),
                  style: const TextStyle(
                    color: NomadColors.mint,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (board != null && s.kind == SpotKind.gate)
                  Text(t.airportBoarding(DateFormat.Hm(locale).format(board))),
                if (timing != null)
                  Text(
                    timing,
                    style: TextStyle(
                      color: timing == t.airportInTime
                          ? NomadColors.mint
                          : NomadColors.safety,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _box(Widget child) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: NomadColors.surfaceHigh,
      borderRadius: BorderRadius.circular(24),
    ),
    child: child,
  );
}

/// El aviso de Flyra abajo del todo: su cara, el giro en letras grandes y
/// el altavoz para callarla. Entra con un pequeño salto cada vez que cambia.
class _FlyraTurn extends StatelessWidget {
  const _FlyraTurn({
    required this.text,
    required this.cue,
    required this.voice,
    required this.onVoice,
  });

  final String text;
  final Cue cue;
  final bool voice;
  final VoidCallback onVoice;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final IconData icon = switch (cue) {
      Cue.left => Icons.turn_left_rounded,
      Cue.right => Icons.turn_right_rounded,
      Cue.back => Icons.u_turn_left_rounded,
      Cue.straight => Icons.straight_rounded,
      Cue.arrived => Icons.flag_rounded,
    };
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        decoration: BoxDecoration(
          color: NomadColors.surfaceHigh,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: NomadColors.mint),
        ),
        child: Row(
          children: <Widget>[
            const FlyraAvatar(size: 40),
            const SizedBox(width: 10),
            Icon(icon, color: NomadColors.mint, size: 32),
            const SizedBox(width: 8),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                transitionBuilder: (Widget child, Animation<double> a) =>
                    ScaleTransition(scale: a, child: child),
                child: Text(
                  text,
                  key: ValueKey<String>(text),
                  semanticsLabel: text,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: t.airportVoice,
              isSelected: voice,
              icon: const Icon(Icons.volume_off_rounded),
              selectedIcon: const Icon(Icons.volume_up_rounded),
              onPressed: onVoice,
            ),
          ],
        ),
      ),
    );
  }
}
