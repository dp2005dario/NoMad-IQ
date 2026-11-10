// Antes de salir (maqueta "Antes"): la maqueta tal cual dentro de un WebView
// (assets/trip/antes.html, hecha con tool/antes/build_page.py) con los datos
// de TU viaje. En el mismo orden que la maqueta:
//   1. Cabecera: el círculo de "% listo" y "País · Ciudad · sales en N días"
//      (tocándolo cambias el viaje: es el mismo de Modo fácil y Aeropuerto).
//   2. "<PAÍS> EN 30 SEGUNDOS": tarjetas que se dan la vuelta al tocarlas.
//      Detrás de cada una pone de dónde sale el dato ("FUENTE · ...").
//   3. "Consejos de Flyra": uno cada vez; tocándolo vas a su pantalla.
//   4. "Para la maleta": la lista con casillas.
//   5. Datos móviles y seguro médico.
//   6. "Reels de <país>": búsquedas en TikTok, Instagram y YouTube (no
//      enseñamos vídeos inventados); se pueden guardar en tu viaje.
//
// De dónde sale cada cosa (todo real, nada inventado):
//   - Enchufes: tabla de la IEC (plugs.dart).
//   - Moneda, idioma y lado de conducir: REST Countries + CLDR, dentro de la
//     app (country_facts.dart).
//   - Emergencias: la tabla del SOS (sos/emergency_data.dart).
//   - Hora: la base de husos horarios de IANA (paquete timezone).
//   - Visado: la tabla de Passport Index (visa/visa_data.dart).
//   - Papeles: la Bóveda de este móvil (pasaporte y seguro).
//   - Para la maleta: el enchufe del país y el clima medio del mes (NASA).
// Si de un país falta un dato, su tarjeta no sale: mejor nada que inventar
// (por eso no salen las de propinas, agua del grifo, costumbres ni pagos de
// la maqueta: no hay una fuente gratis y fiable para todos los países).
// Lo que marcas se guarda SOLO en el móvil.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_home_screen.dart' show EasyTripSheet;
import '../easy/easy_mode.dart';
import '../flights/climate_api.dart';
import '../money/money_screen.dart' show MoneyTab;
import '../route/flight3d.dart' show CountryCodes;
import '../route/web_scene.dart';
import '../route/world_data.dart';
import '../sos/emergency_data.dart';
import '../visa/visa_data.dart';
import 'before_page.dart';
import 'before_trip.dart';
import 'country_facts.dart';
import 'plugs.dart';
import 'trip_check.dart';

class BeforeTripScreen extends StatefulWidget {
  const BeforeTripScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<BeforeTripScreen> createState() => _BeforeTripScreenState();
}

