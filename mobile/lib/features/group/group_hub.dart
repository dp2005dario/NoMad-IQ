// La pantalla Grupo cuando ya hay destino: la maqueta "Viaje en grupo" tal
// cual (assets/group/grupo.html, dentro de un WebView) con los datos de
// vuestro viaje. La página enseña y anima; aquí se traen los datos y se hace
// lo que la página pide:
//   - Cabecera: el destino, quiénes vais y los 4 atajos (chat, bote común,
//     elegir planes y cromos).
//   - "Gustos de cada uno": los tuyos se tocan y se guardan; los de los
//     demás solo se ven.
//   - "Así lo busca Flyra": gustos, zonas de OpenStreetMap, Booking con los
//     filtros puestos, eventos de Ticketmaster y la votación.
//   - "Votad dónde dormir": las dos zonas, con votos secretos (solo
//     cuántos); cuando todos votáis la misma, confeti y a reservar.
//   - "¿Qué os apetece?": sitios reales a un paseo, "Me apetece / Paso" e
//     "Ir" (Google Maps andando), y la hora dorada calculada con el sol.
//   - El plan del grupo (lo metido en «Elegir planes») y los gastos.
//
// Nada de esto usa IA ni datos inventados: si algo no se encuentra, la
// página lo dice. No hay precios de hoteles ni de sitios (no hay fuente
// gratis fiable).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../events/events_api.dart';
import '../map/geo.dart';
import '../map/geocode_api.dart';
import '../map/location.dart';
import '../money/money_screen.dart' show MoneyTab;
import '../plans/plans_api.dart';
import '../route/geo.dart' show LatLon, distanceKm;
import '../route/web_scene.dart';
import '../route/world_data.dart';
import '../stays/stays_api.dart';
import '../stays/stays_math.dart';
import 'cravings_api.dart';
import 'group_api.dart';
import 'group_page.dart';
import 'group_widgets.dart';
import 'sun.dart';

/// El nombre de un gusto en el idioma de cada uno.
String tasteLabel(AppLocalizations t, String id) => switch (id) {
  'tapas' => t.tasteTapas,
  'music' => t.tasteMusic,
  'views' => t.tasteViews,
  'fish' => t.tasteFish,
  'veggie' => t.tasteVeggie,
  'late' => t.tasteLate,
  _ => tagLabel(t, id),
};

/// "O contándoselo a Flyra en el chat": los gustos que se nombran en un
/// mensaje, por palabras clave (sin IA). Vale el nombre del gusto en tu
/// idioma ("pescado", "museos") y unas pocas palabras que se dicen igual en
/// casi todos (fado, jazz, sushi...).
List<String> tastesInText(AppLocalizations t, String text) {
  final String low = text.toLowerCase();
  const Map<String, List<String>> universal = <String, List<String>>{
    'music': <String>['fado', 'jazz', 'flamenco', 'tango', 'karaoke'],
    'fish': <String>['sushi', 'marisco', 'seafood'],
    'veggie': <String>['vegan', 'vegano', 'vegana'],
    'beach': <String>['playa', 'beach'],
  };
  return <String>[
    for (final String id in tasteIds)
      if (low.contains(tasteLabel(t, id).toLowerCase()) ||
          (universal[id] ?? const <String>[]).any(
            (String w) => RegExp('\\b$w\\b').hasMatch(low),
          ))
        id,
  ];
}

String cravingLabel(AppLocalizations t, Craving c) => switch (c) {
  Craving.tapas => t.tasteTapas,
  Craving.fish => t.tasteFish,
  Craving.veggie => t.tasteVeggie,
  Craving.cafe => t.craveCafe,
  Craving.views => t.tasteViews,
};

/// El gusto que encaja con cada antojo (para "Encaja con Marta").
String? tasteOfCraving(Craving c) => switch (c) {
  Craving.tapas => 'tapas',
  Craving.fish => 'fish',
  Craving.veggie => 'veggie',
  Craving.views => 'views',
  Craving.cafe => null,
};

/// Los gustos del grupo de más a menos repetidos (para el paso 1).
List<(String, int)> topTastes(List<TripMember> members) {
  final Map<String, int> count = <String, int>{};
  for (final TripMember m in members) {
    for (final String id in m.tastes) {
      count[id] = (count[id] ?? 0) + 1;
    }
  }
  final List<(String, int)> out = <(String, int)>[
    for (final MapEntry<String, int> e in count.entries) (e.key, e.value),
  ];
  // Más votos primero; a igualdad, el orden de los chips.
  out.sort(
    ((String, int) a, (String, int) b) => a.$2 != b.$2
        ? b.$2.compareTo(a.$2)
        : tasteIds.indexOf(a.$1).compareTo(tasteIds.indexOf(b.$1)),
  );
  return out;
}

