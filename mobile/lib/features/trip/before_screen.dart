// Antes de salir (maqueta "Antes"): una sola pantalla con todo lo que hay
// que tener resuelto antes de un viaje.
//
// Qué lleva, y de dónde sale cada cosa:
//   - Datos móviles allí: tabla fija de países con "roaming como en casa".
//   - Papeles: la Bóveda de este móvil (pasaporte y seguro).
//   - Huella del vuelo: se calcula aquí con la distancia y factores públicos.
//   - Para la maleta: el enchufe del país y el clima medio del mes (NASA).
// Lo que marcas se guarda SOLO en el móvil.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/climate_api.dart';
import '../papers/trip_check.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/geo.dart';
import '../route/world_data.dart';
import 'before_trip.dart';
import 'co2.dart';
import 'plugs.dart';

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

  Future<void> _toggle(PackItem item) async {
    final bool ready = !_done.contains(item.id);
    await _packing.setDone(item.id, ready: ready);
    if (mounted) setState(() => _done = _packing.done());
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Airport? to = _destination;
    final DateTime? day = _day;
    final bool ready = to != null && day != null;
    final List<PackItem> items = _items;
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
            _Header(city: to.city, day: day, ready: readiness(items, _done)),
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
          if (ready && !_working) ...<Widget>[
            const SizedBox(height: 24),
            _Section(t.beforeDataTitle),
            Text(switch (roamingFor(
              homeCountry: _homeCountry,
              destination: _thereCountry,
            )) {
              RoamingStatus.free => t.beforeRoamingFree,
              RoamingStatus.abroad => t.beforeRoamingAbroad,
              RoamingStatus.unknown => t.beforeFillTrip,
            }),
            const SizedBox(height: 24),
            _Section(t.beforeCo2Title),
            _Carbon(from: _origin, to: to),
            const SizedBox(height: 24),
            _Section(t.beforePackTitle),
            for (final PackItem item in items)
              _PackTile(
                item: item,
                done: _done.contains(item.id),
                onTap: () => unawaited(_toggle(item)),
              ),
          ],
        ],
      ),
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
  const _Header({required this.city, required this.day, required this.ready});

  final String city;
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
              CircularProgressIndicator(
                value: ready,
                strokeWidth: 6,
                backgroundColor: NomadColors.surfaceHigh,
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
                t.beforeSubtitle(city, days),
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

/// Las barras del CO₂: tu vuelo, con escala y un coche en un año.
class _Carbon extends StatelessWidget {
  const _Carbon({required this.from, required this.to});

  final Airport? from;
  final Airport to;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Airport? origin = from;
    if (origin == null) {
      return Text(
        t.beforeFillTrip,
        style: const TextStyle(color: NomadColors.textMuted),
      );
    }
    final LatLon a = origin.position;
    final LatLon b = to.position;
    final double direct = flightKgCo2(a, b);
    final double stop = flightKgCo2(a, b, stops: 1);
    final double most = <double>[
      direct,
      stop,
      carYearKgCo2,
    ].reduce((double x, double y) => x > y ? x : y);
    final NumberFormat kg = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toLanguageTag(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final (String label, double value, bool mine)
            in <(String, double, bool)>[
              (t.beforeCo2Direct, direct, true),
              (t.beforeCo2Stop, stop, false),
              (t.beforeCo2Car, carYearKgCo2, false),
            ]) ...<Widget>[
          Text(
            '$label · ${kg.format(value.round())} kg CO₂',
            style: TextStyle(
              color: mine ? NomadColors.mint : NomadColors.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          // La barra más larga ocupa todo el ancho: se comparan de un vistazo.
          FractionallySizedBox(
            alignment: AlignmentDirectional.centerStart,
            widthFactor: most == 0 ? 0 : (value / most).clamp(0.02, 1),
            child: Container(
              height: 10,
              decoration: BoxDecoration(
                color: mine ? NomadColors.mint : NomadColors.outline,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        Text(t.beforeCo2Trees(treesForAYear(direct)), style: text.bodyMedium),
        const SizedBox(height: 4),
        Text(
          t.beforeCo2Estimate,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
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