class _BeforeTripScreenState extends State<BeforeTripScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final PackList _packing = PackList(_services.prefs);
  final WebSceneBridge _bridge = BeforeTripScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  late EasyTrip _trip = loadEasyTrip(_services.prefs);
  Airports? _airports;
  CountryCodes? _codes;
  MonthClimate? _climate;
  TripChecks? _checks;
  Set<String> _done = <String>{};
  Set<String> _saved = <String>{};
  bool _working = false;
  // Qué viaje se revisó ya: la Bóveda solo pide la huella UNA vez por viaje.
  String? _checkedFor;

  // Los datos fijos de los países (nombres, monedas, idiomas, visados). Se
  // cargan SOLO cuando ya sabemos a dónde vas.
  CountryFacts? _facts;
  CountryNames? _names;
  VisaTable? _visas;

  @override
  void initState() {
    super.initState();
    _done = _packing.done();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    _saved = savedReels(_services.prefs.readData(LocalData.beforeReels));
    try {
      _pageCache ??= await rootBundle.loadString(beforePage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    await _loadWorld();
  }

  Future<void> _loadWorld() async {
    try {
      final WorldData world = await WorldData.load();
      final CountryCodes codes = await CountryCodes.load();
      if (!mounted) return;
      setState(() {
        _airports = world.airports;
        _codes = codes;
      });
      unawaited(_check());
    } on Object {
      // Sin los datos del mundo no se puede calcular nada: la página dice
      // "Dinos a dónde vas".
    }
  }

  /// Lee las tablas de países la primera vez que hacen falta. Si una falla,
  /// sus tarjetas simplemente no salen.
  Future<void> _loadFacts() async {
    try {
      final CountryFacts facts = await CountryFacts.load();
      if (mounted) setState(() => _facts = facts);
    } on Object {
      // Sin la tabla, no salen las tarjetas de moneda, idioma ni conducir.
    }
    try {
      final CountryNames names = await CountryNames.load();
      if (mounted) setState(() => _names = names);
    } on Object {
      // Sin nombres se enseña el código del país (ES, JP...).
    }
    try {
      final VisaTable visas = await VisaTable.load();
      if (mounted) setState(() => _visas = visas);
    } on Object {
      // Sin la tabla, el consejo del visado manda a la pantalla de Visado.
    }
  }

  Airport? get _origin =>
      _airportOf(_trip.from ?? _services.prefs.readFlightOrigin() ?? '');
  Airport? get _destination => _airportOf(_trip.to ?? '');

  Airport? _airportOf(String code) {
    final Airports? all = _airports;
    final String c = code.trim().toUpperCase();
    if (all == null || c.length != 3) return null;
    return all[c];
  }

  String? get _homeCountry {
    final Airport? a = _origin;
    return a == null ? null : _codes?[a.country];
  }

  String? get _thereCountry {
    final Airport? a = _destination;
    return a == null ? null : _codes?[a.country];
  }

  /// "Cambiar el viaje": la misma hoja que Modo fácil (el viaje es el mismo).
  Future<void> _editTrip() async {
    final EasyTrip? trip = await showModalBottomSheet<EasyTrip>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => EasyTripSheet(trip: _trip),
    );
    if (trip == null || !mounted) return;
    await saveEasyTrip(_services.prefs, trip);
    if (!mounted) return;
    setState(() => _trip = trip);
    unawaited(_check());
  }

  /// Revisa el viaje: papeles de la Bóveda y clima del mes de la salida.
  Future<void> _check() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final Airport? to = _destination;
    final DateTime day = _trip.departure ?? DateTime.now();
    if (to == null || _working) return;
    final String trip = '${_origin?.iata}-${to.iata}-${day.month}';
    if (trip == _checkedFor) return;
    _checkedFor = trip;
    setState(() => _working = true);
    if (_facts == null) await _loadFacts();
    // Los papeles: la Bóveda se abre con tu huella y solo se miran fechas.
    if (!_services.vault.isOpen) {
      await _services.vault.open(t.vaultUnlockReason);
    }
    TripChecks? checks;
    if (_services.vault.isOpen) {
      // La vuelta no se sabe aquí: se supone una semana después, que es lo
      // justo para avisar del margen del pasaporte.
      checks = checkTrip(
        _services.vault.docs,
        day.add(const Duration(days: 7)),
      );
    }
    MonthClimate? climate;
    try {
      final List<MonthClimate> months = await _services.climate.at(
        to.position.lat,
        to.position.lon,
      );
      climate = months
          .where((MonthClimate c) => c.month == day.month)
          .firstOrNull;
    } on ApiException {
      // El clima es un extra: sin él, la lista sale sin ropa.
    }
    if (!mounted) return;
    setState(() {
      _checks = checks;
      _climate = climate;
      _working = false;
    });
  }

  List<PackItem> get _items => _destination == null
      ? const <PackItem>[]
      : packingFor(
          homePower: powerOf(_homeCountry),
          therePower: powerOf(_thereCountry),
          climate: _climate,
          roaming: _roaming,
          passportSoon: _checks != null && _checks!.passport != CheckState.ok,
          noInsurance: _checks != null && _checks!.insurance != CheckState.ok,
        );

  RoamingStatus get _roaming =>
      roamingFor(homeCountry: _homeCountry, destination: _thereCountry);

  Future<void> _setDone(String id, bool ready) async {
    await _packing.setDone(id, ready: ready);
    if (mounted) setState(() => _done = _packing.done());
  }

  Future<void> _setSaved(String title, bool on) async {
    final Set<String> all = savedReels(
      _services.prefs.readData(LocalData.beforeReels),
    );
    if (on) {
      all.add(title);
    } else {
      all.remove(title);
    }
    await _services.prefs.writeData(
      LocalData.beforeReels,
      jsonEncode(all.toList()),
    );
    if (mounted) setState(() => _saved = all);
  }

  /// El nombre del país en tu idioma ("Japón"), o su código si no se sabe.
  String _countryName(String code, String lang) =>
      _names?.name(code, lang) ?? code;

  List<BeforeReel> _reels(String lang) {
    final Airport? to = _destination;
    final String? c = _thereCountry;
    if (to == null || c == null) return const <BeforeReel>[];
    return reelsFor(to.city, _countryName(c, lang));
  }

  List<_Tip> _tipsNow(AppLocalizations t, String lang) {
    final Airport? to = _destination;
    final String? c = _thereCountry;
    if (to == null || c == null) return const <_Tip>[];
    return _tipsFor(t, lang, c, _countryName(c, lang), to);
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    final List<String> p = m.split(':');
    final int? a = p.length > 1 ? int.tryParse(p[1]) : null;
    final int? b = p.length > 2 ? int.tryParse(p[2]) : null;
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'options':
        unawaited(_editTrip());
      case 'pack' when a != null && b != null:
        final List<PackItem> items = _items;
        if (b < items.length) unawaited(_setDone(items[b].id, a == 1));
      case 'esim' when _roaming == RoamingStatus.abroad:
        unawaited(_setDone('esim', !_done.contains('esim')));
      case 'ins':
        unawaited(context.push(Routes.vault));
      case 'tip' when a != null:
        final List<_Tip> tips = _tipsNow(t, lang);
        if (a < tips.length) unawaited(context.push(tips[a].route));
      case 'reel' when a != null:
        final List<BeforeReel> reels = _reels(lang);
        if (a < reels.length) unawaited(_services.openLink(reels[a].url));
      case 'save' when a != null && b != null:
        final List<BeforeReel> reels = _reels(lang);
        if (b < reels.length) unawaited(_setSaved(reels[b].title, a == 1));
    }
  }

  Map<String, Object?> _data(AppLocalizations t, String lang) {
    final Airport? to = _destination;
    final String? country = _thereCountry;
    final String name = country == null ? '' : _countryName(country, lang);
    final List<PackItem> items = _items;
    final DateTime? day = _trip.departure;
    final String place = to == null
        ? ''
        : name.isEmpty
        ? to.city
        : '$name · ${to.city}';
    int daysLeft(DateTime d) {
      final DateTime now = DateTime.now();
      return DateTime(d.year, d.month, d.day)
          .difference(DateTime(now.year, now.month, now.day))
          .inDays
          .clamp(0, 9999);
    }

    final RoamingStatus roaming = _roaming;
    final bool esimDone = _done.contains('esim');
    final bool insOk = _checks?.insurance == CheckState.ok;
    final List<BeforeReel> reels = _reels(lang);
    final List<_Tip> tips = _tipsNow(t, lang);
    return <String, Object?>{
      'key': to?.iata ?? '',
      'sub': to == null
          ? t.beforeFillTrip
          : day == null
          ? place
          : t.beforeSubtitle(place, daysLeft(day)),
      'pct': items.isEmpty ? 0 : (readiness(items, _done) * 100).round(),
      'heroK':
          (to == null
                  ? t.beforeTitle
                  : t.beforeFactsEyebrow(name.isEmpty ? to.city : name))
              .toUpperCase(),
      'torii': country == 'JP',
      'factsH': name.isEmpty ? '' : 'Lo importante de $name',
      'emptyTxt': _working ? '…' : t.beforeFillTrip,
      'facts': country == null || to == null || _working
          ? const <Object?>[]
          : _factsFor(t, lang, country, to),
      'tipsH': t.beforeTipsTitle(name),
      // "FUENTE · {source}" en tu idioma (la página pone la fuente).
      'srcFmt': t.beforeSource('{source}'),
      'tips': <Map<String, Object?>>[
        for (final _Tip tip in tips)
          <String, Object?>{'t': tip.text, 's': tip.source},
      ],
      'pack': <Map<String, Object?>>[
        for (final PackItem i in items)
          <String, Object?>{
            'id': i.id,
            't': textsFor(t, i).$1,
            'w': textsFor(t, i).$2,
          },
      ],
      'done': _done.toList()..sort(),
      'esim': <String, Object?>{
        'txt': switch (roaming) {
          RoamingStatus.free => 'Sin coste extra',
          _ => esimDone ? '✓ Instalada' : 'Elegir eSIM',
        },
        'sub': switch (roaming) {
          RoamingStatus.free => 'Tu tarifa europea vale allí',
          RoamingStatus.abroad => 'eSIM de viaje · se activa al aterrizar',
          RoamingStatus.unknown => '',
        },
        'on': roaming == RoamingStatus.free || esimDone,
      },
      'ins': <String, Object?>{
        'txt': insOk ? '✓ Activo' : t.beforeInsuranceAdd,
        'sub': insOk ? 'Guardado en tu Bóveda' : 'Guárdalo en tu Bóveda',
        'on': insOk,
      },
      'reelsH': t.beforeReelsTitle(name),
      'reels': reelsJson(reels, 'Búsqueda en su app oficial'),
      'saved': <int>[
        for (int i = 0; i < reels.length; i++)
          if (_saved.contains(reels[i].title)) i,
      ],
      'how': const <String, String>{
        'tt': 'Se abre TikTok con los vídeos de esta búsqueda, con su autor y en su app oficial.',
        'ig': 'Se abre Instagram con las publicaciones de esta etiqueta, en su app oficial.',
        'yt': 'Se abre YouTube con los Shorts de esta búsqueda, en su app oficial.',
      },
      'saveTxt': 'Guardar en mi viaje a $name',
      'savedTxt': '✓ Guardado en tu viaje',
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
    final AppLocalizations t = AppLocalizations.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    final Map<String, Object?> data = _data(t, lang);
    final String push = beforePushScript(data);
    if (_html == null) {
      _html = beforePageWith(page, data);
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
            _services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }

  /// Las tarjetas de "(país) en 30 segundos". Solo las que tienen dato.
  List<Map<String, Object?>> _factsFor(
    AppLocalizations t,
    String lang,
    String country,
    Airport to,
  ) {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    // Enchufe y voltaje.
    final Power? there = powerOf(country);
    final Power? home = powerOf(_homeCountry);
    if (there != null) {
      final List<String> types = there.plugs.split('/');
      final bool adapter = home == null || there.needsAdapterFrom(home);
      final bool transformer = home != null && there.needsTransformerFrom(home);
      out.add(
        factJson(
          key: t.beforeFactPlug,
          value: '${t.beforePlugType(types.join('/'))} · ${there.volts} V',
          more: <String>[
            adapter ? t.beforePlugsNeed(types.join(', ')) : t.beforePlugsNoNeed,
            if (transformer) t.beforePlugsTransformer,
          ].join(' '),
          source: iecSource,
          icon: 'plug',
          color: '#6CA8FF',
        ),
      );
    }
    final CountryFact? fact = _facts?[country];
    // Moneda: "Yen (¥ JPY)", como en la maqueta (solo la primera palabra).
    if (fact != null && fact.currencies.isNotEmpty) {
      final CountryFacts facts = _facts!;
      final String code = fact.currencies.first;
      final String sym = facts.symbol(code);
      out.add(
        factJson(
          key: t.beforeFactCurrency,
          value:
              '${_capital(facts.currencyName(code, lang).split(' ').first)} (${sym == code ? code : '$sym $code'})',
          more: t.beforeCurrencyMore,
          source: '$restCountriesSource + $ecbSource',
          icon: 'yen',
          color: '#FFD27A',
        ),
      );
    }
    // Emergencias (si el país no está, el 112, como hace el SOS).
    final EmergencyNumbers n = numbersFor(country);
    final List<String> numbers = <String>{
      ?n.police,
      ?n.ambulance,
      ?n.fire,
    }.toList();
    out.add(
      factJson(
        key: t.beforeFactEmergency,
        value: numbers.isEmpty ? n.general : numbers.take(2).join(' · '),
        more: <String>[
          if (n.police != null) t.beforeEmergencyLine(t.sosPolice, n.police!),
          if (n.ambulance != null)
            t.beforeEmergencyLine(t.sosAmbulance, n.ambulance!),
          if (n.fire != null) t.beforeEmergencyLine(t.sosFire, n.fire!),
          t.beforeEmergencyMore,
        ].join('. '),
        source: emergencyWikiSource,
        icon: 'sos',
        color: '#FF4D4D',
      ),
    );
    // Por dónde se conduce.
    final bool? left = fact?.drivesLeft;
    if (left != null) {
      out.add(
        factJson(
          key: t.beforeFactDrive,
          value: left ? t.beforeDriveLeft : t.beforeDriveRight,
          more: left ? t.beforeDriveLeftMore : t.beforeDriveRightMore,
          source: restCountriesSource,
          icon: 'car',
          color: '#FFB86B',
        ),
      );
    }
    // Idioma.
    if (fact != null && fact.languages.isNotEmpty) {
      out.add(
        factJson(
          key: t.beforeFactLanguage,
          value: fact.languages
              .take(2)
              .map((String l) => _capital(_facts!.languageName(l, lang)))
              .join(', '),
          more: t.beforeLanguageMore,
          source: cldrSource,
          icon: 'talk',
          color: '#FF7AB6',
        ),
      );
    }
    // Hora: la diferencia con tu móvil ahora y dentro de 6 meses.
    final (String now, String later)? hours = _hoursAt(t, to.timeZone);
    if (hours != null) {
      out.add(
        factJson(
          key: t.beforeFactTime,
          value: hours.$1,
          more: t.beforeTimeMore(hours.$2),
          source: ianaSource,
          icon: 'clock',
          color: '#6CA8FF',
        ),
      );
    }
    return out;
  }

  static bool _tzReady = false;

  /// La diferencia de hora con el destino, ahora y dentro de 6 meses (por
  /// el horario de verano puede cambiar). null si la zona no se conoce.
  (String, String)? _hoursAt(AppLocalizations t, String zone) {
    if (zone.isEmpty) return null;
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }
    try {
      final tz.Location place = tz.getLocation(zone);
      final DateTime now = DateTime.now();
      final DateTime later = now.add(const Duration(days: 182));
      String diff(DateTime when) =>
          hoursDiff(
            tz.TZDateTime.from(when, place).timeZoneOffset,
            when.timeZoneOffset,
          ) ??
          t.beforeTimeSame;
      return (diff(now), diff(later));
    } on tz.LocationNotFoundException {
      return null;
    }
  }

  /// Los consejos de Flyra, cada uno con su fuente y a dónde lleva.
  List<_Tip> _tipsFor(
    AppLocalizations t,
    String lang,
    String country,
    String countryName,
    Airport to,
  ) {
    final List<_Tip> tips = <_Tip>[];
    // Visado con TU pasaporte (el que guardaste en Visado).
    final String? passport = _services.prefs.readData(LocalData.visaPassport);
    final VisaTable? visas = _visas;
    if (passport != null && passport.isNotEmpty && visas != null) {
      final EntryRequirement need = visas.lookup(passport, country);
      if (need.rule != EntryRule.unknown) {
        tips.add(
          _Tip(
            t.beforeTipVisa(_countryName(passport, lang), switch (need.rule) {
              EntryRule.free => t.visaFree,
              EntryRule.onArrival => t.visaOnArrival,
              EntryRule.eta => t.visaEta,
              EntryRule.eVisa => t.visaEVisa,
              EntryRule.embassy => t.visaEmbassy,
              EntryRule.refused => t.visaRefused,
              EntryRule.unknown => t.visaUnknown,
            }),
            passportIndexSource,
            Routes.visa(to: country),
          ),
        );
      }
    }
    if (tips.isEmpty) {
      tips.add(
        _Tip(
          t.beforeTipVisaPick(countryName),
          passportIndexSource,
          Routes.visa(to: country),
        ),
      );
    }
    // El cambio de moneda.
    final CountryFact? fact = _facts?[country];
    if (fact != null && fact.currencies.isNotEmpty) {
      tips.add(
        _Tip(
          t.beforeTipFx(_facts!.currencyName(fact.currencies.first, lang)),
          ecbSource,
          Routes.money(tab: MoneyTab.fx),
        ),
      );
    }
    // La ciudad sin conexión.
    tips.add(
      _Tip(t.beforeTipOffline(to.city), t.beforeSourceYours, Routes.offline),
    );
    // El seguro y el pasaporte, según tu Bóveda.
    final TripChecks? checks = _checks;
    if (checks != null) {
      tips.add(
        _Tip(
          checks.insurance == CheckState.ok
              ? t.beforeTipInsuranceOk
              : t.beforeTipInsuranceNo,
          t.beforeSourceYours,
          Routes.vault,
        ),
      );
    }
    tips.add(_Tip(t.beforeTipPassport, t.beforeSourceYours, Routes.vault));
    return tips;
  }
}

