// Radar local (maqueta "Radar"): la maqueta tal cual (assets/radar/radar.html)
// con lo que conviene saber AHORA donde estás:
//
//   1. ¿Va a llover? La previsión de las próximas horas (MET Norway). Si no
//      se puede cargar, Flyra lo dice en su bocadillo.
//   2. Ojo en esta zona: timos que han avisado otros viajeros (solo se
//      enseñan con 3 personas o más; tú también puedes avisar).
//   3. ¿Me están cobrando de más? Comparas lo que te piden con lo que
//      pagaron otros viajeros en esa ciudad (con 5 o más precios).
//
// REGLA: nada inventado. Si aún no hay avisos o precios en una ciudad, la
// app lo dice tal cual ("aún no hay suficientes") en vez de rellenar.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../money/currency_info.dart';
import '../route/geo.dart' show LatLon;
import '../route/web_scene.dart';
import '../route/world_data.dart';
import '../sos/where_am_i.dart' show nearestAirport;
import 'radar_api.dart';
import 'radar_page.dart';

String scamTitle(AppLocalizations t, ScamCategory c) => switch (c) {
  ScamCategory.streetTouts => t.radarScamTouts,
  ScamCategory.taxi => t.radarScamTaxi,
  ScamCategory.fakePolice => t.radarScamPolice,
  ScamCategory.bracelet => t.radarScamBracelet,
  ScamCategory.atm => t.radarScamAtm,
  ScamCategory.pickpockets => t.radarScamPickpockets,
  ScamCategory.fakeTickets => t.radarScamTickets,
  ScamCategory.exchange => t.radarScamExchange,
};

String scamAdvice(AppLocalizations t, ScamCategory c) => switch (c) {
  ScamCategory.streetTouts => t.radarScamToutsWhy,
  ScamCategory.taxi => t.radarScamTaxiWhy,
  ScamCategory.fakePolice => t.radarScamPoliceWhy,
  ScamCategory.bracelet => t.radarScamBraceletWhy,
  ScamCategory.atm => t.radarScamAtmWhy,
  ScamCategory.pickpockets => t.radarScamPickpocketsWhy,
  ScamCategory.fakeTickets => t.radarScamTicketsWhy,
  ScamCategory.exchange => t.radarScamExchangeWhy,
};

String priceItemLabel(AppLocalizations t, PriceItem i) => switch (i) {
  PriceItem.coffee => t.radarItemCoffee,
  PriceItem.beer => t.radarItemBeer,
  PriceItem.water => t.radarItemWater,
  PriceItem.simpleMeal => t.radarItemMeal,
  PriceItem.taxiShort => t.radarItemTaxi,
};

