// Escala de regalo: eliges de dónde a dónde vuelas y la app te dice en qué
// ciudades puedes parar unos días "de regalo" por el camino, con qué
// aerolínea y qué condiciones. El precio sale del buscador de Vuelos (el
// mismo de siempre, con su caché y sus límites), y el vuelo con parada se
// reserva en la página de la aerolínea.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/fares_api.dart';
import '../flights/flight_format.dart';
import '../route/city_sheet.dart';
import '../route/world_data.dart';
import 'stopover.dart';

String stopRuleText(AppLocalizations t, StopoverRule r) => switch (r) {
  StopoverRule.sameFare => t.stopRuleSameFare,
  StopoverRule.freeHotel => t.stopRuleFreeHotel,
  StopoverRule.hotelDeal => t.stopRuleHotelDeal,
  StopoverRule.checkFare => t.stopRuleCheckFare,
};

final RegExp _iata = RegExp(r'^[A-Z]{3}$');

class StopoverScreen extends StatefulWidget {
  const StopoverScreen({super.key, this.from, this.to});

  final String? from;
  final String? to;

  @override
  State<StopoverScreen> createState() => _StopoverScreenState();
}

class _StopoverScreenState extends State<StopoverScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final TextEditingController _from = TextEditingController(
    text: widget.from ?? '',
  );
  late final TextEditingController _to = TextEditingController(
    text: widget.to ?? '',
  );
  DateTime _date = DateTime.now().add(const Duration(days: 30));
  Airports? _airports;
  List<StopoverOption>? _options;
  bool _unknown = false;
  int _pick = 0;
  int _nights = 2;

  // El precio (solo al tocar "Ver precio": así no se gasta el buscador).
  bool _searching = false;
  SearchResult? _result;
  ApiError? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_find()));
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _find() async {
    final String from = _from.text.trim().toUpperCase();
    final String to = _to.text.trim().toUpperCase();
    if (!_iata.hasMatch(from) || !_iata.hasMatch(to)) return;
    final Airports airports = _airports ??= await _services.loadAirports();
    final Airport? a = airports[from];
    final Airport? b = airports[to];
    if (!mounted) return;
    setState(() {
      _unknown = a == null || b == null;
      _options = a == null || b == null ? null : stopoversFor(a, b, airports);
      _pick = 0;
      _result = null;
      _error = null;
      final List<StopoverOption>? o = _options;
      if (o != null && o.isNotEmpty) {
        _nights = _nights.clamp(0, nightChoices(o.first.program).last);
      }
    });
  }

  Future<void> _price() async {
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final SearchResult r = await _services.fares.search(
        origin: _from.text.trim().toUpperCase(),
        destination: _to.text.trim().toUpperCase(),
        departure: _date,
      );
      if (mounted) setState(() => _result = r);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    final DateTime? d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: now,
      lastDate: now.add(const Duration(days: 330)),
    );
    if (d == null) return;
    setState(() {
      _date = d;
      _result = null;
    });
  }

  void _openCity(Airport hub) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (BuildContext sheet) => CitySheet(
          iata: hub.iata,
          load: _services.places.get,
          openLink: _services.openBooking,
        ),
      ),
    );
  }

  /// La oferta más barata y la más barata de esa aerolínea con escala.
  (Offer?, Offer?) _offers(StopoverProgram p) {
    final List<Offer> all = _result?.offers ?? const <Offer>[];
    Offer? cheapest;
    Offer? airline;
    for (final Offer o in all) {
      if (cheapest == null ||
          o.pricePerAdult.amountMinor < cheapest.pricePerAdult.amountMinor) {
        cheapest = o;
      }
      if (o.carrier == p.airline &&
          o.transfers > 0 &&
          (airline == null ||
              o.pricePerAdult.amountMinor <
                  airline.pricePerAdult.amountMinor)) {
        airline = o;
      }
    }
    return (cheapest, airline);
  }

  Future<void> _book(StopoverOption o, Offer? best) async {
    if (_nights > 0) {
      await _services.openLink(Uri.parse(o.program.url));
      return;
    }
    if (best != null) {
      await _services.openBooking(best.bookingUrl);
    } else {
      await _price();
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final List<StopoverOption>? options = _options;
    final StopoverOption? o = options == null || options.isEmpty
        ? null
        : options[_pick.clamp(0, options.length - 1)];
    return Scaffold(
      appBar: AppBar(title: Text(t.stopTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: <Widget>[
          Text(t.stopTagline, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(t.stopHow, style: const TextStyle(color: NomadColors.textMuted)),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: _CodeField(controller: _from, label: t.stopFrom),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CodeField(controller: _to, label: t.stopTo),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => unawaited(_find()),
            icon: const Icon(Icons.connecting_airports_rounded),
            label: Text(t.stopFind),
          ),
          const SizedBox(height: 16),
          if (_unknown)
            Text(t.stopUnknown)
          else if (options != null && options.isEmpty)
            Text(t.stopNone)
          else if (o != null) ...<Widget>[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (int i = 0; i < options!.length; i++)
                  ChoiceChip(
                    selected: i == _pick,
                    label: Text(options[i].hub.city),
                    onSelected: (_) => setState(() {
                      _pick = i;
                      _nights = _nights.clamp(
                        0,
                        nightChoices(options[i].program).last,
                      );
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _RouteLine(
              from: _from.text.trim().toUpperCase(),
              hub: o.hub.iata,
              to: _to.text.trim().toUpperCase(),
              label: _nights == 0
                  ? t.stopNights(0)
                  : '${o.hub.city} · ${t.stopNights(_nights)}',
            ),
            Text(
              t.stopDetour(o.extraKm),
              textAlign: TextAlign.center,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 16),
            Text(
              t.stopNightsTitle,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: <ButtonSegment<int>>[
                for (final int n in nightChoices(o.program))
                  ButtonSegment<int>(
                    value: n,
                    label: Text(n == 0 ? t.stopNoNights : '$n'),
                  ),
              ],
              selected: <int>{_nights},
              onSelectionChanged: (Set<int> s) =>
                  setState(() => _nights = s.first),
            ),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      o.program.airlineName,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (o.program.maxNights case final int n)
                      Text(
                        t.stopMaxNights(n),
                        style: const TextStyle(color: NomadColors.money),
                      ),
                    const SizedBox(height: 8),
                    Text(stopRuleText(t, o.program.rule)),
                    const SizedBox(height: 12),
                    ActionChip(
                      avatar: const Icon(Icons.event_rounded, size: 18),
                      label: Text(
                        t.stopDate(DateFormat.yMMMd(locale).format(_date)),
                      ),
                      onPressed: () => unawaited(_pickDate()),
                    ),
                    const SizedBox(height: 8),
                    ..._priceLines(t, o),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _openCity(o.hub),
              icon: const Icon(Icons.travel_explore_rounded),
              label: Text(t.placeAbout(o.hub.city)),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => unawaited(_book(o, _offers(o.program).$1)),
              child: Text(
                _nights == 0
                    ? t.stopBookDirect
                    : t.stopBookWith(t.stopNights(_nights), o.hub.city),
              ),
            ),
            if (_nights > 0) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                t.stopBookHint,
                style: const TextStyle(color: NomadColors.textMuted),
              ),
            ],
            const SizedBox(height: 12),
            Text(t.stopCheck, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }

  List<Widget> _priceLines(AppLocalizations t, StopoverOption o) {
    if (_searching) {
      return const <Widget>[LinearProgressIndicator()];
    }
    final ApiError? error = _error;
    if (error != null) {
      return <Widget>[
        Text(
          error == ApiError.rateLimited
              ? t.stopBusy
              : error == ApiError.network
              ? t.errorNetwork
              : t.errorUnavailable,
        ),
      ];
    }
    if (_result == null) {
      return <Widget>[
        OutlinedButton(
          onPressed: () => unawaited(_price()),
          child: Text(t.stopSeePrice),
        ),
      ];
    }
    final (Offer? cheapest, Offer? airline) = _offers(o.program);
    final String nights = t.stopNights(_nights);
    return <Widget>[
      if (cheapest != null)
        Text(t.stopCheapest(priceText(context, cheapest.pricePerAdult))),
      if (airline != null)
        Text(
          t.stopWithAirline(
            o.program.airlineName,
            priceText(context, airline.pricePerAdult),
          ),
          style: const TextStyle(fontWeight: FontWeight.w800),
        )
      else
        Text(t.stopNoAirline(o.program.airlineName)),
      if (_nights > 0)
        Text(
          // "Mismo precio" solo donde la aerolínea lo dice en su web.
          o.program.rule == StopoverRule.sameFare
              ? t.stopSamePrice(nights, o.hub.city)
              : t.stopCheckNote(nights, o.hub.city),
          style: const TextStyle(color: NomadColors.mint),
        ),
    ];
  }
}

class _CodeField extends StatelessWidget {
  const _CodeField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return TextField(
      controller: controller,
      maxLength: 3,
      textCapitalization: TextCapitalization.characters,
      decoration: InputDecoration(
        labelText: label,
        helperText: t.stopCodeHint,
        counterText: '',
      ),
    );
  }
}

/// "MAD ─ IST ─ HND" con la parada en ámbar (como el arco de la maqueta).
class _RouteLine extends StatelessWidget {
  const _RouteLine({
    required this.from,
    required this.hub,
    required this.to,
    required this.label,
  });

  final String from;
  final String hub;
  final String to;
  final String label;

  @override
  Widget build(BuildContext context) {
    Widget code(String c, {Color color = NomadColors.text}) => Text(
      c,
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: color),
    );
    const Widget line = Expanded(
      child: Divider(
        thickness: 2,
        color: NomadColors.outline,
        indent: 6,
        endIndent: 6,
      ),
    );
    return Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            code(from),
            line,
            code(hub, color: NomadColors.money),
            line,
            code(to),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: NomadColors.money,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: Color(0xFF1A1206),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}
