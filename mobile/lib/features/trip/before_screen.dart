// Antes de salir (maqueta "Antes", pantalla 22): una sola pantalla con todo
// lo que hay que tener resuelto antes de un viaje, en el mismo orden que la
// maqueta:
//   1. Cabecera: el círculo de "% listo" y "País · Ciudad · sales en N días".
//   2. "<PAÍS> EN 30 SEGUNDOS": tarjetas que se dan la vuelta al tocarlas
//      (enchufe, moneda, emergencias, por dónde se conduce, idioma y hora).
//      Detrás de cada una pone de dónde sale el dato ("FUENTE · ...").
//   3. "Consejos de Flyra": uno cada vez, con puntos y "Otro consejo →".
//   4. "Para la maleta": la lista con casillas.
//   5. Dos tarjetas: datos móviles y seguro médico.
//   6. "Reels de <país>": botones que abren TikTok, Instagram y YouTube ya
//      buscando el país (no enseñamos vídeos inventados).
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
// Si de un país falta un dato, su tarjeta no sale: mejor nada que inventar.
// Lo que marcas se guarda SOLO en el móvil.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/climate_api.dart';
import '../money/money_screen.dart' show MoneyTab;
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';
import '../sos/emergency_data.dart';
import '../visa/visa_data.dart';
import 'before_trip.dart';
import 'country_facts.dart';
import 'plugs.dart';
import 'trip_check.dart';

class BeforeTripScreen extends StatefulWidget {
  const BeforeTripScreen({super.key});

  @override
  State<BeforeTripScreen> createState() => _BeforeTripScreenState();
}

