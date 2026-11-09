// La RUTA DEL VUELO (maqueta "Ruta"): la maqueta tal cual
// (assets/route/ruta.html) con tu ruta de verdad. Cuatro momentos:
//   1. Mundo: se ve la ruta entera. "Empezar en Madrid".
//   2. Origen: la cámara se acerca a tu ciudad y sale su ficha (Wikipedia y
//      Wikidata): bandera, capital, idioma, moneda, hora, por qué es famosa
//      y lo más visitado con fotos de licencia libre.
//   3. Vuelo: el avión sigue el camino más corto de verdad y la cámara lo
//      sigue, con por dónde pasa, los km recorridos y lo que queda
//      (simulado: dura unos segundos, no 13 horas). También en 3D.
//   4. Destino: aterriza y sale la ficha de allí, con cuánto adelanta o
//      atrasa la hora.
//
// El mapa y los aeropuertos van dentro de la app; las fichas, del servidor.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../l10n/generated/app_localizations.dart';
import '../flights/booking.dart';
import '../flights/flight_format.dart';
import '../money/currency_info.dart' show flagOf;
import '../visa/visa_data.dart' show CountryNames;
import 'flight3d.dart';
import 'geo.dart';
import 'places_api.dart';
import 'route_page.dart';
import 'web_scene.dart';
import 'world_data.dart';

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

  /// De dónde salen las fichas de ciudad. Sin él, las fichas dicen que no
  /// hay información (por ejemplo, en algunos tests).
  final PlaceLoader? places;

  /// Abre un enlace fuera de la app (Wikipedia, la página de una foto).
  final OpenBooking openLink;

  /// Dónde se ven las páginas web (esta y el Vuelo 3D). Con él, "Ver el
  /// vuelo en 3D" abre el vuelo en 3D.
  final WebSceneBuilder? scene3d;

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<FlightRouteScreen> createState() => _FlightRouteScreenState();
}

class _FlightRouteScreenState extends State<FlightRouteScreen> {
  final WebSceneBridge _bridge = FlightRouteScreen.lastBridge =
      WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  WorldData? _world;
  bool _failed = false;
  late String? _to = widget.to;

  Airport? _origin;
  Airport? _dest;
  List<LatLon> _route = const <LatLon>[];
  double _km = 0;

  CountryCodes? _codes;
  CountryNames? _names;
  List<(double, String)> _regions = const <(double, String)>[];

  /// Las fichas de ciudad ("" mientras llegan; null si no hay).
  final Map<String, PlaceCard?> _cards = <String, PlaceCard?>{};
  final Set<String> _asked = <String>{};

