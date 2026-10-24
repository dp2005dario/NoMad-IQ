// Explorar (maqueta "Explorar"): "¿a dónde vuelo barato y con buen tiempo?".
// Se eligen dos aeropuertos y sale el precio de ida y vuelta de cada mes del
// próximo año (lo que encontraron otros viajeros) junto al clima medio de ese
// mes (medias de 30 años de la NASA). Al tocar un mes, el veredicto y el
// botón para buscar vuelos de esos días.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../route/world_data.dart';
import 'climate_api.dart';
import 'fares_api.dart';
import 'flight_format.dart';

/// Cuándo un mes es "buen tiempo": ni frío ni bochorno, y poca lluvia.
bool niceWeather(MonthClimate c) =>
    c.tempC >= 12 && c.tempMaxC <= 32 && c.rainyDays <= 10;

/// El mes más barato de la lista (null si está vacía).
MonthFare? cheapestMonth(List<MonthFare> months) {
  MonthFare? best;
  for (final MonthFare m in months) {
    if (best == null ||
        m.pricePerAdult.amountMinor < best.pricePerAdult.amountMinor) {
      best = m;
    }
  }
  return best;
}

/// El nombre del mes en el idioma de la app ("marzo").
String monthName(BuildContext context, int month) =>
    DateFormat.MMMM(Localizations.localeOf(context).toLanguageTag())
        .format(DateTime(2026, month));

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key, this.origin = ''});

  /// Aeropuerto de salida que trae la pantalla de Vuelos ("MAD").
  final String origin;

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final TextEditingController _from = TextEditingController(
    text: widget.origin,
  );
  final TextEditingController _to = TextEditingController();

  Airports? _airports;
  List<MonthFare>? _months;
  Map<int, MonthClimate> _climate = <int, MonthClimate>{};
  int? _picked;
  bool _loading = false;
  ApiError? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAirports());
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _loadAirports() async {
    try {
      final WorldData world = await WorldData.load();
      if (mounted) setState(() => _airports = world.airports);
    } on Object {
      // Sin los aeropuertos no sabemos dónde está el destino: se enseñan
      // los precios y se deja el clima fuera.
    }
  }

  String get _origin => _from.text.trim().toUpperCase();
  String get _destination => _to.text.trim().toUpperCase();

  Future<void> _load() async {
    final String from = _origin;
    final String to = _destination;
    if (from.length != 3 || to.length != 3 || from == to) return;
    setState(() {
      _loading = true;
      _error = null;
      _months = null;
      _climate = <int, MonthClimate>{};
      _picked = null;
    });
    try {
      final List<MonthFare> months = await _services.fares.months(
        origin: from,
        destination: to,
      );
      if (!mounted) return;
      setState(() {
        _months = months;
        _picked = cheapestMonth(months)?.month;
        _loading = false;
      });
      await _loadClimate(to);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.error;
        });
      }
    }
  }

  /// El clima del destino. Si falla, la pantalla sigue con los precios.
  Future<void> _loadClimate(String iata) async {
    final Airport? airport = _airports?[iata];
    if (airport == null) return;
    try {
      final List<MonthClimate> months = await _services.climate.at(
        airport.position.lat,
        airport.position.lon,
      );
      if (!mounted) return;
      setState(
        () => _climate = <int, MonthClimate>{
          for (final MonthClimate c in months) c.month: c,
        },
      );
    } on ApiException {
      // El clima es un extra: sin él se siguen viendo los precios.
    }
  }

  String _cityOf(String iata) => _airports?[iata]?.city ?? iata;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<MonthFare>? months = _months;
    return Scaffold(
      appBar: AppBar(title: Text(t.exploreTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Text(
            t.exploreSubtitle,
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: _Iata(controller: _from, label: t.searchFrom),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.flight_takeoff_rounded),
              ),
              Expanded(
                child: _Iata(controller: _to, label: t.searchTo),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.travel_explore_rounded),
            label: Text(t.exploreSearch),
          ),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(switch (_error!) {
                ApiError.rateLimited => t.searchBusy,
                ApiError.network => t.errorNetwork,
                _ => t.errorUnavailable,
              }, style: const TextStyle(color: NomadColors.safety)),
            ),
          if (months != null && months.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(t.exploreNoPrices),
            ),
          if (months != null && months.isNotEmpty) ...<Widget>[
            const SizedBox(height: 24),
            _MonthBars(
              months: months,
              picked: _picked,
              onPick: (int month) => setState(() => _picked = month),
            ),
            const SizedBox(height: 20),
            _Picked(
              month: months.firstWhere(
                (MonthFare m) => m.month == _picked,
                orElse: () => months.first,
              ),
              climate: _climate[_picked],
              city: _cityOf(_destination),
              onSearch: _searchPicked,
            ),
            const SizedBox(height: 20),
            Text(
              t.exploreWeatherSource,
              style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
            ),
          ],
        ],
      ),
    );
  }

  /// Abre el buscador con los días de ese mes (los que dio el proveedor).
  void _searchPicked() {
    final MonthFare? month = _months?.firstWhere(
      (MonthFare m) => m.month == _picked,
      orElse: () => _months!.first,
    );
    if (month == null) return;
    final DateTime? departure = DateTime.tryParse(month.departureAt);
    if (departure == null) return;
    final DateTime? ret = month.returnAt == null
        ? null
        : DateTime.tryParse(month.returnAt!);
    unawaited(
      context.push(
        Routes.fareSearch(
          origin: _origin,
          destination: _destination,
          departure: isoDay(departure),
          returnDate: ret == null ? null : isoDay(ret),
        ),
      ),
    );
  }
}