/// "yen japonés" → "Yen japonés" (solo cambia la primera letra).
String _capital(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

/// Un consejo de Flyra: el texto, de dónde sale y a dónde lleva.
class _Tip {
  const _Tip(this.text, this.source, this.route);

  final String text;
  final String source;
  final String route;
}

/// El texto de cada apunte en el idioma de la app.
(String, String) textsFor(AppLocalizations t, PackItem item) =>
    switch (item.kind) {
      PackKind.adapter => (
        t.beforePackAdapter(item.detail),
        t.beforePackAdapterWhy,
      ),
      PackKind.transformer => (
        t.beforePackTransformer(item.detail),
        t.beforePackTransformerWhy,
      ),
      PackKind.umbrella => (
        t.beforePackUmbrella(item.detail),
        t.beforePackUmbrellaWhy(item.detail),
      ),
      PackKind.coat => (
        t.beforePackCoat(item.detail),
        t.beforePackCoatWhy(item.detail),
      ),
      PackKind.sunscreen => (
        t.beforePackSunscreen(item.detail),
        t.beforePackSunscreenWhy(item.detail),
      ),
      PackKind.esim => (t.beforePackEsim, t.beforePackEsimWhy),
      PackKind.offline => (t.beforePackOffline, t.beforePackOfflineWhy),
      PackKind.passport => (t.beforePackPassport, t.beforePackPassportWhy),
      PackKind.insurance => (t.beforePackInsurance, t.beforePackInsuranceWhy),
    };
