// Aeropuerto (maqueta "Aeropuerto"): una flecha que apunta a tu puerta, al
// baño más cercano o a un café, con los metros y los minutos andando.
//
// Funciona como una brújula: el GPS dice dónde estás, la brújula hacia dónde
// miras y la guía (OpenStreetMap) dónde está cada sitio. No es navegación
// giro a giro con pasillos (para eso haría falta un mapa de interiores que
// no existe gratis para todos los aeropuertos), pero dentro de una terminal
// "por ahí y a 300 m" ya ayuda mucho; y la pantalla avisa de que sigas
// también los carteles.
import 'dart:async';

import 'package:flutter/material.dart';
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
import 'airport_guide.dart';

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
    _fixes ??= _services.location.watch().listen(
      (PositionFix f) => setState(() => _here = f.point),
      onError: (Object _) {},
    );
    _compass ??= _services.compass().listen(
      (double? h) => setState(() => _heading = h),
      onError: (Object _) {},
    );
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
    return Scaffold(
      appBar: AppBar(title: Text(t.airportTitle)),
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
          onChanged: (_) => setState(() {}),
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
              onSelected: (_) => setState(() => _target = k),
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
    final Turn turn = turnFor(relative);
    final String instruction = meters < 15
        ? t.airportArrived
        : switch (turn) {
            Turn.straight => t.airportStraight(m),
            Turn.left => t.airportLeft,
            Turn.right => t.airportRight,
            Turn.back => t.airportBack,
          };
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