class _BeforeTripScreenState extends State<BeforeTripScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final PackList _packing = PackList(_services.prefs);
  final TextEditingController _from = TextEditingController();
  final TextEditingController _to = TextEditingController();

  Airports? _airports;
  CountryCodes? _codes;
  DateTime? _day;
  MonthClimate? _climate;
  TripChecks? _checks;
  Set<String> _done = <String>{};
  bool _working = false;
  // Qué viaje se revisó ya. Así, si escribes las letras del aeropuerto una a
  // una, la Bóveda solo pide la huella UNA vez por viaje (y no en cada letra).
  String? _checkedFor;

  // Los datos fijos de los países (nombres, monedas, idiomas, visados). Se
  // cargan SOLO cuando ya sabemos a dónde vas: así no se leen si no hacen
  // falta.
  CountryFacts? _facts;
  CountryNames? _names;
  VisaTable? _visas;

  @override
  void initState() {
    super.initState();
    _from.text = _services.prefs.readFlightOrigin() ?? '';
    _done = _packing.done();
    unawaited(_loadWorld());
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _loadWorld() async {
    try {
      final WorldData world = await WorldData.load();
      final CountryCodes codes = await CountryCodes.load();
      if (mounted) {
        setState(() {
          _airports = world.airports;
          _codes = codes;
        });
      }
    } on Object {
      // Sin los datos del mundo no se puede calcular nada: la pantalla lo
      // dice en los campos ("no conocemos ese aeropuerto").
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

  Airport? get _origin => _airportOf(_from.text);
  Airport? get _destination => _airportOf(_to.text);

  Airport? _airportOf(String code) {
    // Ojo: aquí NO se puede usar "c.length == 3 ? _airports?[c] : null", porque
    // Dart confunde el "?" del si-no con el "?[" de la búsqueda; con un if queda
    // igual de corto y además se lee mejor.
    final Airports? all = _airports;
    final String c = code.trim();
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

  /// Al escribir las letras del aeropuerto: se repinta y, si ya está todo
  /// (ida, vuelta y día), se revisa el viaje.
  void _codeTyped(String _) {
    setState(() {});
    if (_day != null && _destination != null) unawaited(_check());
  }

  Future<void> _pickDay() async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2, now.month, now.day),
      initialDate: _day ?? now.add(const Duration(days: 14)),
    );
    if (d != null && mounted) {
      setState(() => _day = d);
      unawaited(_check());
    }
  }

  /// Revisa el viaje: papeles de la Bóveda y clima del mes de la salida.
  Future<void> _check() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final Airport? to = _destination;
    final DateTime? day = _day;
    if (to == null || day == null || _working) return;
    final String trip = '${_origin?.iata}-${to.iata}-${day.month}';
    if (trip == _checkedFor) return;
    _checkedFor = trip;
    setState(() => _working = true);
    if (_facts == null) unawaited(_loadFacts());
    // Los papeles: la Bóveda se abre con tu huella y solo se miran fechas.
    if (!_services.vault.isOpen) {
      await _services.vault.open(t.vaultUnlockReason);
    }
    TripChecks? checks;
    if (_services.vault.isOpen) {
      // La vuelta no se pregunta aquí: se supone una semana después, que es
      // lo justo para avisar del margen del pasaporte.
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

  List<PackItem> get _items => packingFor(
    homePower: powerOf(_homeCountry),
    therePower: powerOf(_thereCountry),
    climate: _climate,
    roaming: roamingFor(homeCountry: _homeCountry, destination: _thereCountry),
    passportSoon: _checks != null && _checks!.passport != CheckState.ok,
    noInsurance: _checks != null && _checks!.insurance != CheckState.ok,
  );

  Future<void> _toggle(String id) async {
    final bool ready = !_done.contains(id);
    await _packing.setDone(id, ready: ready);
    if (mounted) setState(() => _done = _packing.done());
  }

  /// El nombre del país en tu idioma ("Japón"), o su código si no se sabe.
  String _countryName(String code, String lang) =>
      _names?.name(code, lang) ?? code;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String lang = Localizations.localeOf(context).languageCode;
    final Airport? to = _destination;
    final DateTime? day = _day;
    final bool ready = to != null && day != null;
    final List<PackItem> items = _items;
    final String? country = _thereCountry;
    final String countryName = country == null
        ? ''
        : _countryName(country, lang);
    final RoamingStatus roaming = roamingFor(
      homeCountry: _homeCountry,
      destination: country,
    );
    return Scaffold(
      appBar: AppBar(title: Text(t.beforeTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          if (!ready)
            Text(
              t.beforeFillTrip,
              style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
            )
          else
            _Header(
              place: countryName.isEmpty
                  ? to.city
                  : '$countryName · ${to.city}',
              day: day,
              ready: readiness(items, _done),
            ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: _Iata(
                  controller: _from,
                  label: t.searchFrom,
                  onChanged: _codeTyped,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Iata(
                  controller: _to,
                  label: t.searchTo,
                  onChanged: _codeTyped,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDay,
            icon: const Icon(Icons.event_rounded),
            label: Text(
              day == null
                  ? t.searchPickDate
                  : DateFormat.yMMMd(
                      Localizations.localeOf(context).toLanguageTag(),
                    ).format(day),
            ),
          ),
          if (_working)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (ready && !_working && country != null) ...<Widget>[
            const SizedBox(height: 24),
            // 2. El país en 30 segundos.
            Text(
              t.beforeFactsEyebrow(countryName).toUpperCase(),
              style: text.labelMedium?.copyWith(
                color: NomadColors.mint,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(t.beforeFactsTitle, style: text.titleLarge),
            Text(
              t.beforeFactsHint(countryName),
              style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 10),
            _FactGrid(facts: _factsFor(t, lang, country, to)),
            const SizedBox(height: 24),
            // 3. Los consejos de Flyra.
            _Tips(
              title: t.beforeTipsTitle(countryName),
              tips: _tipsFor(t, lang, country, countryName, to),
            ),
            const SizedBox(height: 24),
            // 4. La maleta.
            _Section(t.beforePackTitle),
            for (final PackItem item in items)
              _PackTile(
                item: item,
                done: _done.contains(item.id),
                onTap: () => unawaited(_toggle(item.id)),
              ),
            const SizedBox(height: 16),
            // 5. Datos móviles y seguro médico.
            _InfoCard(
              icon: Icons.signal_cellular_alt_rounded,
              color: NomadColors.flights,
              title: t.beforeDataTitle,
              body: switch (roaming) {
                RoamingStatus.free => t.beforeRoamingFree,
                RoamingStatus.abroad => t.beforeRoamingAbroad,
                RoamingStatus.unknown => t.beforeFillTrip,
              },
              action: roaming == RoamingStatus.abroad
                  ? _done.contains('esim')
                        ? _CardAction.done(t.beforeDone)
                        : _CardAction(
                            t.beforeEsimTodo,
                            () => unawaited(_toggle('esim')),
                          )
                  : null,
            ),
            const SizedBox(height: 12),
            _InfoCard(
              icon: Icons.health_and_safety_rounded,
              color: NomadColors.safety,
              title: t.beforeInsuranceTitle,
              body: _checks?.insurance == CheckState.ok
                  ? t.beforeInsuranceOk
                  : t.beforePackInsuranceWhy,
              action: _checks?.insurance == CheckState.ok
                  ? null
                  : _CardAction(
                      t.beforeInsuranceAdd,
                      () => unawaited(context.push(Routes.vault)),
                    ),
            ),
            const SizedBox(height: 24),
            // 6. Reels del país, en su app oficial.
            _Reels(country: countryName),
          ],
        ],
      ),
    );
  }

  /// Las tarjetas de "(país) en 30 segundos". Solo las que tienen dato.
  List<_Fact> _factsFor(
    AppLocalizations t,
    String lang,
    String country,
    Airport to,
  ) {
    final List<_Fact> out = <_Fact>[];
    // Enchufe y voltaje.
    final Power? there = powerOf(country);
    final Power? home = powerOf(_homeCountry);
    if (there != null) {
      final List<String> types = there.plugs.split('/');
      final bool adapter = home == null || there.needsAdapterFrom(home);
      final bool transformer = home != null && there.needsTransformerFrom(home);
      out.add(
        _Fact(
          icon: Icons.power_rounded,
          title: t.beforeFactPlug,
          value: '${t.beforePlugType(types.join('/'))} · ${there.volts} V',
          more: <String>[
            adapter ? t.beforePlugsNeed(types.join(', ')) : t.beforePlugsNoNeed,
            if (transformer) t.beforePlugsTransformer,
          ].join('\n'),
          source: iecSource,
        ),
      );
    }
    final CountryFact? fact = _facts?[country];
    // Moneda.
    if (fact != null && fact.currencies.isNotEmpty) {
      final CountryFacts facts = _facts!;
      final String code = fact.currencies.first;
      out.add(
        _Fact(
          icon: Icons.payments_rounded,
          title: t.beforeFactCurrency,
          value:
              '${facts.symbol(code)} · ${_capital(facts.currencyName(code, lang))}',
          more: t.beforeCurrencyMore,
          source: cldrSource,
        ),
      );
    }
    // Emergencias (si el país no está, el 112, como hace el SOS).
    final EmergencyNumbers n = numbersFor(country);
    out.add(
      _Fact(
        icon: Icons.emergency_rounded,
        title: t.beforeFactEmergency,
        value: n.general,
        more: <String>[
          if (n.police != null) t.beforeEmergencyLine(t.sosPolice, n.police!),
          if (n.ambulance != null)
            t.beforeEmergencyLine(t.sosAmbulance, n.ambulance!),
          if (n.fire != null) t.beforeEmergencyLine(t.sosFire, n.fire!),
          t.beforeEmergencyMore,
        ].join('\n'),
        source: emergencyWikiSource,
      ),
    );
    // Por dónde se conduce.
    final bool? left = fact?.drivesLeft;
    if (left != null) {
      out.add(
        _Fact(
          icon: Icons.directions_car_rounded,
          title: t.beforeFactDrive,
          value: left ? t.beforeDriveLeft : t.beforeDriveRight,
          more: left ? t.beforeDriveLeftMore : t.beforeDriveRightMore,
          source: restCountriesSource,
        ),
      );
    }
    // Idioma.
    if (fact != null && fact.languages.isNotEmpty) {
      out.add(
        _Fact(
          icon: Icons.translate_rounded,
          title: t.beforeFactLanguage,
          value: fact.languages
              .take(3)
              .map((String l) => _capital(_facts!.languageName(l, lang)))
              .join(', '),
          more: t.beforeLanguageMore,
          source: cldrSource,
        ),
      );
    }
    // Hora: la diferencia con tu móvil ahora y dentro de 6 meses.
    final (String now, String later)? hours = _hoursAt(t, to.timeZone);
    if (hours != null) {
      out.add(
        _Fact(
          icon: Icons.schedule_rounded,
          title: t.beforeFactTime,
          value: hours.$1,
          more: t.beforeTimeMore(hours.$2),
          source: ianaSource,
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

/// Una tarjeta de "(país) en 30 segundos".
class _Fact {
  const _Fact({
    required this.icon,
    required this.title,
    required this.value,
    required this.more,
    required this.source,
  });

  final IconData icon;
  final String title;
  final String value;
  final String more;
  final String source;
}

/// Las tarjetas en dos columnas.
class _FactGrid extends StatelessWidget {
  const _FactGrid({required this.facts});

  final List<_Fact> facts;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      for (int i = 0; i < facts.length; i += 2)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          // IntrinsicHeight: las dos tarjetas de la fila miden lo mismo.
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: _FlipCard(fact: facts[i])),
                const SizedBox(width: 10),
                Expanded(
                  child: i + 1 < facts.length
                      ? _FlipCard(fact: facts[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

/// Una tarjeta que se da la vuelta al tocarla: delante el dato, detrás la
/// explicación y la fuente.
class _FlipCard extends StatefulWidget {
  const _FlipCard({required this.fact});

  final _Fact fact;

  @override
  State<_FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<_FlipCard> {
  bool _back = false;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final _Fact f = widget.fact;
    final Widget front = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(f.icon, color: NomadColors.mint, size: 22),
        const SizedBox(height: 6),
        Text(
          f.title,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
        Text(
          f.value,
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w800),
        ),
      ],
    );
    final Widget back = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(f.more, style: text.bodySmall),
        const SizedBox(height: 6),
        Text(
          AppLocalizations.of(context).beforeSource(f.source),
          style: text.labelSmall?.copyWith(
            color: NomadColors.mint,
            letterSpacing: 0.6,
          ),
        ),
      ],
    );
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: () => setState(() => _back = !_back),
        // Gira 180° en el eje vertical. A mitad de giro se cambia la cara.
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _back ? math.pi : 0),
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeInOut,
          builder: (BuildContext context, double angle, Widget? _) {
            final bool showBack = angle > math.pi / 2;
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0015)
                ..rotateY(angle),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: showBack
                      ? NomadColors.surfaceHigh
                      : NomadColors.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: NomadColors.outline),
                ),
                // Las dos caras están siempre (una invisible): así la
                // tarjeta mide lo que la más alta y no salta al girar.
                child: Stack(
                  children: <Widget>[
                    Opacity(opacity: showBack ? 0 : 1, child: front),
                    Opacity(
                      opacity: showBack ? 1 : 0,
                      // La cara de atrás se da la vuelta para leerse bien.
                      child: Transform(
                        alignment: Alignment.center,
                        transform: Matrix4.identity()..rotateY(math.pi),
                        child: back,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Un consejo de Flyra: el texto, de dónde sale y a qué pantalla lleva.
class _Tip {
  const _Tip(this.text, this.source, this.route);

  final String text;
  final String source;
  final String route;
}

/// Los consejos, de uno en uno, con puntos y "Otro consejo →".
class _Tips extends StatefulWidget {
  const _Tips({required this.title, required this.tips});

  final String title;
  final List<_Tip> tips;

  @override
  State<_Tips> createState() => _TipsState();
}

class _TipsState extends State<_Tips> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<_Tip> tips = widget.tips;
    if (tips.isEmpty) return const SizedBox.shrink();
    final _Tip tip = tips[_i % tips.length];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NomadColors.group.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: NomadColors.group.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(widget.title, style: text.titleMedium),
          Text(
            t.beforeTipsSub,
            style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 10),
          InkWell(
            onTap: () => unawaited(context.push(tip.route)),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Column(
                key: ValueKey<int>(_i),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(tip.text, style: text.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                    t.beforeSource(tip.source),
                    style: text.labelSmall?.copyWith(color: NomadColors.group),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              for (int d = 0; d < tips.length; d++)
                Container(
                  width: d == _i % tips.length ? 16 : 6,
                  height: 6,
                  margin: const EdgeInsetsDirectional.only(end: 4),
                  decoration: BoxDecoration(
                    color: d == _i % tips.length
                        ? NomadColors.group
                        : NomadColors.outline,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              const Spacer(),
              TextButton(
                style: TextButton.styleFrom(minimumSize: const Size(0, 36)),
                onPressed: () => setState(() => _i++),
                child: Text(t.beforeTipNext),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// El botón de una tarjeta de abajo (o "✓ Listo" sin botón).
class _CardAction {
  const _CardAction(this.label, this.onTap);
  const _CardAction.done(this.label) : onTap = null;

  final String label;
  final VoidCallback? onTap;
}

/// Las tarjetas de "Datos móviles" y "Seguro médico".
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final _CardAction? action;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final _CardAction? action = this.action;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(icon, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: text.labelMedium?.copyWith(
                      color: color,
                      letterSpacing: 1.1,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(body),
            if (action != null) ...<Widget>[
              const SizedBox(height: 10),
              if (action.onTap == null)
                Text(
                  action.label,
                  style: const TextStyle(
                    color: NomadColors.mint,
                    fontWeight: FontWeight.w800,
                  ),
                )
              else
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
                  onPressed: action.onTap,
                  child: Text(action.label),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Reels de (país)": abre la búsqueda del país en cada app oficial.
class _Reels extends StatelessWidget {
  const _Reels({required this.country});

  final String country;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String q = Uri.encodeComponent(country);
    // Instagram busca por etiqueta: sin espacios ("Corea del Sur" →
    // "CoreadelSur").
    final String tag = Uri.encodeComponent(country.replaceAll(' ', ''));
    final List<(String, Color, Uri)> apps = <(String, Color, Uri)>[
      (
        'TikTok',
        NomadColors.text,
        Uri.parse('https://www.tiktok.com/search?q=$q'),
      ),
      (
        'Instagram',
        const Color(0xFFE1306C),
        Uri.parse('https://www.instagram.com/explore/tags/$tag/'),
      ),
      (
        'YouTube',
        const Color(0xFFFF4E45),
        Uri.parse('https://www.youtube.com/results?search_query=$q'),
      ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t.beforeReelsTitle(country), style: text.titleLarge),
        Text(
          t.beforeReelsSub(country),
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            for (final (String name, Color color, Uri url) in apps) ...<Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    foregroundColor: color,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  icon: const Icon(Icons.play_circle_rounded, size: 18),
                  label: Text(name, overflow: TextOverflow.ellipsis),
                  onPressed: () =>
                      unawaited(ServicesScope.of(context).openLink(url)),
                ),
              ),
              if (name != apps.last.$1) const SizedBox(width: 8),
            ],
          ],
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(title, style: Theme.of(context).textTheme.titleLarge),
  );
}

class _Iata extends StatelessWidget {
  const _Iata({
    required this.controller,
    required this.label,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    onChanged: onChanged,
    maxLength: 3,
    textAlign: TextAlign.center,
    textCapitalization: TextCapitalization.characters,
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.allow(RegExp('[a-zA-Z]')),
    ],
    style: Theme.of(context).textTheme.titleLarge,
    decoration: InputDecoration(
      labelText: label,
      hintText: 'MAD',
      counterText: '',
    ),
  );
}

/// La cabecera: a dónde vas, cuándo y cuánto llevas listo.
class _Header extends StatelessWidget {
  const _Header({required this.place, required this.day, required this.ready});

  /// "Japón · Tokyo".
  final String place;
  final DateTime day;
  final double ready;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final DateTime now = DateTime.now();
    final int days = DateTime(
      day.year,
      day.month,
      day.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays.clamp(0, 9999);
    return Row(
      children: <Widget>[
        SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              // El anillo se llena con animación, como en la maqueta.
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: ready),
                duration: const Duration(milliseconds: 800),
                curve: Curves.easeOutCubic,
                builder: (BuildContext context, double v, Widget? _) =>
                    CircularProgressIndicator(
                      value: v,
                      strokeWidth: 6,
                      backgroundColor: NomadColors.surfaceHigh,
                    ),
              ),
              Text('${(ready * 100).round()}%'),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                t.beforeSubtitle(place, days),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(
                t.beforeReady((ready * 100).round()),
                style: const TextStyle(color: NomadColors.mint),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Un apunte de la maleta, con su casilla.
class _PackTile extends StatelessWidget {
  const _PackTile({
    required this.item,
    required this.done,
    required this.onTap,
  });

  final PackItem item;
  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final (String title, String why) = textsFor(t, item);
    return Card(
      child: CheckboxListTile(
        value: done,
        onChanged: (_) => onTap(),
        title: Text(
          title,
          style: done
              ? const TextStyle(
                  decoration: TextDecoration.lineThrough,
                  color: NomadColors.textMuted,
                )
              : null,
        ),
        subtitle: Text(why),
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }
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