/// El antojo con el que se abre "¿Qué os apetece?": el del gusto más
/// repetido del grupo, o tapas.
Craving firstCraving(List<TripMember> members) {
  for (final (String id, int _) in topTastes(members)) {
    for (final Craving c in Craving.values) {
      if (tasteOfCraving(c) == id) return c;
    }
  }
  return Craving.tapas;
}

/// El orden de los sitios: cercanía + lo que el grupo vota. Cada "Me
/// apetece" del grupo acerca el sitio 250 m; si tú dijiste "Paso", al final.
List<CravingSpot> rankSpots(
  List<CravingSpot> spots,
  GeoPoint from,
  Map<String, GroupPlan> votes,
) {
  double score(CravingSpot s) {
    final GroupPlan? p = votes[s.name.toLowerCase()];
    final double d = from.distanceTo(s.point);
    if (p?.myVote == false) return d + 100000;
    return d - 250 * (p?.yes ?? 0);
  }

  return <CravingSpot>[
    for (final CravingSpot s in spots)
      if (from.distanceTo(s.point) <= cravingRadiusM) s,
  ]..sort((CravingSpot a, CravingSpot b) => score(a).compareTo(score(b)));
}

class TripHub extends StatefulWidget {
  const TripHub({super.key, required this.trip, required this.onTrip});

  final GroupTrip trip;

  /// Cuando cambian tus gustos, el viaje nuevo (para repintar).
  final void Function(GroupTrip) onTrip;

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<TripHub> createState() => _TripHubState();
}

