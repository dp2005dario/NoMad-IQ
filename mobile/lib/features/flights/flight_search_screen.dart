// El BUSCADOR de vuelos: "de Madrid a Tokio, ida el 15 y vuelta el 22, para
// 2 personas". Arriba el formulario y debajo los resultados, del más barato
// al más caro, con el precio por persona y el total.
//
// Funciona también en modo invitado: buscar y reservar no necesitan cuenta.
// Solo "Avisar si baja" pide crear una (los avisos se guardan a tu nombre).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'fares_api.dart';
import 'flight_format.dart';
import 'watch_sheet.dart';

class FlightSearchScreen extends StatefulWidget {
  const FlightSearchScreen({
    super.key,
    this.origin,
    this.destination,
    this.departure,
    this.returnDate,
  });

  /// Con lo que empieza el formulario (p. ej. el aeropuerto de salida
  /// guardado en el cazador, o un enlace que ya trae el viaje).
  final String? origin;
  final String? destination;
  final DateTime? departure;
  final DateTime? returnDate;

  /// Máximo de viajeros (como en las aerolíneas; el servidor también lo exige).
  static const int maxAdults = 9;

  @override
  State<FlightSearchScreen> createState() => _FlightSearchScreenState();
}

class _FlightSearchScreenState extends State<FlightSearchScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final TextEditingController _from = TextEditingController(
    text: widget.origin ?? '',
  );
  late final TextEditingController _to = TextEditingController(
    text: widget.destination ?? '',
  );
  bool _roundTrip = true;
  late DateTime? _departure = widget.departure;
  late DateTime? _return = widget.returnDate;
  int _adults = 1;

  bool _searching = false;
  SearchResult? _result;
  ApiError? _error;

  /// Un aviso del propio formulario (falta un dato...), antes de preguntar.
  String? _formError;

  static final RegExp _iata = RegExp(r'^[A-Z]{3}$');

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  DateTime get _today {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  Future<void> _pickDate({required bool outbound}) async {
    final DateTime first = outbound ? _today : (_departure ?? _today);
    final DateTime? current = outbound ? _departure : _return;
    final DateTime? picked = await showDatePicker(
      context: context,
      useRootNavigator: true,
      firstDate: first,
      // Las aerolíneas venden como mucho un año antes.
      lastDate: _today.add(const Duration(days: 365)),
      initialDate: current != null && !current.isBefore(first)
          ? current
          : first,
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (outbound) {
        _departure = picked;
        // Si la vuelta quedaba antes de la nueva ida, se borra.
        if (_return != null && _return!.isBefore(picked)) _return = null;
      } else {
        _return = picked;
      }
      _formError = null;
    });
  }

  void _swap() {
    final String from = _from.text;
    setState(() {
      _from.text = _to.text;
      _to.text = from;
    });
  }

  Future<void> _search() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String from = _from.text.trim().toUpperCase();
    final String to = _to.text.trim().toUpperCase();
    String? problem;
    if (!_iata.hasMatch(from) || !_iata.hasMatch(to)) {
      problem = t.flightsOriginInvalid;
    } else if (from == to) {
      problem = t.searchSameAirport;
    } else if (_departure == null || (_roundTrip && _return == null)) {
      problem = t.searchMissingDates;
    }
    if (problem != null) {
      setState(() => _formError = problem);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _formError = null;
      _searching = true;
      _error = null;
    });
    try {
      final SearchResult result = await _services.fares.search(
        origin: from,
        destination: to,
        departure: _departure!,
        returnDate: _roundTrip ? _return : null,
        adults: _adults,
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _searching = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.error;
        _result = null;
        _searching = false;
      });
    }
  }

  Future<void> _book(Uri url) async {
    final bool opened = await _services.openBooking(url);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).flightsBookFailed)),
      );
    }
  }

  Future<void> _watch(SearchResult result, Offer offer) async {
    // Vigilar necesita cuenta: el invitado va a crearla.
    if (_services.api.session.status != SessionStatus.signedIn) {
      await context.push(Routes.signIn);
      return;
    }
    await showWatchSheet(
      context,
      route: result.route,
      currency: offer.pricePerAdult.currency,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.searchTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          SegmentedButton<bool>(
            segments: <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: true, label: Text(t.searchRoundTrip)),
              ButtonSegment<bool>(value: false, label: Text(t.flightsOneWay)),
            ],
            selected: <bool>{_roundTrip},
            onSelectionChanged: (Set<bool> v) =>
                setState(() => _roundTrip = v.first),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: _AirportField(controller: _from, label: t.searchFrom),
              ),
              IconButton(
                tooltip: t.searchSwap,
                onPressed: _swap,
                icon: const Icon(Icons.swap_horiz_rounded),
              ),
              Expanded(
                child: _AirportField(controller: _to, label: t.searchTo),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: _DateButton(
                  label: t.searchDeparture,
                  day: _departure,
                  onTap: () => _pickDate(outbound: true),
                ),
              ),
              if (_roundTrip) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(
                  child: _DateButton(
                    label: t.searchReturn,
                    day: _return,
                    onTap: () => _pickDate(outbound: false),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              const Icon(
                Icons.people_alt_rounded,
                color: NomadColors.textMuted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(t.searchAdults(_adults), style: text.titleMedium),
              ),
              IconButton.outlined(
                tooltip: t.searchRemoveTraveler,
                onPressed: _adults > 1 ? () => setState(() => _adults--) : null,
                icon: const Icon(Icons.remove_rounded),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: t.searchAddTraveler,
                onPressed: _adults < FlightSearchScreen.maxAdults
                    ? () => setState(() => _adults++)
                    : null,
                icon: const Icon(Icons.add_rounded),
              ),
            ],
          ),
          if (_formError != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _formError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _searching ? null : _search,
            icon: const Icon(Icons.search_rounded),
            label: Text(t.searchGo),
          ),
          const SizedBox(height: 24),
          ..._results(context, t),
        ],
      ),
    );
  }

  List<Widget> _results(BuildContext context, AppLocalizations t) {
    final TextStyle muted = const TextStyle(color: NomadColors.textMuted);
    if (_searching) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final ApiError? error = _error;
    if (error != null) {
      return <Widget>[
        Text(switch (error) {
          ApiError.rateLimited => t.searchBusy,
          ApiError.network => t.errorNetwork,
          ApiError.invalidInput => t.searchMissingDates,
          _ => t.errorUnavailable,
        }, style: muted),
      ];
    }
    final SearchResult? result = _result;
    if (result == null) return const <Widget>[];
    if (result.offers.isEmpty) {
      return <Widget>[Text(t.searchNoResults, style: muted)];
    }
    return <Widget>[
      Text(
        t.searchResults(result.offers.length),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      const SizedBox(height: 4),
      Text(t.searchPricesNote, style: muted),
      const SizedBox(height: 12),
      for (final Offer o in result.offers)
        _OfferCard(
          offer: o,
          adults: result.adults,
          onBook: () => _book(o.bookingUrl),
          onWatch: () => _watch(result, o),
        ),
    ];
  }
}