/// Un aeropuerto en código IATA ("MAD").
class _Iata extends StatelessWidget {
  const _Iata({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
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

/// Las barras de precio por meses: la más baja en verde, la más alta en rojo.
class _MonthBars extends StatelessWidget {
  const _MonthBars({
    required this.months,
    required this.picked,
    required this.onPick,
  });

  final List<MonthFare> months;
  final int? picked;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final int low = months
        .map((MonthFare m) => m.pricePerAdult.amountMinor)
        .reduce((int a, int b) => a < b ? a : b);
    final int high = months
        .map((MonthFare m) => m.pricePerAdult.amountMinor)
        .reduce((int a, int b) => a > b ? a : b);
    final MonthFare best = cheapestMonth(months)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(t.exploreMonthlyPrices, style: text.titleMedium),
        const SizedBox(height: 4),
        // Wrap y no Row: con letra grande o un idioma largo, la leyenda
        // baja a la línea siguiente en vez de salirse de la pantalla.
        Wrap(
          spacing: 12,
          children: <Widget>[
            Text(
              t.exploreCheapest(monthName(context, best.month)),
              style: const TextStyle(color: NomadColors.mint),
            ),
            Text(
              '${t.exploreCheap} → ${t.exploreDear}',
              style: const TextStyle(
                color: NomadColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Scroll horizontal: con 12 meses y letra grande no caben de golpe.
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              for (final MonthFare m in months)
                _Bar(
                  month: m,
                  // La altura es relativa: el más barato un 35 % y el más
                  // caro el 100 %, para que la diferencia se vea.
                  fraction: high == low
                      ? 1
                      : 0.35 +
                            0.65 *
                                (m.pricePerAdult.amountMinor - low) /
                                (high - low),
                  cheapest: m.month == best.month,
                  selected: m.month == picked,
                  onTap: () => onPick(m.month),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({
    required this.month,
    required this.fraction,
    required this.cheapest,
    required this.selected,
    required this.onTap,
  });

  final MonthFare month;
  final double fraction;
  final bool cheapest;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = cheapest ? NomadColors.mint : NomadColors.flights;
    final String name = monthName(context, month.month);
    return Semantics(
      button: true,
      selected: selected,
      label: '$name ${priceText(context, month.pricePerAdult)}',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              Text(
                priceText(context, month.pricePerAdult),
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? color : NomadColors.textMuted,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: 34,
                height: 120 * fraction,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: selected ? 1 : 0.45),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(6),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // Las tres primeras letras del mes ("mar").
              Text(
                name.length > 3 ? name.substring(0, 3) : name,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// El mes elegido: clima, veredicto y el botón para buscar vuelos.
class _Picked extends StatelessWidget {
  const _Picked({
    required this.month,
    required this.climate,
    required this.city,
    required this.onSearch,
  });

  final MonthFare month;
  final MonthClimate? climate;
  final String city;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final MonthClimate? c = climate;
    final String name = monthName(context, month.month);
    final String verdict = c == null
        ? t.exploreVerdictNoClimate(name)
        : niceWeather(c)
        ? t.exploreVerdictGreat(name)
        : t.exploreVerdictCheapRain(name);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(name, style: text.titleLarge),
            Text(
              priceText(context, month.pricePerAdult),
              style: text.headlineMedium?.copyWith(color: NomadColors.mint),
            ),
            if (c != null) ...<Widget>[
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(
                    child: _Stat(
                      label: t.exploreTemperature,
                      value: '${c.tempC.round()}° / ${c.tempMaxC.round()}°',
                    ),
                  ),
                  Expanded(
                    child: _Stat(
                      label: t.exploreRainDays,
                      value: t.exploreDaysValue(c.rainyDays),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(
              t.exploreVerdict,
              style: const TextStyle(
                color: NomadColors.textMuted,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(verdict, style: text.bodyLarge),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onSearch,
              icon: const Icon(Icons.flight_rounded),
              label: Text(t.exploreSeeFlights(city)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        label,
        style: const TextStyle(
          color: NomadColors.textMuted,
          fontSize: 11,
          letterSpacing: 1.2,
        ),
      ),
      Text(value, style: Theme.of(context).textTheme.titleMedium),
    ],
  );
}