class _TripHubState extends State<TripHub> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = TripHub.lastBridge = WebSceneBridge();
  bool _started = false;

  /// La página y los aeropuertos se leen una vez (se guardan los textos, no
  /// la espera: así sirven a la siguiente pantalla aunque esta se cierre).
  static String? _pageCache;
  static Airports? _airportsCache;
  String? _html;
  String? _sentJson;

  /// El destino en el mapa (null mientras se busca; [_noCity] si no está).
  GeoPoint? _city;
  bool _noCity = false;

  /// Tu GPS, solo si ya diste permiso y estás en la ciudad (a 30 km).
  GeoPoint? _here;
  List<StayZone>? _zones;
  bool _zonesFailed = false;
  PlanBoard? _board;
  late Craving _crave = firstCraving(widget.trip.members);
  List<CravingSpot>? _spots;
  bool _spotsFailed = false;
  bool _savingTastes = false;
  bool _voting = false;
  String? _iata;
  List<CityEvent>? _events;
  bool _eventsFailed = false;
  DateTimeRange? _dates;

  String get _cityName =>
      widget.trip.option(widget.trip.result?.chosenOptionId)?.label ??
      widget.trip.title;

  GeoPoint? get _center => _here ?? _city;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      _pageCache ??= await rootBundle.loadString(groupPage, cache: false);
    } on Object {
      return; // sin la página no hay nada que enseñar
    }
    if (!mounted) return;
    setState(() {});
    unawaited(_loadBoard());
    try {
      final List<GeoPlace> found = await _services.geocode.search(_cityName);
      if (!mounted) return;
      if (found.isEmpty) {
        setState(() => _noCity = true);
        return;
      }
      setState(() => _city = found.first.point);
    } on ApiException {
      if (mounted) setState(() => _noCity = true);
      return;
    }
    await _locate();
    await Future.wait(<Future<void>>[
      _loadZones(),
      _loadSpots(),
      _loadEvents(),
    ]);
  }

  /// Sin preguntar nada: si ya hay permiso y estás en la ciudad, se usa tu
  /// GPS ("Dónde estás"); si no, el centro de la ciudad.
  Future<void> _locate() async {
    final GeoPoint? city = _city;
    if (city == null) return;
    try {
      final LocationSource gps = _services.location;
      if (await gps.check() != LocationAccess.granted) return;
      final PositionFix? fix = await gps.current();
      if (fix != null && fix.point.distanceTo(city) <= 30000 && mounted) {
        setState(() => _here = fix.point);
      }
    } on Object {
      // Sin GPS no pasa nada: se usa el centro de la ciudad.
    }
  }

  Future<void> _loadZones() async {
    final GeoPoint? city = _city;
    if (city == null) return;
    try {
      final StayArea area = await _services.stays.around(city);
      if (mounted) setState(() => _zones = area.zones.take(2).toList());
    } on ApiException {
      if (mounted) setState(() => _zonesFailed = true);
    }
  }

  Future<void> _loadSpots() async {
    final GeoPoint? at = _center;
    if (at == null) return;
    final Craving asked = _crave;
    setState(() => (_spots = null, _spotsFailed = false));
    try {
      final List<CravingSpot> spots = await _services.cravings.near(at, asked);
      if (mounted && asked == _crave) setState(() => _spots = spots);
    } on ApiException {
      if (mounted && asked == _crave) setState(() => _spotsFailed = true);
    }
  }

  /// "Mira qué pasa esos días": los eventos de Ticketmaster de las
  /// próximas dos semanas en el aeropuerto más cercano (a 100 km o menos).
  Future<void> _loadEvents() async {
    final GeoPoint? city = _city;
    if (city == null) return;
    try {
      _airportsCache ??= Airports.parse(
        await rootBundle.loadString('assets/geo/airports.txt'),
      );
    } on Object {
      return;
    }
    final LatLon at = LatLon(city.lat, city.lon);
    Airport? best;
    double bestKm = 100;
    for (final Airport a in _airportsCache!.all) {
      final double d = distanceKm(at, a.position);
      if (d < bestKm) {
        bestKm = d;
        best = a;
      }
    }
    if (best == null || !mounted) return;
    setState(() => _iata = best!.iata);
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    try {
      final CityEvents found = await _services.events.between(
        best.iata,
        today,
        today.add(const Duration(days: 14)),
      );
      if (mounted) setState(() => _events = found.events);
    } on ApiException {
      if (mounted) setState(() => _eventsFailed = true);
    }
  }

  Future<void> _loadBoard() async {
    try {
      final PlanBoard board = await _services.plans.board(widget.trip.id);
      if (mounted) setState(() => _board = board);
    } on ApiException {
      // Sin tablero se ven los sitios igual; los votos, al reintentar.
    }
  }

  void _error(ApiException e) {
    if (!mounted) return;
    final AppLocalizations t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          e.error == ApiError.network ? t.errorNetwork : t.errorUnavailable,
        ),
      ),
    );
  }

  Future<void> _toggleTaste(String id) async {
    final TripMember? me = widget.trip.me;
    if (me == null || _savingTastes) return;
    final List<String> next = me.tastes.contains(id)
        ? <String>[
            for (final String x in me.tastes)
              if (x != id) x,
          ]
        : <String>[...me.tastes, id];
    _savingTastes = true;
    try {
      widget.onTrip(await _services.group.setTastes(widget.trip.id, next));
    } on ApiException catch (e) {
      _error(e);
    } finally {
      _savingTastes = false;
    }
  }

  /// El voto de un sitio o zona: si aún no está en el tablero, se añade
  /// (el servidor no lo repite) y luego se vota.
  Future<void> _vote(List<NewPlan> ensure, Map<String, bool> votes) async {
    if (_voting) return;
    _voting = true;
    try {
      PlanBoard board = _board ?? await _services.plans.board(widget.trip.id);
      bool missing(NewPlan p) => findPlan(board, p.kind, p.title) == null;
      if (ensure.any(missing)) {
        board = await _services.plans.add(widget.trip.id, ensure);
      }
      for (final MapEntry<String, bool> v in votes.entries) {
        final GroupPlan? plan = findPlan(board, ensure.first.kind, v.key);
        if (plan == null || plan.myVote == v.value) continue;
        board = await _services.plans.vote(
          widget.trip.id,
          plan.id,
          yes: v.value,
        );
      }
      if (mounted) setState(() => _board = board);
    } on ApiException catch (e) {
      _error(e);
    } finally {
      _voting = false;
    }
  }

  Future<void> _voteSleep(StayZone chosen) async {
    final List<StayZone> zones = _zones ?? const <StayZone>[];
    await _vote(
      <NewPlan>[
        for (final StayZone z in zones)
          NewPlan(title: zoneTitle(z, _cityName), kind: PlanKind.sleep),
      ],
      <String, bool>{
        for (final StayZone z in zones)
          zoneTitle(z, _cityName): z.id == chosen.id,
      },
    );
  }

  Future<void> _voteSpot(CravingSpot spot, {required bool yes}) => _vote(
    <NewPlan>[
      NewPlan(
        title: spot.name,
        note: cravingLabel(AppLocalizations.of(context), _crave),
        kind: PlanKind.crave,
      ),
    ],
    <String, bool>{spot.name: yes},
  );

  /// "Abrir Booking": con las fechas que elijas y todo el grupo.
  Future<void> _openBooking(GeoPoint at) async {
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 500)),
      initialDateRange: _dates,
    );
    if (range == null || !mounted) return;
    final DateTimeRange dates = range.duration.inDays < 1
        ? DateTimeRange(
            start: range.start,
            end: range.start.add(const Duration(days: 1)),
          )
        : range;
    _dates = dates;
    unawaited(
      _services.openBooking(
        bookingSearch(
          at: at,
          checkIn: dates.start,
          checkOut: dates.end,
          adults: math.max(1, widget.trip.members.length),
          language: Localizations.localeOf(context).languageCode,
          affiliateId: AppConfig.bookingAffiliateId,
        ),
      ),
    );
  }

  /// "Ir": Google Maps andando hasta el sitio (un enlace, gratis).
  Future<void> _go(GeoPoint p) => _services.openBooking(
    Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'destination': '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}',
      'travelmode': 'walking',
    }),
  );

  /// Los sitios en el orden en que se ven (cercanía + votos del grupo).
  List<CravingSpot>? get _ranked => switch ((_spots, _center)) {
    (final List<CravingSpot> s, final GeoPoint at) => rankSpots(
      s,
      at,
      <String, GroupPlan>{
        for (final GroupPlan p in _board?.extras ?? const <GroupPlan>[])
          if (p.kind == PlanKind.crave) p.title.toLowerCase(): p,
      },
    ).take(3).toList(),
    _ => null,
  };

  Map<String, Object?> _data() => groupPageData(
    trip: widget.trip,
    city: _cityName,
    crave: _crave,
    zones: _zones,
    zonesFailed: _zonesFailed,
    noCity: _noCity,
    board: _board,
    spots: _ranked,
    spotsFailed: _spotsFailed,
    center: _center,
    golden: _city == null ? null : goldenHour(DateTime.now(), _city!),
    iata: _iata,
    events: _events,
    eventsFailed: _eventsFailed,
  );

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final List<StayZone> zones = _zones ?? const <StayZone>[];
    final List<CravingSpot> spots = _ranked ?? const <CravingSpot>[];
    switch (p.first) {
      case 'taste' when n != null && n < pageTastes.length:
        unawaited(_toggleTaste(pageTastes[n].$1));
      case 'zone' when n != null && n < zones.length:
        unawaited(_voteSleep(zones[n]));
      case 'book' when n != null && n < zones.length:
        unawaited(_openBooking(zones[n].point));
      case 'crave' when n != null && n < Craving.values.length:
        if (Craving.values[n] != _crave) {
          _crave = Craving.values[n];
          unawaited(_loadSpots());
        }
      case 'spot' when n != null && n < spots.length && p.length == 3:
        unawaited(_voteSpot(spots[n], yes: p[2] == '1'));
      case 'go' when n != null && n < spots.length:
        unawaited(_go(spots[n].point));
      case 'tile' when n != null:
        final String? route = switch (n) {
          0 => Routes.groupChat(widget.trip.id),
          1 => Routes.money(tab: MoneyTab.kitty),
          2 => Routes.groupPlans(widget.trip.id, city: _cityName),
          3 => Routes.cards,
          _ => null,
        };
        if (route != null) unawaited(_push(route));
      case 'settings':
        unawaited(context.push(Routes.settings));
      case 'events':
        unawaited(context.push(Routes.events(iata: _iata)));
      case 'money':
        unawaited(context.push(Routes.money()));
    }
  }

  /// Al volver de «Elegir planes» (o del chat) puede haber planes nuevos.
  Future<void> _push(String route) async {
    await context.push(route);
    if (mounted) unawaited(_loadBoard());
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) return const SizedBox.expand();
    final Map<String, Object?> data = _data();
    final String json = groupPushScript(data);
    if (_html == null) {
      _html = groupPageWith(page, data);
      _sentJson = json;
    } else if (json != _sentJson) {
      // Sin recargar: la página ya abierta recibe los datos nuevos.
      _sentJson = json;
      unawaited(_bridge.run(json));
    }
    final String html = _html!;
    return _services.webScene?.call(html, _onMessage) ??
        WebScene(html: html, onMessage: _onMessage, bridge: _bridge);
  }
}