class _AirportField extends StatelessWidget {
  const _AirportField({required this.controller, required this.label});

  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    maxLength: 3,
    textCapitalization: TextCapitalization.characters,
    textAlign: TextAlign.center,
    style: Theme.of(context).textTheme.titleLarge,
    decoration: InputDecoration(
      labelText: label,
      hintText: 'MAD',
      counterText: '',
    ),
  );
}

class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.label,
    required this.day,
    required this.onTap,
  });

  final String label;
  final DateTime? day;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.event_rounded),
      label: Text(
        day == null
            ? '$label · ${t.searchPickDate}'
            : '$label · ${dayText(context, day!)}',
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Una oferta: precio por persona grande, total, horarios y escalas.
class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.offer,
    required this.adults,
    required this.onBook,
    required this.onWatch,
  });

  final Offer offer;
  final int adults;
  final VoidCallback onBook;
  final VoidCallback onWatch;

  String _leg(BuildContext context, AppLocalizations t, String at, int stops) {
    final DateTime? day = DateTime.tryParse(at.substring(0, 10));
    final String when = day == null
        ? at.substring(11, 16)
        : '${dayText(context, day)} · ${at.substring(11, 16)}';
    return '$when · ${stops == 0 ? t.searchDirect : t.searchStops(stops)}';
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final TextStyle muted = const TextStyle(color: NomadColors.textMuted);
    final int hours = offer.durationMinutes ~/ 60;
    final int minutes = offer.durationMinutes % 60;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        t.searchPerPerson(
                          priceText(context, offer.pricePerAdult),
                        ),
                        style: text.titleLarge?.copyWith(
                          color: NomadColors.flights,
                        ),
                      ),
                      if (adults > 1)
                        Text(
                          t.searchTotal(
                            t.searchAdults(adults),
                            priceText(context, offer.total),
                          ),
                          style: muted,
                        ),
                    ],
                  ),
                ),
                if (offer.carrier.isNotEmpty)
                  Chip(
                    label: Text(offer.carrier),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '${t.searchDeparture}: '
              '${_leg(context, t, offer.departureAt, offer.transfers)}',
            ),
            if (offer.returnAt != null)
              Text(
                '${t.searchReturn}: '
                '${_leg(context, t, offer.returnAt!, offer.returnTransfers)}',
              ),
            if (offer.durationMinutes > 0)
              Text(t.searchDuration(hours, minutes), style: muted),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: onBook,
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(t.flightsBook),
                ),
                OutlinedButton.icon(
                  onPressed: onWatch,
                  icon: const Icon(Icons.notifications_active_rounded),
                  label: Text(t.flightsNotify),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
