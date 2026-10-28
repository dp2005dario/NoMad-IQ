// La RUTA DEL VUELO (maqueta "Ruta"): un mapamundi con el camino real del
// avión. Cuatro momentos:
//   1. Mundo: se ve la ruta entera. "Empezar en Madrid".
//   2. Origen: la cámara se acerca a tu ciudad, con su hora local.
//   3. Vuelo: el avión despega y la cámara lo sigue, con los km recorridos y
//      lo que queda (simulado: dura unos segundos, no 13 horas).
//   4. Destino: aterriza y ves la hora allí y cuánto adelanta o atrasa.
//
// Todo funciona sin Internet: el mapa y los aeropuertos van dentro de la app.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/booking.dart';
import '../flights/flight_format.dart';
import 'city_sheet.dart';
import 'flight3d.dart';
import 'flight_hud.dart';
import 'geo.dart';
import 'places_api.dart';
import 'route_painter.dart';
import 'world_data.dart';

enum RouteStage { world, origin, flight, arrived }

class FlightRouteScreen extends StatefulWidget {
  const FlightRouteScreen({
    super.key,
    required this.from,
    this.to,
    this.loadWorld,
    this.places,
    this.openLink = openInBrowser,
    this.scene3d,
  });

  /// Códigos IATA ("MAD", "NRT"). Sin destino, primero se pregunta.
  final String from;
  final String? to;

  /// En los tests se puede dar el mapa ya cargado.
  final Future<WorldData> Function()? loadWorld;

  /// De dónde salen las fichas de ciudad. Sin él no se ofrece el botón
  /// "Sobre Madrid" (por ejemplo, en algunos tests).
  final PlaceLoader? places;

  /// Abre un enlace fuera de la app (Wikipedia, la página de una foto).
  final OpenBooking openLink;

  /// Dónde se ve el Vuelo 3D. Con él, "Despegar" abre el vuelo en 3D; sin
  /// él, el avión cruza este mapa plano.
  final WebSceneBuilder? scene3d;

  /// Cuánto dura la simulación del vuelo.
  static const Duration flightAnimation = Duration(seconds: 14);

  @override
  State<FlightRouteScreen> createState() => _FlightRouteScreenState();
}

