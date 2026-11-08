// Vuelos (maqueta "Cazador de vuelos"): la página es la propia maqueta
// (assets/flights/vuelos.html) dentro de un WebView, sin datos de ejemplo.
//
// Lo de verdad lo pone la app (flights_page.dart):
//   - tus chollos de hoy desde tu aeropuerto (el price-consumer), el mejor
//     arriba en grande con "¡VUELO CAZADO!";
//   - la ruta de ese chollo en el globo, con las coordenadas reales, los
//     monumentos que pillan cerca y los países que se sobrevuelan;
//   - tus alertas de precio (las rutas que vigilas).
// Y lo que la página pide después, sin recargarse (WebSceneBridge):
//   - el precio más barato de cada día del mes (calendario y barras);
//   - la ficha de cada ciudad (Wikipedia y fotos de Wikimedia Commons).
// Los botones que llevan a otra pantalla (buscar, reservar, avisar, Vuelo
// 3D, los cuadrados de "Planea tu viaje"...) los abre la app.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../home/home_screen.dart' show displayName;
import '../route/flight3d.dart' show CountryCodes;
import '../route/places_api.dart';
import '../route/web_scene.dart';
import '../route/world_data.dart';
import 'fares_api.dart';
import 'flight_format.dart' show localeOf;
import 'flights_page.dart';
import 'watch_sheet.dart';

/// Aeropuerto por defecto (el de la maqueta) hasta que eliges otro.
const String defaultOrigin = 'MAD';

/// Cuántos chollos van a la página (para la ganga a medida).
const int maxDeals = 20;

class FlightsScreen extends StatefulWidget {
  const FlightsScreen({super.key});

  /// Lo último que se le mandó a la página (para los tests, que no tienen
  /// WebView).
  @visibleForTesting
  static WebSceneBridge? lastBridge;

  @override
  State<FlightsScreen> createState() => _FlightsScreenState();
}

