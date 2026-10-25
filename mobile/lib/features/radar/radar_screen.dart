// Radar local (maqueta "Radar"): lo que conviene saber AHORA donde estás.
//
//   1. ¿Va a llover? La previsión de las próximas horas (MET Norway).
//   2. Ojo en esta ciudad: timos que han avisado otros viajeros (solo se
//      enseñan con 3 personas o más; tú también puedes avisar).
//   3. ¿Me están cobrando de más? Comparas lo que te piden con lo que
//      pagaron otros viajeros en esa ciudad (con 5 o más precios).
//
// REGLA: nada inventado. Si aún no hay avisos o precios en una ciudad, la
// app lo dice tal cual ("aún no hay suficientes") en vez de rellenar.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../money/currency_info.dart';
import '../route/geo.dart' show LatLon;
import '../route/world_data.dart';
import '../sos/where_am_i.dart' show nearestAirport;
import 'radar_api.dart';

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

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  late final AppServices _services = ServicesScope.of(context);

  GeoPoint? _here;
  String? _city;
  String? _cityName;
  bool _locating = true;

  RainForecast? _rain;
  bool _rainFailed = false;

  CityRadar? _radar;
  ApiError? _radarError;

  PriceItem _item = PriceItem.coffee;
  String _currency = 'EUR';
  double? _asked;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    _city = widget.iata?.toUpperCase();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
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
        _pickCurrency();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _radarError = e.error);
    }
  }

  /// La moneda de los precios de esa cosa en esa ciudad (si hay).
  void _pickCurrency() {
    final PriceRange? r = _rangeFor(_item);
    if (r != null) _currency = r.currency;
  }

  PriceRange? _rangeFor(PriceItem item) =>
      _radar?.prices.where((PriceRange p) => p.item == item).firstOrNull;

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

  Future<void> _sendPrice() async {
    final String? city = _city;
    final double? asked = _asked;
    if (city == null || asked == null) return;
    try {
      await _services.radar.addPrice(city, _item, _currency, asked);
      if (mounted) setState(() => _sent = true);
      _snack((AppLocalizations t) => t.radarPriceThanks);
    } on ApiException catch (e) {
      _snack(
        (AppLocalizations t) => e.error == ApiError.rateLimited
            ? t.radarTooMany
            : t.radarSendFailed,
      );
    }
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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.radarTitle)),
      body: _locating
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: <Widget>[
                if (_city != null)
                  Text(
                    t.radarNowIn(_cityName ?? _city!),
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                const SizedBox(height: 12),
                Text(t.radarRainTitle, style: text.titleMedium),
                const SizedBox(height: 6),
                _rainCard(t),
                const SizedBox(height: 20),
                Text(t.radarScamsTitle, style: text.titleMedium),
                const SizedBox(height: 6),
                ..._scams(t),
                const SizedBox(height: 20),
                Text(t.radarPriceTitle, style: text.titleMedium),
                const SizedBox(height: 6),
                ..._prices(t),
              ],
            ),
    );
  }

  Widget _rainCard(AppLocalizations t) {
    final RainForecast? rain = _rain;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    if (_here == null) return Text(t.radarNoLocation);
    if (_rainFailed) return Text(t.radarRainFailed);
    if (rain == null) return const LinearProgressIndicator();
    final RainHour? first = rain.firstRain;
    final NumberFormat mm = NumberFormat.decimalPatternDigits(
      locale: locale,
      decimalDigits: 1,
    );
    final GeoPoint here = _here!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              first == null
                  ? t.radarNoRain(rain.hours.length)
                  : t.radarRainAt(
                      DateFormat.Hm(locale).format(first.time),
                      mm.format(first.rainMm),
                    ),
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: first == null ? NomadColors.mint : NomadColors.flights,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 70,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  for (final RainHour h in rain.hours)
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            height: 4 + (h.rainMm.clamp(0, 6) * 7),
                            decoration: BoxDecoration(
                              color: h.rainMm >= 0.2
                                  ? NomadColors.flights
                                  : NomadColors.outline,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            DateFormat.H(locale).format(h.time),
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (first != null)
              TextButton.icon(
                icon: const Icon(Icons.local_cafe_rounded),
                label: Text(t.radarFindShelter),
                // Google Maps busca cafés alrededor (gratis, sin clave).
                onPressed: () => unawaited(
                  _services.openBooking(
                    Uri.https(
                      'www.google.com',
                      '/maps/search/cafe/@${here.lat.toStringAsFixed(4)},${here.lon.toStringAsFixed(4)},16z',
                    ),
                  ),
                ),
              ),
            Text(
              rain.attribution,
              style: const TextStyle(
                fontSize: 11,
                color: NomadColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _scams(AppLocalizations t) {
    if (_city == null) return <Widget>[Text(t.radarNoCity)];
    if (_radarError == ApiError.signedOut) {
      return <Widget>[Text(t.radarSignIn)];
    }
    if (_radarError != null) return <Widget>[Text(t.radarSendFailed)];
    final CityRadar? radar = _radar;
    if (radar == null) return <Widget>[const LinearProgressIndicator()];
    return <Widget>[
      if (radar.scams.isEmpty)
        Text(
          t.radarNoScams,
          style: const TextStyle(color: NomadColors.textMuted),
        ),
      for (final MapEntry<ScamCategory, int> e in radar.scams.entries)
        Card(
          color: const Color(0xFF2A1A16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  scamTitle(t, e.key),
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: NomadColors.safety,
                  ),
                ),
                const SizedBox(height: 4),
                Text(scamAdvice(t, e.key)),
                const SizedBox(height: 4),
                Text(
                  t.radarReportedBy(e.value),
                  style: const TextStyle(
                    fontSize: 12,
                    color: NomadColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      const SizedBox(height: 8),
      Text(
        t.radarReportHint,
        style: const TextStyle(color: NomadColors.textMuted),
      ),
      const SizedBox(height: 6),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final ScamCategory c in ScamCategory.values)
            FilterChip(
              label: Text(scamTitle(t, c)),
              selected: radar.myScams.contains(c),
              onSelected: (_) => unawaited(_toggleScam(c)),
            ),
        ],
      ),
    ];
  }

  List<Widget> _prices(AppLocalizations t) {
    if (_city == null || _radarError != null || _radar == null) {
      return <Widget>[];
    }
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final PriceRange? range = _rangeFor(_item);
    final bool sameCurrency = range != null && range.currency == _currency;
    final double? asked = _asked;
    String money(double v) =>
        NumberFormat.simpleCurrency(locale: locale, name: _currency).format(v);
    final List<String> currencies = <String>['EUR', ...currencyCountry.keys];
    return <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final PriceItem i in PriceItem.values)
            ChoiceChip(
              label: Text(priceItemLabel(t, i)),
              selected: _item == i,
              onSelected: (_) => setState(() {
                _item = i;
                _sent = false;
                _pickCurrency();
              }),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(labelText: t.radarAsked),
              onChanged: (String v) {
                final double? x = double.tryParse(v.replaceAll(',', '.'));
                setState(() {
                  _asked = x != null && x > 0 && x < 1e7 ? x : null;
                  _sent = false;
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 130,
            child: DropdownButtonFormField<String>(
              initialValue: _currency,
              isExpanded: true,
              items: <DropdownMenuItem<String>>[
                for (final String c in currencies)
                  DropdownMenuItem<String>(
                    value: c,
                    child: Text('${currencyFlag(c)} $c'),
                  ),
              ],
              onChanged: (String? c) {
                if (c != null) setState(() => _currency = c);
              },
            ),
          ),
        ],
      ),
      const SizedBox(height: 10),
      if (!sameCurrency)
        Text(
          t.radarNoPrices,
          style: const TextStyle(color: NomadColors.textMuted),
        )
      else ...<Widget>[
        Text(
          t.radarNormalRange(
            money(range.low),
            money(range.high),
            range.reporters,
          ),
        ),
        if (asked != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            switch (verdictFor(asked, range)) {
              PriceVerdict.fine => t.radarVerdictFine,
              PriceVerdict.bitHigh => t.radarVerdictBitHigh,
              PriceVerdict.overcharged => t.radarVerdictOver,
            },
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: switch (verdictFor(asked, range)) {
                PriceVerdict.fine => NomadColors.mint,
                PriceVerdict.bitHigh => NomadColors.money,
                PriceVerdict.overcharged => NomadColors.safety,
              },
            ),
          ),
        ],
      ],
      const SizedBox(height: 8),
      OutlinedButton.icon(
        icon: Icon(_sent ? Icons.check_rounded : Icons.add_task_rounded),
        label: Text(t.radarIPaid),
        onPressed: asked == null || _sent
            ? null
            : () => unawaited(_sendPrice()),
      ),
      const SizedBox(height: 6),
      Text(
        t.radarPricesNote,
        style: const TextStyle(fontSize: 12, color: NomadColors.textMuted),
      ),
    ];
  }
}