class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, this.iata});

  final String? iata;

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = RadarScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  GeoPoint? _here;
  String? _city;
  String? _cityName;
  String? _country;
  bool _locating = true;

  RainForecast? _rain;
  bool _rainFailed = false;

  CityRadar? _radar;
  ApiError? _radarError;

  PriceItem _item = PriceItem.coffee;
  String? _currency;

  /// Lo último que apuntaste ("coffee:EUR:1.60"), para la marca ✓.
  String _sentKey = '';

  @override
  void initState() {
    super.initState();
    _city = widget.iata?.toUpperCase();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_open()));
  }

  Future<void> _open() async {
    try {
      _pageCache ??= await rootBundle.loadString(radarPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    await _start();
  }

  Future<void> _start() async {
    final LocationSource gps = _services.location;
    LocationAccess access = await gps.check();
    if (access == LocationAccess.denied) access = await gps.request();
    if (access == LocationAccess.granted) {
      try {
        final PositionFix fix = await gps.watch().first.timeout(
          const Duration(seconds: 10),
        );
        _here = fix.point;
        if (_city == null) {
          final Airports airports = await _services.loadAirports();
          final Airport? a = nearestAirport(
            airports.all,
            LatLon(fix.point.lat, fix.point.lon),
          );
          // La ciudad = la del aeropuerto más cercano, si está a menos de
          // 80 km (si no, estás "en ningún sitio" para el radar).
          if (a != null &&
              fix.point.distanceTo(GeoPoint(a.position.lat, a.position.lon)) <
                  80000) {
            _city = a.iata;
            _cityName = a.city;
            _country = a.country;
          }
        }
      } on Object {
        // Sin GPS a tiempo: sin lluvia (y ciudad solo si te la pasan).
      }
    }
    if (!mounted) return;
    setState(() => _locating = false);
    await Future.wait(<Future<void>>[_loadRain(), _loadRadar()]);
  }

  Future<void> _loadRain() async {
    final GeoPoint? here = _here;
    if (here == null) return;
    try {
      final RainForecast r = await _services.radar.rain(here);
      if (mounted) setState(() => _rain = r);
    } on ApiException {
      if (mounted) setState(() => _rainFailed = true);
    }
  }

  Future<void> _loadRadar() async {
    final String? city = _city;
    if (city == null) return;
    try {
      final CityRadar r = await _services.radar.city(city);
      if (!mounted) return;
      setState(() {
        _radar = r;
        _radarError = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _radarError = e.error);
    }
  }

  /// La moneda: la de los precios de esa cosa en esa ciudad; si no hay,
  /// la que elegiste, la del país o el euro.
  String get _cur =>
      _rangeFor(_item)?.currency ??
      _currency ??
      _localCurrency(_country) ??
      'EUR';

  static String? _localCurrency(String? country) {
    if (country == null) return null;
    for (final MapEntry<String, String> e in currencyCountry.entries) {
      if (e.value == country.toUpperCase()) return e.key;
    }
    return null;
  }

  PriceRange? _rangeFor(PriceItem item) => _radar?.prices
      .where(
        (PriceRange p) =>
            p.item == item && p.currency == (_currency ?? p.currency),
      )
      .firstOrNull;

  Future<void> _toggleScam(ScamCategory c) async {
    final String? city = _city;
    final CityRadar? radar = _radar;
    if (city == null || radar == null) return;
    try {
      if (radar.myScams.contains(c)) {
        await _services.radar.withdrawScam(city, c);
      } else {
        await _services.radar.reportScam(city, c);
      }
      await _loadRadar();
    } on ApiException catch (e) {
      _snack(
        (AppLocalizations t) => e.error == ApiError.rateLimited
            ? t.radarTooMany
            : t.radarSendFailed,
      );
    }
  }

  Future<void> _sendPrice(double asked) async {
    final String? city = _city;
    if (city == null) return;
    final String cur = _cur;
    final PriceItem item = _item;
    try {
      await _services.radar.addPrice(city, item, cur, asked);
      if (mounted) {
        setState(
          () => _sentKey = '${item.wire}:$cur:${asked.toStringAsFixed(2)}',
        );
      }
      _snack((AppLocalizations t) => t.radarPriceThanks);
    } on ApiException catch (e) {
      _snack(
        (AppLocalizations t) => e.error == ApiError.rateLimited
            ? t.radarTooMany
            : t.radarSendFailed,
      );
    }
  }

  /// La lista de monedas (las del conversor), para elegir en cuál te piden.
  Future<void> _pickCurrency() async {
    final List<String> all = <String>['EUR', ...currencyCountry.keys];
    final String? c = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final String c in all)
              ListTile(
                title: Text('${currencyFlag(c)} $c'),
                selected: c == _cur,
                onTap: () => Navigator.of(context).pop(c),
              ),
          ],
        ),
      ),
    );
    if (c != null && mounted) setState(() => _currency = c);
  }

  /// Google Maps busca cafés alrededor (gratis, sin clave).
  void _shelter() {
    final GeoPoint? here = _here;
    if (here == null) return;
    unawaited(
      _services.openBooking(
        Uri.https(
          'www.google.com',
          '/maps/search/cafe/@${here.lat.toStringAsFixed(4)},${here.lon.toStringAsFixed(4)},16z',
        ),
      ),
    );
  }

  // Recibe una función que elige el texto, para no leer el contexto antes
  // de comprobar que la pantalla sigue abierta.
  void _snack(String Function(AppLocalizations t) text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text(AppLocalizations.of(context)))),
      );
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final int i = m.indexOf(':');
    final String what = i < 0 ? m : m.substring(0, i);
    final String arg = i < 0 ? '' : m.substring(i + 1);
    switch (what) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'go':
        _shelter();
      case 'scam':
        final ScamCategory? c = ScamCategory.parse(arg);
        if (c != null) unawaited(_toggleScam(c));
      case 'item':
        final PriceItem? item = PriceItem.parse(arg);
        if (item != null) setState(() => _item = item);
      case 'cur':
        unawaited(_pickCurrency());
      case 'paid':
        final double? x = double.tryParse(arg);
        if (x != null && x > 0 && x < 1e7) unawaited(_sendPrice(x));
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String? city = _city;
    final String place = (_cityName ?? city ?? '').toUpperCase();

    // 1. La lluvia.
    final RainForecast? rain = _rain;
    final RainHour? first = rain?.firstRain;
    String rainTxt;
    if (_locating) {
      rainTxt = '…';
    } else if (_here == null) {
      rainTxt = t.radarNoLocation;
    } else if (_rainFailed) {
      rainTxt = t.radarRainFailed;
    } else if (rain == null) {
      rainTxt = '…';
    } else if (first == null) {
      rainTxt = t.radarNoRain(rain.hours.length);
    } else {
      rainTxt = t.radarRainAt(
        DateFormat.Hm(locale).format(first.time),
        NumberFormat.decimalPatternDigits(
          locale: locale,
          decimalDigits: 1,
        ).format(first.rainMm),
      );
    }

    // 2. Ojo en esta zona.
    final CityRadar? radar = _radar;
    final String zone = place.isEmpty
        ? 'OJO EN ESTA ZONA'
        : 'OJO EN ESTA ZONA · $place';
    Map<String, Object?> card(String title, String why, [String by = '']) =>
        <String, Object?>{'lbl': zone, 'title': title, 'why': why, 'by': by};
    final List<Map<String, Object?>> scams = <Map<String, Object?>>[
      if (_locating)
        card(t.radarScamsTitle, '…')
      else if (city == null)
        card(t.radarScamsTitle, t.radarNoCity)
      else if (_radarError == ApiError.signedOut)
        card(t.radarScamsTitle, t.radarSignIn)
      else if (_radarError != null)
        card(t.radarScamsTitle, t.radarSendFailed)
      else if (radar == null)
        card(t.radarScamsTitle, '…')
      else if (radar.scams.isEmpty)
        card(t.radarScamsTitle, t.radarNoScams)
      else
        for (final MapEntry<ScamCategory, int> e in radar.scams.entries)
          card(
            scamTitle(t, e.key),
            scamAdvice(t, e.key),
            t.radarReportedBy(e.value),
          ),
    ];

    // 3. ¿Me están cobrando de más?
    final String cur = _cur;
    final PriceRange? range = _rangeFor(_item);
    String money(double v) =>
        NumberFormat.simpleCurrency(locale: locale, name: cur).format(v);
    final bool showPrice = city != null && radar != null;

    return <String, Object?>{
      'title': t.radarTitle,
      'backTxt': MaterialLocalizations.of(context).backButtonTooltip,
      'sub': city == null ? '' : t.radarNowIn(_cityName ?? city),
      'rainy': first != null,
      'rainLbl': first == null
          ? t.radarRainTitle.toUpperCase()
          : rainLabel(first, DateTime.now(), locale),
      'rainTxt': rainTxt,
      'goTxt': t.radarFindShelter,
      'attr': rain?.attribution ?? '',
      'scams': scams,
      'reportHint': t.radarReportHint,
      'report': <Object?>[
        if (radar != null && city != null)
          for (final ScamCategory c in ScamCategory.values)
            <String, Object?>{
              'k': c.wire,
              'label': scamTitle(t, c),
              'on': radar.myScams.contains(c),
            },
      ],
      'showPrice': showPrice,
      'priceH': t.radarPriceTitle,
      'items': <Object?>[
        for (final PriceItem i in PriceItem.values)
          <String, Object?>{'k': i.wire, 'label': priceItemLabel(t, i)},
      ],
      'item': _item.wire,
      'askH': t.radarAsked,
      'cur': '${currencyFlag(cur)} $cur'.trim(),
      'curTxt': cur,
      'range': range == null
          ? null
          : <String, Object?>{'low': range.low, 'high': range.high},
      'loTxt': range == null ? '' : money(range.low * 0.6),
      'hiTxt': range == null ? '' : money(range.high * 1.8),
      'rangeTxt': range == null
          ? ''
          : '${money(range.low)} – ${money(range.high)}',
      'v': <String>[
        t.radarVerdictFine,
        t.radarVerdictBitHigh,
        t.radarVerdictOver,
      ],
      'noPrices': t.radarNoPrices,
      'payTxt': t.radarIPaid,
      'sentKey': _sentKey,
      'note': t.radarPricesNote,
      // El bocadillo de Flyra: sin previsión de lluvia para este punto.
      'flyOn': _rainFailed,
      'flyTitle': t.radarRainTitle,
      'flyText': t.radarRainFailed,
      'flyOk': t.settleOk,
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = _data(AppLocalizations.of(context));
    final String push = radarPushScript(data);
    if (_html == null) {
      _html = radarPageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    final AppServices services = ServicesScope.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }
}