class _FlightsScreenState extends State<FlightsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final String _origin =
      _services.prefs.readFlightOrigin() ?? defaultOrigin;
  final WebSceneBridge _bridge = FlightsScreen.lastBridge = WebSceneBridge();
  bool _started = false;

  String? _page;
  String? _html;
  Airports? _airports;
  CountryCodes? _codes;
  List<Deal> _deals = <Deal>[];
  List<Watch> _watches = <Watch>[];
  bool _guest = false;

  /// El chollo que se ve arriba (cambia con la ganga a medida).
  int _hunt = 0;

  /// Las fichas de ciudad que ya llegaron (para abrir sus fotos).
  final Map<String, PlaceCard> _cards = <String, PlaceCard>{};

  /// Dónde se reserva cada día del calendario: "MAD-NRT-rt-2027-3" → día → enlace.
  final Map<String, Map<int, Uri>> _dayLinks = <String, Map<int, Uri>>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    _page ??= await rootBundle.loadString(flightsPage, cache: false);
    try {
      // Se leen una vez y se quedan en memoria (son datos que no cambian).
      _airports ??= _airportsCache ??= Airports.parse(
        await rootBundle.loadString('assets/geo/airports.txt'),
      );
      _codes ??= _codesCache ??= CountryCodes.parse(
        await rootBundle.loadString('assets/geo/countries.txt'),
      );
    } on Object {
      // Sin los datos de aeropuertos no hay ruta en el globo (el resto sí).
    }
    bool failed = false;
    List<Deal> deals = <Deal>[];
    List<Watch> watches = <Watch>[];
    bool guest = false;
    try {
      deals = await _services.fares.deals(_origin);
      // Primero lo que más ha bajado; a igual bajada, lo más barato.
      deals.sort((Deal a, Deal b) {
        final int byDrop = b.dropBasisPoints.compareTo(a.dropBasisPoints);
        return byDrop != 0
            ? byDrop
            : a.fare.price.amountMinor.compareTo(b.fare.price.amountMinor);
      });
    } on ApiException {
      failed = true;
    }
    try {
      (watches, _) = await _services.fares.watches();
    } on ApiException catch (e) {
      // Sin cuenta no hay "mis alertas": no es un error.
      guest = e.error == ApiError.signedOut;
      if (!guest) failed = true;
    }
    if (!mounted) return;
    setState(() {
      _deals = deals.take(maxDeals).toList();
      _watches = watches;
      _guest = guest;
      _hunt = 0;
      _cards.clear();
      _html = flightsPageWith(_page!, _data(failed));
    });
  }

  Map<String, Object?> _data(bool failed) {
    final DateTime now = DateTime.now();
    final String locale = localeOf(context);
    final Airports? airports = _airports;
    final CountryCodes? codes = _codes;
    final String? name = displayName(SessionScope.of(context).user?.email);
    return flightsPageData(
      now: now,
      origin: _origin,
      locale: locale.replaceAll('_', '-'),
      initial: name == null ? '?' : name[0],
      guest: _guest,
      failed: failed,
      deals: <Map<String, Object?>>[
        for (int i = 0; i < _deals.length; i++)
          dealJson(
            i,
            _deals[i],
            now: now,
            route: airports == null || codes == null
                ? null
                : routeJson(
                    _deals[i].fare.route.origin,
                    _deals[i].fare.route.destination,
                    airports: airports,
                    codeOf: (String c) => codes[c],
                    offset: _offsetMinutes,
                    now: now,
                  ),
          ),
      ],
      alerts: <Map<String, Object?>>[
        for (final Watch w in _watches)
          alertJson(
            w,
            (Money m) =>
                formatMoney(m.amountMinor, m.currency, locale, compact: true),
          ),
      ],
    );
  }

  static bool _tzReady = false;
  static Airports? _airportsCache;
  static CountryCodes? _codesCache;

  /// Minutos de diferencia con UTC en esa zona ese día (null si no se sabe).
  static int? _offsetMinutes(String zone, DateTime when) {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    try {
      return tz.TZDateTime.from(
        when,
        tz.getLocation(zone),
      ).timeZoneOffset.inMinutes;
    } on tz.LocationNotFoundException {
      return null;
    }
  }

  // ---- Lo que pide la página.

  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int n = p.length > 1 ? int.tryParse(p[1]) ?? -1 : -1;
    switch (p.first) {
      case 'cal' when p.length == 3:
        unawaited(_calendar(unpackJson(p[2])));
      case 'ficha':
        unawaited(_ficha(n == 0 ? 'o' : 'd'));
      case 'go' when p.length == 3:
        _search(unpackJson(p[2]));
      case 'hunt' when n >= 0 && n < _deals.length:
        _hunt = n;
        _cards.clear();
      case 'book' when n >= 0 && n < _deals.length && p.length == 3:
        unawaited(_book(_deals[n], int.tryParse(p[2]) ?? 0));
      case 'watch' when n >= 0 && n < _deals.length:
        unawaited(_watch(_deals[n]));
      case 'fly3d' when _deals.isNotEmpty:
        final FareRoute r = _deals[_hunt].fare.route;
        unawaited(
          context.push(Routes.flightRoute(from: r.origin, to: r.destination)),
        );
      case 'tile':
        final String? to = switch (n) {
          0 => Routes.explore(),
          1 => Routes.stays(),
          2 => Routes.events(),
          3 => Routes.copyTrip(),
          4 => Routes.flightRoute(from: _origin),
          _ => null,
        };
        if (to != null) unawaited(context.push(to));
      case 'settings':
        unawaited(context.push(Routes.settings));
      case 'retry':
        unawaited(_load());
      case 'photo' when p.length == 3:
        _photo(n == 0 ? 'o' : 'd', int.tryParse(p[2]) ?? -1);
      case 'alert' when n >= 0 && n < _watches.length:
        unawaited(_openWatch(_watches[n]));
      case 'signin':
        unawaited(context.push(Routes.signIn));
      case 'alerts':
        unawaited(context.push(Routes.fareAlerts));
    }
  }

  static final RegExp _iata = RegExp(r'^[A-Z]{3}$');

  /// El precio más barato de cada día de un mes (lo pide el calendario).
  Future<void> _calendar(Map<String, Object?>? q) async {
    if (q == null) return;
    final Object? k = q['k'], o = q['o'], d = q['d'], y = q['y'], m = q['m'];
    if (k is! String || k.length > 40 || o is! String || d is! String) return;
    if (!_iata.hasMatch(o) || !_iata.hasMatch(d) || y is! int || m is! int) {
      return;
    }
    if (m < 1 || m > 12) return;
    final Map<String, int> prices = <String, int>{};
    try {
      final List<DayFare> days = await _services.fares.days(
        origin: o,
        destination: d,
        year: y,
        month: m,
        oneWay: q['ow'] == true,
      );
      final Map<int, Uri> links = _dayLinks[k] = <int, Uri>{};
      for (final DayFare f in days) {
        prices['${f.day.day}'] = f.pricePerAdult.amountMinor;
        if (f.bookingUrl case final Uri u) links[f.day.day] = u;
      }
    } on ApiException {
      // Sin precios ese mes: el calendario sale sin ellos.
    }
    await _bridge.run(
      pushScript(<String, Object?>{
        'cal': <String, Object?>{'k': k, 'p': prices},
      }),
    );
  }

  /// La ficha de la ciudad de salida ("o") o de llegada ("d") del chollo.
  Future<void> _ficha(String side) async {
    if (_deals.isEmpty) return;
    final FareRoute r = _deals[_hunt].fare.route;
    final String iata = side == 'o' ? r.origin : r.destination;
    PlaceCard? card;
    try {
      card = await _services.places.get(iata, 'es');
    } on Object {
      card = null;
    }
    if (card != null) _cards[side] = card;
    final CountryFacts? c = card?.country;
    await _bridge.run(
      pushScript(<String, Object?>{
        'ficha': <String, Object?>{
          'side': side,
          'capital': c?.capital,
          'lang': c == null || c.languages.isEmpty
              ? null
              : c.languages.join(', '),
          'cur': c?.currency,
          'culture': null,
          'why': card?.summary,
          'places': <Map<String, Object?>>[
            for (final Attraction a in card?.attractions ?? <Attraction>[])
              <String, Object?>{
                'name': a.name,
                'desc': a.description ?? '',
                'img': a.photo?.url.toString(),
              },
          ],
        },
      }),
    );
  }

  /// Tocar la foto de un lugar abre su página (autor y licencia).
  void _photo(String side, int i) {
    final List<Attraction> list =
        _cards[side]?.attractions ?? const <Attraction>[];
    if (i < 0 || i >= list.length) return;
    final Uri? url = list[i].photo?.pageUrl ?? list[i].articleUrl;
    if (url != null) unawaited(_services.openLink(url));
  }

  /// "Buscar vuelos": el buscador de la app con todo ya puesto, y busca.
  void _search(Map<String, Object?>? q) {
    if (q == null) return;
    final Object? o = q['o'], d = q['d'], dep = q['dep'], ret = q['ret'];
    final Object? ad = q['ad'], ki = q['ki'];
    if (o is! String || d is! String || dep is! String) return;
    if (!_iata.hasMatch(o) || !_iata.hasMatch(d)) return;
    final RegExp day = RegExp(r'^\d{4}-\d{2}-\d{2}$');
    if (!day.hasMatch(dep) ||
        (ret is String && ret.isNotEmpty && !day.hasMatch(ret))) {
      return;
    }
    final int people = (ad is int ? ad : 1) + (ki is int ? ki : 0);
    unawaited(
      context.push(
        Routes.fareSearch(
          origin: o,
          destination: d,
          departure: dep,
          returnDate: ret is String && ret.isNotEmpty ? ret : null,
          adults: people.clamp(1, 9),
          search: true,
        ),
      ),
    );
  }

  /// "Reservar ya": el día elegido en las barras (o el del chollo).
  Future<void> _book(Deal deal, int day) async {
    final FareRoute r = deal.fare.route;
    Uri? url = deal.fare.bookingUrl;
    if (day != r.departure.day) {
      final String key =
          '${r.origin}-${r.destination}-${r.returnDate == null ? 'ow' : 'rt'}-'
          '${r.departure.year}-${r.departure.month}';
      url = _dayLinks[key]?[day] ?? url;
    }
    if (url == null) return;
    final bool opened = await _services.openBooking(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo abrir la reserva.')),
      );
    }
  }

  /// "Avisar si baja": vigilar la ruta (necesita cuenta).
  Future<void> _watch(Deal deal) async {
    if (_guest) {
      await context.push(Routes.signIn);
      return;
    }
    final bool done = await showWatchSheet(
      context,
      route: deal.fare.route,
      currency: deal.fare.price.currency,
    );
    if (done && mounted) unawaited(_load());
  }

  Future<void> _openWatch(Watch w) async {
    await context.push(Routes.fareRoute(w.route.key), extra: w.latest);
    if (mounted) unawaited(_load()); // quizá dejó de vigilarla
  }

  @override
  Widget build(BuildContext context) {
    final String? html = _html;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: html == null
          // Mientras llegan los chollos (un instante), el fondo oscuro.
          ? const SizedBox.expand()
          : SafeArea(
              bottom: false,
              child: KeyedSubtree(
                // Una página nueva = un WebView nuevo.
                key: ValueKey<int>(html.hashCode),
                child:
                    _services.webScene?.call(html, _onMessage) ??
                    WebScene(
                      html: html,
                      onMessage: _onMessage,
                      bridge: _bridge,
                    ),
              ),
            ),
    );
  }
}