class _FlightRouteScreenState extends State<FlightRouteScreen>
    with TickerProviderStateMixin {
  WorldData? _world;
  bool _failed = false;
  late String? _to = widget.to;

  Airport? _origin;
  Airport? _dest;
  List<LatLon> _route = const <LatLon>[];
  double _km = 0;

  RouteStage _stage = RouteStage.world;
  MapCamera _camera = const MapCamera(LatLon(20, 0), 1);

  // Movimiento de cámara entre dos puntos de vista.
  late final AnimationController _camMove = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );
  MapCamera _camFrom = const MapCamera(LatLon(20, 0), 1);
  MapCamera _camTo = const MapCamera(LatLon(20, 0), 1);

  // El vuelo simulado (0 = despegue, 1 = aterrizaje).
  late final AnimationController _flight = AnimationController(
    vsync: this,
    duration: FlightRouteScreen.flightAnimation,
  );

  // El "latido" de los puntos de origen y destino.
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  static const double _followZoom = 3;
  static const double _cityZoom = 9;

  @override
  void initState() {
    super.initState();
    _camMove.addListener(() {
      setState(() {
        _camera = MapCamera.lerp(
          _camFrom,
          _camTo,
          Curves.easeInOutCubic.transform(_camMove.value),
        );
      });
    });
    _flight.addListener(() {
      if (_stage != RouteStage.flight) return;
      setState(() {
        _camera = MapCamera(
          RoutePainter.pointAt(_route, _flight.value),
          _followZoom,
        );
      });
    });
    _flight.addStatusListener((AnimationStatus s) {
      if (s == AnimationStatus.completed && _stage == RouteStage.flight) {
        _arrive();
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _camMove.dispose();
    _flight.dispose();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final WorldData world = await (widget.loadWorld ?? WorldData.load)();
      if (!mounted) return;
      setState(() => _world = world);
      _setRoute();
      if (_to == null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _askDestination());
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  /// Prepara la ruta con los aeropuertos elegidos y enseña el mundo.
  void _setRoute() {
    final WorldData? world = _world;
    if (world == null) return;
    final Airport? origin = world.airports[widget.from];
    final Airport? dest = _to == null ? null : world.airports[_to!];
    setState(() {
      _origin = origin;
      _dest = dest;
      _flight.value = 0;
      if (origin != null && dest != null) {
        _route = greatCircle(origin.position, dest.position);
        _km = distanceKm(origin.position, dest.position);
      } else {
        _route = const <LatLon>[];
      }
      _stage = RouteStage.world;
    });
    _moveTo(_worldCamera());
  }

  /// La vista "Mundo": la ruta entera centrada.
  MapCamera _worldCamera() {
    if (_route.isEmpty) {
      final Airport? o = _origin;
      return MapCamera(o?.position ?? const LatLon(20, 0), 1.2);
    }
    double minLon = 999, maxLon = -999, minLat = 99, maxLat = -99;
    for (final LatLon p in _route) {
      if (p.lon < minLon) minLon = p.lon;
      if (p.lon > maxLon) maxLon = p.lon;
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
    }
    // Que quepa la ruta con margen (y nunca alejarse más del mundo entero).
    final double span = (maxLon - minLon).abs() + 30;
    final double spanLat = ((maxLat - minLat).abs() + 20) * 2;
    final double zoom = (360 / (span > spanLat ? span : spanLat)).clamp(
      1.0,
      6.0,
    );
    return MapCamera(
      LatLon((minLat + maxLat) / 2, (minLon + maxLon) / 2),
      zoom,
    );
  }

  void _moveTo(MapCamera target, {VoidCallback? then}) {
    _camFrom = _camera;
    _camTo = target;
    _camMove.forward(from: 0).whenComplete(() {
      if (mounted && then != null) then();
    });
  }

  void _goOrigin() {
    final Airport? o = _origin;
    if (o == null) return;
    _flight.stop();
    setState(() {
      _stage = RouteStage.origin;
      _flight.value = 0;
    });
    _moveTo(MapCamera(_route.isEmpty ? o.position : _route.first, _cityZoom));
  }

  void _takeOff() {
    if (_route.isEmpty) return;
    final WebSceneBuilder? scene = widget.scene3d;
    final Airport? from = _origin, to = _dest;
    if (scene != null && from != null && to != null) {
      unawaited(_fly3d(scene, from, to));
      return;
    }
    setState(() => _stage = RouteStage.flight);
    _moveTo(
      MapCamera(_route.first, _followZoom),
      then: () => _flight.forward(from: 0),
    );
  }

  /// El vuelo en 3D a pantalla completa. Al volver tras aterrizar, este
  /// mapa ya enseña el destino (con su hora local).
  Future<void> _fly3d(WebSceneBuilder scene, Airport from, Airport to) async {
    final bool? landed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (BuildContext context) =>
            Flight3dScreen(from: from, to: to, scene: scene),
      ),
    );
    if (!mounted || landed != true) return;
    _arrive();
  }

  void _land() {
    _flight.stop();
    _arrive();
  }

  void _arrive() {
    setState(() {
      _stage = RouteStage.arrived;
      _flight.value = 1;
    });
    _moveTo(MapCamera(_route.last, _cityZoom));
  }

  /// Abre la ficha de la ciudad (por qué es famosa, lo más visitado…).
  void _openCity(Airport airport) {
    final PlaceLoader? places = widget.places;
    if (places == null) return;
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheet) => CitySheet(
        iata: airport.iata,
        load: places,
        openLink: widget.openLink,
      ),
    );
  }

  Widget _aboutButton(AppLocalizations t, Airport airport) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: TextButton.icon(
      onPressed: () => _openCity(airport),
      icon: const Icon(Icons.travel_explore_rounded),
      label: Text(t.placeAbout(airport.city)),
    ),
  );

  Future<void> _askDestination() async {
    final String? code = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheet) =>
          _DestinationSheet(airports: _world!.airports, exclude: widget.from),
    );
    if (code == null || !mounted) return;
    _to = code;
    _setRoute();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final WorldData? world = _world;
    final Airport? origin = _origin;
    final Airport? dest = _dest;
    return Scaffold(
      backgroundColor: NomadColors.background,
      appBar: AppBar(
        title: Text(
          origin != null && dest != null
              ? '${origin.iata} → ${dest.iata}'
              : t.routeTitle,
        ),
        actions: <Widget>[
          if (world != null)
            IconButton(
              tooltip: t.routePickDestination,
              onPressed: _askDestination,
              icon: const Icon(Icons.edit_location_alt_rounded),
            ),
        ],
      ),
      body: _failed
          ? Center(child: Text(t.routeLoadFailed))
          : world == null
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: <Widget>[
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (BuildContext context, Widget? _) => CustomPaint(
                      painter: RoutePainter(
                        shapes: world.shapes,
                        camera: _camera,
                        route: _route.isEmpty && origin != null
                            ? <LatLon>[origin.position, origin.position]
                            : _route,
                        progress: _flight.value,
                        pulse: _pulse.value,
                        showPlane:
                            _route.isNotEmpty &&
                            (_stage == RouteStage.flight ||
                                _stage == RouteStage.origin ||
                                _stage == RouteStage.arrived),
                      ),
                    ),
                  ),
                ),
                PositionedDirectional(
                  top: 12,
                  start: 16,
                  child: _ViewChip(
                    label: switch (_stage) {
                      RouteStage.world => t.routeWorld,
                      RouteStage.origin => origin?.city ?? '',
                      RouteStage.flight => t.routeFollowing,
                      RouteStage.arrived => dest?.city ?? '',
                    },
                  ),
                ),
                if (origin == null)
                  Center(child: Text(t.routeUnknownAirport))
                else
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: SafeArea(top: false, child: _panel(context, t)),
                  ),
              ],
            ),
    );
  }

  Widget _panel(BuildContext context, AppLocalizations t) {
    final Airport origin = _origin!;
    final Airport? dest = _dest;
    final String locale = localeOf(context);
    final NumberFormat km = NumberFormat.decimalPattern(locale);
    final String duration = _durationText(t, estimatedFlightTime(_km));
    if (dest == null) {
      return _Panel(
        children: <Widget>[
          Text(t.routePickDestination, style: _title(context)),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _askDestination,
            child: Text(t.routePickDestination),
          ),
        ],
      );
    }
    switch (_stage) {
      case RouteStage.world:
        return _Panel(
          children: <Widget>[
            Text('${origin.city} → ${dest.city}', style: _title(context)),
            Text(
              '${t.routeDistance(km.format(_km.round()))} · '
              '${t.routeFlightTime(duration)}',
              style: _muted,
            ),
            const SizedBox(height: 8),
            Text(t.routeStartHint(origin.city), style: _muted),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _goOrigin,
              icon: const Icon(Icons.my_location_rounded),
              label: Text(t.routeStartAt(origin.city)),
            ),
            const SizedBox(height: 8),
            Text(t.routeCredits, style: _muted.copyWith(fontSize: 11)),
          ],
        );
      case RouteStage.origin:
        return _Panel(
          children: <Widget>[
            _Tag(text: t.routeOriginTag, color: NomadColors.mint),
            const SizedBox(height: 6),
            Text('${origin.city} · ${origin.country}', style: _title(context)),
            Text(_localTime(t, origin, null, locale), style: _muted),
            if (widget.places != null) _aboutButton(t, origin),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _takeOff,
              icon: const Icon(Icons.flight_takeoff_rounded),
              label: Text(t.routeTakeOff(dest.city)),
            ),
          ],
        );
      case RouteStage.flight:
        final double done = _flight.value;
        final Duration total = estimatedFlightTime(_km);
        return _Panel(
          children: <Widget>[
            FlightHud(
              fromCode: origin.iata,
              toCode: dest.iata,
              progress: done,
              traveled: t.routeTraveled(km.format((_km * done).round())),
              remaining: t.routeRemaining(
                _durationText(t, total * (1 - done)),
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _land,
              icon: const Icon(Icons.flight_land_rounded),
              label: Text(t.routeLand),
            ),
          ],
        );
      case RouteStage.arrived:
        return _Panel(
          children: <Widget>[
            _Tag(text: t.routeDestinationTag, color: NomadColors.flights),
            const SizedBox(height: 6),
            Text(t.routeArrived(dest.city), style: _title(context)),
            Text(
              '${dest.country} · ${_localTime(t, dest, origin, locale)}',
              style: _muted,
            ),
            if (widget.places != null) _aboutButton(t, dest),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _takeOffAgain,
                  icon: const Icon(Icons.replay_rounded),
                  label: Text(t.routeReplay),
                ),
                OutlinedButton(
                  onPressed: _goOrigin,
                  child: Text(t.routeBackToOrigin),
                ),
              ],
            ),
          ],
        );
    }
  }

  void _takeOffAgain() {
    setState(() => _flight.value = 0);
    _takeOff();
  }

  static TextStyle? _title(BuildContext context) =>
      Theme.of(context).textTheme.titleLarge;

  static const TextStyle _muted = TextStyle(color: NomadColors.textMuted);

  static String _durationText(AppLocalizations t, Duration d) {
    final int minutes = d.inMinutes;
    final int h = minutes ~/ 60, m = minutes % 60;
    return m == 0 ? t.routeHours(h) : t.routeHoursMinutes(h, m);
  }

  /// "Hora local: 14:05 · 8 h más que Madrid".
  static String _localTime(
    AppLocalizations t,
    Airport here,
    Airport? compareTo,
    String locale,
  ) {
    final Duration? offset = _offset(here.timeZone);
    if (offset == null) return '';
    final DateTime now = DateTime.now().toUtc().add(offset);
    final String time = t.routeLocalTime(DateFormat.Hm(locale).format(now));
    if (compareTo == null) return time;
    final Duration? other = _offset(compareTo.timeZone);
    if (other == null) return time;
    final int diff = (offset - other).inMinutes;
    if (diff == 0) return '$time · ${t.routeSameTime(compareTo.city)}';
    final int abs = diff.abs();
    final String amount = abs % 60 == 0
        ? t.routeHours(abs ~/ 60)
        : t.routeHoursMinutes(abs ~/ 60, abs % 60);
    return '$time · '
        '${diff > 0 ? t.routeAhead(amount, compareTo.city) : t.routeBehind(amount, compareTo.city)}';
  }

  static bool _tzReady = false;

  /// Diferencia con UTC ahora mismo en esa zona horaria (con horario de
  /// verano incluido). null si la zona no se conoce.
  static Duration? _offset(String zone) {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    try {
      return tz.TZDateTime.now(tz.getLocation(zone)).timeZoneOffset;
    } on tz.LocationNotFoundException {
      return null;
    }
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: NomadColors.surface.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: NomadColors.outline),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Text(
      text,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w800,
        fontSize: 11,
        letterSpacing: 0.6,
      ),
    ),
  );
}

class _ViewChip extends StatelessWidget {
  const _ViewChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: NomadColors.surface.withValues(alpha: 0.9),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: NomadColors.outline),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    ),
  );
}

/// Hoja para escribir el aeropuerto de destino.
class _DestinationSheet extends StatefulWidget {
  const _DestinationSheet({required this.airports, required this.exclude});

  final Airports airports;
  final String exclude;

  @override
  State<_DestinationSheet> createState() => _DestinationSheetState();
}

class _DestinationSheetState extends State<_DestinationSheet> {
  final TextEditingController _code = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _save() {
    final String code = _code.text.trim().toUpperCase();
    if (widget.airports[code] == null || code == widget.exclude) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, code);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.routePickDestination,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _code,
            autofocus: true,
            maxLength: 3,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: t.routeDestinationHint,
              errorText: _invalid ? t.routeUnknownAirport : null,
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          FilledButton(onPressed: _save, child: Text(t.routeShowRoute)),
        ],
      ),
    );
  }
}