  /// Sube cada vez que se aterriza en 3D (la página salta al destino).
  int _arrive = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      _pageCache ??= await rootBundle.loadString(routePage, cache: false);
      final WorldData world = await (widget.loadWorld ?? WorldData.load)();
      if (!mounted) return;
      _world = world;
      _setRoute();
      if (_to == null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _askDestination());
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
      return;
    }
    // Banderas y nombres de país en tu idioma (si no, en inglés).
    try {
      _codes = await CountryCodes.load();
      _names = await CountryNames.load();
    } on Object {
      // Sin ellos sale el nombre en inglés y sin bandera.
    }
    if (mounted) setState(_setRegions);
  }

  /// Prepara la ruta con los aeropuertos elegidos.
  void _setRoute() {
    final WorldData? world = _world;
    if (world == null) return;
    final Airport? origin = world.airports[widget.from];
    final Airport? dest = _to == null ? null : world.airports[_to!];
    setState(() {
      _origin = origin;
      _dest = dest;
      if (origin != null && dest != null) {
        _route = greatCircle(origin.position, dest.position);
        _km = distanceKm(origin.position, dest.position);
      } else {
        _route = const <LatLon>[];
        _km = 0;
      }
      _setRegions();
    });
    for (final Airport? a in <Airport?>[origin, dest]) {
      if (a != null) unawaited(_card(a.iata));
    }
  }

  /// El nombre del país de un aeropuerto, en tu idioma si se sabe.
  String _country(Airport a) {
    final String? code = _codes?[a.country];
    final CountryNames? names = _names;
    if (code == null || names == null) return a.country;
    return names.name(code, Localizations.localeOf(context).languageCode);
  }

  /// Por dónde pasa el avión: el país del aeropuerto más cercano si es
  /// tierra, o el mar.
  void _setRegions() {
    final WorldData? world = _world;
    final Airport? o = _origin, d = _dest;
    if (world == null || o == null || d == null || _route.isEmpty) {
      _regions = const <(double, String)>[];
      return;
    }
    _regions = regionsAlong(
      _route,
      (LatLon p) {
        if (!onLand(world.shapes, p)) return 'Sobrevolando el mar';
        Airport? best;
        double bestKm = double.infinity;
        for (final Airport a in world.airports.all) {
          final double km = distanceKm(p, a.position);
          if (km < bestKm) {
            bestKm = km;
            best = a;
          }
        }
        return best == null || bestKm > 1500
            ? 'Sobrevolando tierra firme'
            : 'Sobrevolando ${_country(best)}';
      },
      leaving: 'Despegando de ${o.city}',
      arriving: 'Llegando a ${d.city}',
    );
  }

  Future<void> _card(String iata) async {
    final PlaceLoader? places = widget.places;
    if (places == null || !_asked.add(iata)) return;
    PlaceCard? card;
    try {
      card = await places(iata, Localizations.localeOf(context).languageCode);
    } on Object {
      card = null;
    }
    if (mounted) setState(() => _cards[iata] = card);
  }

  /// El vuelo en 3D a pantalla completa. Al volver tras aterrizar, la
  /// página ya enseña el destino.
  Future<void> _fly3d() async {
    final WebSceneBuilder? scene = widget.scene3d;
    final Airport? from = _origin, to = _dest;
    if (scene == null || from == null || to == null) return;
    final bool? landed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        fullscreenDialog: true,
        builder: (BuildContext context) =>
            Flight3dScreen(from: from, to: to, scene: scene),
      ),
    );
    if (!mounted || landed != true) return;
    setState(() => _arrive++);
  }

  Future<void> _askDestination() async {
    final WorldData? world = _world;
    if (world == null) return;
    final String? code = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheet) =>
          _DestinationSheet(airports: world.airports, exclude: widget.from),
    );
    if (code == null || !mounted) return;
    _to = code;
    _setRoute();
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    switch (p.first) {
      case 'back':
        unawaited(Navigator.of(context).maybePop());
      case 'pick':
        unawaited(_askDestination());
      case 'fly3d':
        unawaited(_fly3d());
      case 'more' when p.length > 1:
        final Uri? url = _cardOf(p[1])?.articleUrl;
        if (url != null) unawaited(widget.openLink(url));
      case 'sight' when p.length > 2:
        final List<Attraction> all = _cardOf(p[1])?.attractions ?? const [];
        final int i = int.tryParse(p[2]) ?? -1;
        if (i < 0 || i >= all.length) return;
        // El artículo; si no hay, la página de la foto (autor y licencia).
        final Uri? url = all[i].articleUrl ?? all[i].photo?.pageUrl;
        if (url != null) unawaited(widget.openLink(url));
    }
  }

  PlaceCard? _cardOf(String which) {
    final Airport? a = which == 'd' ? _dest : _origin;
    return a == null ? null : _cards[a.iata];
  }

  /// La ficha de una ciudad para la página.
  Map<String, Object?> _place(
    AppLocalizations t,
    Airport a,
    Airport? compareTo,
    bool origin,
    String locale,
  ) {
    final PlaceCard? card = _cards[a.iata];
    final bool waiting = widget.places != null && !_cards.containsKey(a.iata);
    final CountryFacts? c = card?.country;
    const String none = 'Sin datos';
    final String? code = _codes?[a.country];
    final String country = c?.name ?? _country(a);
    final String time = _localTime(t, a, compareTo, locale);
    return <String, Object?>{
      'flag': code == null ? '🌐' : flagOf(code),
      'country': country,
      'city': a.city,
      'sub': '$country · ${origin ? 'punto de salida' : 'has llegado'}',
      'tag': origin ? t.routeOriginTag : t.routeDestinationTag,
      'tagSt':
          'height: 26px; flex-shrink: 0; border-radius: 13px; background: ${origin ? '#6CA8FF' : '#FF8A65'}; color: #0B1217; font-size: 11px; font-weight: 800; display: flex; align-items: center; padding: 0 10px',
      'facts': <Object?>[
        <String, String>{'k': t.placeCapital, 'v': c?.capital ?? none},
        <String, String>{
          'k': 'Idioma',
          'v': c == null || c.languages.isEmpty
              ? none
              : c.languages.take(2).join(', '),
        },
        <String, String>{'k': t.placeCurrency, 'v': c?.currency ?? none},
        <String, String>{
          'k': 'Hora',
          'v': time.isEmpty ? none : time.replaceFirst(RegExp(r'^[^:]*: '), ''),
        },
      ],
      'why': waiting ? '…' : card?.summary ?? t.placeUnavailable,
      'more': card?.articleUrl != null,
      'sights': <Object?>[
        for (final Attraction s in card?.attractions.take(8) ?? <Attraction>[])
          <String, Object?>{
            'name': s.name,
            'img': s.photo?.url.toString() ?? '',
          },
      ],
    };
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String locale = localeOf(context);
    final Airport? o = _origin, d = _dest;
    final NumberFormat km = NumberFormat.decimalPattern(locale);
    final Duration total = estimatedFlightTime(_km);
    final String dur = _durationText(t, total);
    final bool anyCard = _cards.values.any((PlaceCard? c) => c != null);
    return <String, Object?>{
      'loc': locale,
      'backTxt': MaterialLocalizations.of(context).backButtonTooltip,
      'title': o == null
          ? t.routeUnknownAirport
          : d == null
          ? t.routeTitle
          : '${o.city} → ${d.city}',
      'sub': d == null
          ? (o == null ? '' : '${o.iata} · ${o.city}')
          : '${t.routeDistance(km.format(_km.round()))} · ${t.routeFlightTime(dur)}',
      'worldLbl': t.routeWorld,
      'followLbl': t.routeFollowing,
      'path': mapPath(_route),
      'o': o == null
          ? null
          : <String, Object?>{
              ...<String, Object?>{
                'x': mapPoint(o.position)[0],
                'y': mapPoint(o.position)[1],
              },
              'lbl': '${o.iata} · origen',
              'aria': t.placeAbout(o.city),
              'city': o.city,
            },
      'd': d == null
          ? null
          : <String, Object?>{
              'x':
                  mapPoint(d.position)[0] +
                  // Si la ruta cruza el meridiano 180, el destino sigue la línea.
                  (_route.isEmpty
                      ? 0
                      : mapPoint(_route.last)[0] - mapPoint(d.position)[0]),
              'y': mapPoint(d.position)[1],
              'lbl': '${d.iata} · destino',
              'aria': t.placeAbout(d.city),
              'city': d.city,
            },
      'worldH': d == null
          ? t.routePickDestination
          : 'Toca el origen para empezar',
      'worldP': d == null || o == null ? '' : t.routeStartHint(o.city),
      'startTxt': o == null ? '' : t.routeStartAt(o.city),
      'pickTxt': t.routePickDestination,
      'regions': <Object?>[
        for (final (double at, String label) in _regions)
          <String, Object?>{'at': at, 'label': label},
      ],
      'km': _km.round(),
      'mins': total.inMinutes,
      'simTxt': 'SIMULACIÓN DEL RECORRIDO',
      'doneTxt': 'Recorrido',
      'leftTxt': 'Quedan',
      'landTxt': t.routeLand,
      'op': o == null ? null : _place(t, o, null, true, locale),
      'dp': d == null || o == null ? null : _place(t, d, o, false, locale),
      'whyH': t.placeWhyFamous,
      'moreTxt': t.placeReadMore,
      'sightsH': t.placeMostVisited,
      'flyTxt': 'Ir al destino',
      'has3d': widget.scene3d != null && d != null,
      'fly3dTxt': 'Ver el vuelo en 3D',
      'replayTxt': t.routeReplay,
      'backOriginTxt': t.routeBackToOrigin,
      'credits': <String>[
        t.routeCredits,
        if (anyCard) t.placeCredits,
      ].join(' · '),
      'arrive': _arrive,
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    final AppLocalizations t = AppLocalizations.of(context);
    if (_failed) {
      return Scaffold(
        backgroundColor: const Color(0xFF0B1217),
        appBar: AppBar(),
        body: Center(child: Text(t.routeLoadFailed)),
      );
    }
    if (page == null || _world == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = _data(t);
    final String push = routePushScript(data);
    if (_html == null) {
      _html = routePageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            widget.scene3d?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }

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
