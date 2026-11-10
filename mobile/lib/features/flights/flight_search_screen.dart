// El BUSCADOR de vuelos: "de Madrid a Tokio, ida el 15 y vuelta el 22, para
// 2 personas". Arriba el formulario y debajo los resultados, del más barato
// al más caro, con el precio por persona y el total.
//
// Se ve como el buscador de la maqueta de Vuelos (el panel azul con brillo,
// los campos ORIGEN y DESTINO, el botón azul-menta). Y además:
//   - se escribe la CIUDAD ("Tokio"), no el código raro ("NRT"): debajo
//     salen sugerencias y al lado se ve el código que se usará;
//   - debajo, el precio más barato de cada día cerca de tu fecha. Si tu día
//     exacto no tiene precio, esos días cercanos son la respuesta: tocas uno
//     y se busca ese día.
//
// Funciona también en modo invitado: buscar y reservar no necesitan cuenta.
// Solo "Avisar si baja" pide crear una (los avisos se guardan a tu nombre).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'airport_names.dart';
import 'fares_api.dart';
import 'flight_format.dart';
import 'watch_sheet.dart';

/// Los colores del buscador de la maqueta (azul noche con toques menta).
abstract final class _C {
  static const Color panelTop = Color(0xFF16253F);
  static const Color panelBottom = Color(0xFF101B2D);
  static const Color line = Color(0xFF2A3E63);
  static const Color field = Color(0xFF0E1828);
  static const Color sugs = Color(0xFF0C1522);
  static const Color chip = Color(0xFF13213A);
  static const Color accent = Color(0xFF9CC4FF);
  static const Color label = Color(0xFF9FB0B8);
  static const Color ink = Color(0xFFF2F5F3);
  static const Color hint = Color(0xFF6F8490);
}

class FlightSearchScreen extends StatefulWidget {
  const FlightSearchScreen({
    super.key,
    this.origin,
    this.destination,
    this.departure,
    this.returnDate,
    this.adults,
    this.autoSearch = false,
  });

  /// Con lo que empieza el formulario (p. ej. el aeropuerto de salida
  /// guardado en el cazador, o un enlace que ya trae el viaje).
  final String? origin;
  final String? destination;
  final DateTime? departure;
  final DateTime? returnDate;

  /// Cuántos viajeros (los niños de Vuelos cuentan como uno más).
  final int? adults;

  /// Buscar nada más abrir (cuando ya llega todo desde el buscador de Vuelos).
  final bool autoSearch;

  /// Máximo de viajeros (como en las aerolíneas; el servidor también lo exige).
  static const int maxAdults = 9;

  @override
  State<FlightSearchScreen> createState() => _FlightSearchScreenState();
}

/// Un campo de aeropuerto: lo escrito y, si se tocó una sugerencia, cuál.
class _Place {
  _Place(String? iata)
    : text = TextEditingController(text: iata ?? ''),
      picked = iata != null && _iata.hasMatch(iata) ? iata : null;

  final TextEditingController text;
  final FocusNode focus = FocusNode();

  /// El aeropuerto elegido de la lista (null si solo hay texto escrito).
  String? picked;

  static final RegExp _iata = RegExp(r'^[A-Z]{3}$');

  /// El código que se usará: el elegido o, si no, el que mejor encaja con
  /// lo escrito ("tokio" → NRT, "mad" → MAD).
  String? code(AirportNames? names) {
    final String? p = picked;
    if (p != null) return p;
    final String raw = text.text.trim();
    if (raw.isEmpty) return null;
    final String upper = raw.toUpperCase();
    if (names == null || names.all.isEmpty) {
      return _iata.hasMatch(upper) ? upper : null;
    }
    if (raw.length == 3 && names[upper] != null) return upper;
    final List<AirportName> hits = names.search(raw, limit: 1);
    if (hits.isNotEmpty) return hits.first.iata;
    return _iata.hasMatch(upper) ? upper : null;
  }

  void dispose() {
    text.dispose();
    focus.dispose();
  }
}

class _FlightSearchScreenState extends State<FlightSearchScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final _Place _from = _Place(widget.origin?.toUpperCase());
  late final _Place _to = _Place(widget.destination?.toUpperCase());
  // Solo ida si llega la ida sin vuelta.
  late bool _roundTrip = widget.departure == null || widget.returnDate != null;
  late DateTime? _departure = widget.departure;
  late DateTime? _return = widget.returnDate;
  late int _adults = (widget.adults ?? 1).clamp(
    1,
    FlightSearchScreen.maxAdults,
  );
  bool _autoDone = false;
  AirportNames? _names;

  bool _searching = false;
  SearchResult? _result;
  ApiError? _error;

  /// Un aviso del propio formulario (falta un dato...), antes de preguntar.
  String? _formError;

  /// El más barato de cada día cerca de la fecha buscada (puede ir vacío).
  List<DayFare> _days = const <DayFare>[];

  @override
  void initState() {
    super.initState();
    for (final _Place p in <_Place>[_from, _to]) {
      p.text.addListener(() => _edited(p));
      p.focus.addListener(() => setState(() {}));
    }
    unawaited(_loadNames());
  }

  Future<void> _loadNames() async {
    try {
      final AirportNames names = await AirportNames.load();
      if (!mounted) return;
      setState(() {
        _names = names;
        // Lo que llegó como código se enseña con su nombre ("Madrid").
        for (final _Place p in <_Place>[_from, _to]) {
          final AirportName? a = p.picked == null ? null : names[p.picked!];
          if (a != null && p.text.text == a.iata) p.text.text = a.city;
        }
      });
    } on Object {
      // Sin la lista: se puede seguir escribiendo el código (MAD).
    }
  }

  /// Al escribir, lo elegido antes deja de valer (salvo que siga igual).
  void _edited(_Place p) {
    final String? picked = p.picked;
    if (picked == null) {
      setState(() {});
      return;
    }
    final AirportName? a = _names?[picked];
    final String now = p.text.text;
    if (now != picked && now != a?.city) {
      setState(() => p.picked = null);
    }
  }

  void _choose(_Place p, AirportName a) {
    setState(() {
      p.picked = a.iata;
      p.text.text = a.city;
      p.text.selection = TextSelection.collapsed(offset: a.city.length);
      _formError = null;
    });
    // Del origen se salta al destino; del destino se cierra el teclado.
    if (identical(p, _from) && _to.picked == null) {
      _to.focus.requestFocus();
    } else {
      FocusScope.of(context).unfocus();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.autoSearch && !_autoDone) {
      _autoDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_search());
      });
    }
  }

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
    final String text = _from.text.text;
    final String? picked = _from.picked;
    setState(() {
      _from.text.text = _to.text.text;
      _from.picked = _to.picked;
      _to.text.text = text;
      _to.picked = picked;
    });
  }

  Future<void> _search() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? from = _from.code(_names);
    final String? to = _to.code(_names);
    String? problem;
    if (from == null || to == null) {
      problem = t.searchPlaceMissing;
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
      _days = const <DayFare>[];
    });
    final DateTime departure = _departure!;
    // Los días cercanos se piden a la vez (no hacen esperar al resultado).
    unawaited(_loadDays(from!, to!, departure));
    try {
      final SearchResult result = await _services.fares.search(
        origin: from,
        destination: to,
        departure: departure,
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

  /// El más barato de cada día cerca de [around] (su mes y, si cae al
  /// principio o al final, el de al lado). Los 9 días más cercanos.
  Future<void> _loadDays(String from, String to, DateTime around) async {
    final DateTime today = _today;
    final List<DateTime> months = <DateTime>[
      DateTime(around.year, around.month),
      if (around.day >= 22) DateTime(around.year, around.month + 1),
      if (around.day <= 8 &&
          !DateTime(
            around.year,
            around.month,
          ).isBefore(DateTime(today.year, today.month + 1)))
        DateTime(around.year, around.month - 1),
    ];
    final List<DayFare> all = <DayFare>[];
    for (final DateTime m in months) {
      try {
        all.addAll(
          await _services.fares.days(
            origin: from,
            destination: to,
            year: m.year,
            month: m.month,
            oneWay: !_roundTrip,
          ),
        );
      } on ApiException {
        // Sin calendario de ese mes: se enseña lo que haya.
      }
    }
    if (!mounted) return;
    // Que siga siendo la misma búsqueda (si ya buscaste otra cosa, se tira).
    if (_departure != around ||
        _from.code(_names) != from ||
        _to.code(_names) != to) {
      return;
    }
    final List<DayFare> near =
        all.where((DayFare d) => !d.day.isBefore(today)).toList()..sort(
          (DayFare a, DayFare b) => a.day
              .difference(around)
              .inDays
              .abs()
              .compareTo(b.day.difference(around).inDays.abs()),
        );
    setState(() {
      _days = near.take(9).toList()
        ..sort((DayFare a, DayFare b) => a.day.compareTo(b.day));
    });
  }

  /// Tocar un día cercano: se busca ese día (la vuelta se mueve igual,
  /// para que el viaje dure lo mismo).
  void _tryDay(DateTime day) {
    final DateTime? dep = _departure;
    if (dep == null) return;
    final Duration shift = day.difference(dep);
    setState(() {
      _departure = day;
      if (_return != null) _return = _return!.add(shift);
    });
    unawaited(_search());
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

  /// "Tokio" para "NRT" (o el código si no está en la lista).
  String _city(String iata) => _names?[iata]?.city ?? iata;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: NomadColors.background,
      appBar: AppBar(
        backgroundColor: NomadColors.background,
        title: Text(t.searchTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
        children: <Widget>[
          _panel(context, t),
          if (_days.isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
            _daysStrip(context, t),
          ],
          const SizedBox(height: 18),
          ..._results(context, t),
        ],
      ),
    );
  }

  // ---- El panel del formulario (como el "BUSCA TU VUELO" de la maqueta).

  Widget _panel(BuildContext context, AppLocalizations t) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: _C.line),
        gradient: const LinearGradient(
          begin: Alignment(-0.6, -1),
          end: Alignment(0.6, 1),
          colors: <Color>[_C.panelTop, _C.panelBottom],
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x806CA8FF),
            blurRadius: 34,
            offset: Offset(0, 14),
            spreadRadius: -16,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t.searchKicker,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
              color: _C.accent,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              _Pill(
                label: t.searchRoundTrip,
                on: _roundTrip,
                onTap: () => setState(() => _roundTrip = true),
              ),
              const SizedBox(width: 6),
              _Pill(
                label: t.flightsOneWay,
                on: !_roundTrip,
                onTap: () => setState(() => _roundTrip = false),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Stack(
            children: <Widget>[
              Column(
                children: <Widget>[
                  _field(t, _from, t.searchFrom, Icons.place_outlined),
                  if (_suggesting(_from)) _suggestions(_from),
                  const SizedBox(height: 8),
                  _field(t, _to, t.searchTo, Icons.flight_rounded),
                  if (_suggesting(_to)) _suggestions(_to),
                ],
              ),
              if (!_suggesting(_from) && !_suggesting(_to))
                PositionedDirectional(
                  end: 14,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _RoundButton(
                      tooltip: t.searchSwap,
                      icon: Icons.swap_vert_rounded,
                      onTap: _swap,
                      size: 36,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: _DateTile(
                  label: t.searchDeparture,
                  day: _departure,
                  onTap: () => _pickDate(outbound: true),
                ),
              ),
              if (_roundTrip) ...<Widget>[
                const SizedBox(width: 8),
                Expanded(
                  child: _DateTile(
                    label: t.searchReturn,
                    day: _return,
                    onTap: () => _pickDate(outbound: false),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: _C.field,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _C.line),
            ),
            child: Row(
              children: <Widget>[
                const Icon(Icons.person_outline_rounded, color: _C.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.searchAdults(_adults),
                    style: const TextStyle(
                      color: _C.ink,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                _RoundButton(
                  tooltip: t.searchRemoveTraveler,
                  icon: Icons.remove_rounded,
                  onTap: _adults > 1 ? () => setState(() => _adults--) : null,
                ),
                const SizedBox(width: 8),
                _RoundButton(
                  tooltip: t.searchAddTraveler,
                  icon: Icons.add_rounded,
                  onTap: _adults < FlightSearchScreen.maxAdults
                      ? () => setState(() => _adults++)
                      : null,
                ),
              ],
            ),
          ),
          if (_formError != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              _formError!,
              style: const TextStyle(
                color: NomadColors.safety,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 12),
          _GoButton(
            label: t.searchGo,
            busy: _searching,
            onTap: _searching ? null : _search,
          ),
        ],
      ),
    );
  }

  bool _suggesting(_Place p) =>
      p.focus.hasFocus &&
      p.picked == null &&
      p.text.text.trim().isNotEmpty &&
      (_names?.all.isNotEmpty ?? false);

  Widget _field(AppLocalizations t, _Place p, String label, IconData icon) {
    final String? code = p.code(_names);
    final AirportName? a = code == null ? null : _names?[code];
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 58, 6),
      decoration: BoxDecoration(
        color: _C.field,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: p.focus.hasFocus ? NomadColors.flights : _C.line,
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: _C.accent, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    color: _C.label,
                  ),
                ),
                TextField(
                  controller: p.text,
                  focusNode: p.focus,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  style: const TextStyle(
                    color: _C.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  onSubmitted: (_) {
                    final List<AirportName> hits =
                        _names?.search(p.text.text, limit: 1) ??
                        const <AirportName>[];
                    if (p.picked == null && hits.isNotEmpty) {
                      _choose(p, hits.first);
                    }
                  },
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    hintText: t.searchCityHint,
                    hintStyle: const TextStyle(
                      color: _C.hint,
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (a != null && a.flag.isNotEmpty)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 6),
              child: Text(a.flag, style: const TextStyle(fontSize: 16)),
            ),
          if (code != null) _CodeBadge(code: code),
        ],
      ),
    );
  }

  Widget _suggestions(_Place p) {
    final List<AirportName> hits =
        _names?.search(p.text.text, limit: 5) ?? const <AirportName>[];
    if (hits.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(
        color: _C.sugs,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _C.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (int i = 0; i < hits.length; i++)
            InkWell(
              onTap: () => _choose(p, hits[i]),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  border: i == 0
                      ? null
                      : const Border(top: BorderSide(color: Color(0xFF1B2A3F))),
                ),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 26,
                      child: Text(
                        hits[i].flag,
                        style: const TextStyle(fontSize: 18),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            hits[i].city,
                            style: const TextStyle(
                              color: _C.ink,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            hits[i].country,
                            style: const TextStyle(
                              color: _C.label,
                              fontSize: 11.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _CodeBadge(code: hits[i].iata),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ---- Los días cercanos (el calendario de precios en pequeño).

  Widget _daysStrip(BuildContext context, AppLocalizations t) {
    final int cheapest = _days
        .map((DayFare d) => d.pricePerAdult.amountMinor)
        .reduce((int a, int b) => a < b ? a : b);
    final String locale = localeOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          t.searchNearbyDays.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            color: _C.label,
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 92,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _days.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (BuildContext context, int i) {
              final DayFare d = _days[i];
              final bool chosen = d.day == _departure;
              final bool best = d.pricePerAdult.amountMinor == cheapest;
              return _DayChip(
                weekday: DateFormat.E(locale).format(d.day),
                day: dayText(context, d.day),
                price: priceText(context, d.pricePerAdult),
                chosen: chosen,
                best: best,
                bestLabel: t.searchCheapest,
                onTap: chosen || _searching ? null : () => _tryDay(d.day),
              );
            },
          ),
        ),
      ],
    );
  }

  // ---- Los resultados.

  List<Widget> _results(BuildContext context, AppLocalizations t) {
    const TextStyle muted = TextStyle(color: NomadColors.textMuted);
    if (_searching) {
      return const <Widget>[
        Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: CircularProgressIndicator(color: NomadColors.flights),
          ),
        ),
      ];
    }
    final ApiError? error = _error;
    if (error != null) {
      return <Widget>[
        _Notice(
          icon: Icons.cloud_off_rounded,
          text: switch (error) {
            ApiError.rateLimited => t.searchBusy,
            ApiError.network => t.errorNetwork,
            ApiError.invalidInput => t.searchMissingDates,
            _ => t.errorUnavailable,
          },
        ),
      ];
    }
    final SearchResult? result = _result;
    if (result == null) return const <Widget>[];
    if (result.offers.isEmpty) {
      return <Widget>[
        _Notice(
          icon: Icons.event_busy_rounded,
          text: _days.isEmpty ? t.searchNoResults : t.searchNoExactDay,
        ),
      ];
    }
    return <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${_city(result.route.origin)} → ${_city(result.route.destination)}',
              style: const TextStyle(
                fontFamily: NomadFonts.display,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: _C.ink,
              ),
            ),
          ),
          Text(
            t.searchResults(result.offers.length),
            style: const TextStyle(
              color: _C.accent,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
      const SizedBox(height: 4),
      Text(t.searchPricesNote, style: muted),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          style: TextButton.styleFrom(foregroundColor: _C.accent),
          onPressed: () => context.push(
            Routes.flightRoute(
              from: result.route.origin,
              to: result.route.destination,
            ),
          ),
          icon: const Icon(Icons.public_rounded),
          label: Text(t.routeShow),
        ),
      ),
      const SizedBox(height: 4),
      for (int i = 0; i < result.offers.length; i++)
        _OfferCard(
          offer: result.offers[i],
          adults: result.adults,
          from: result.route.origin,
          to: result.route.destination,
          best: i == 0,
          bestLabel: t.searchCheapest,
          onBook: () => _book(result.offers[i].bookingUrl),
          onWatch: () => _watch(result, result.offers[i]),
        ),
    ];
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.on, required this.onTap});

  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: on,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? NomadColors.flights : _C.field,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: on ? NomadColors.flights : _C.line),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w800,
            color: on ? NomadColors.background : _C.ink,
          ),
        ),
      ),
    ),
  );
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.size = 34,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: _C.chip,
      shape: const CircleBorder(side: BorderSide(color: Color(0xFF3A5584))),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: 18,
            color: onTap == null ? _C.hint : _C.accent,
          ),
        ),
      ),
    ),
  );
}

class _CodeBadge extends StatelessWidget {
  const _CodeBadge({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
    decoration: BoxDecoration(
      color: _C.panelBottom,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: _C.line),
    ),
    child: Text(
      code,
      style: const TextStyle(
        fontSize: 10.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.8,
        color: _C.accent,
      ),
    ),
  );
}

class _DateTile extends StatelessWidget {
  const _DateTile({
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
    final DateTime? d = day;
    return Material(
      color: _C.field,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _C.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 54,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: AlignmentDirectional.centerStart,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(
                    Icons.calendar_today_rounded,
                    size: 13,
                    color: _C.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    label.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      color: _C.label,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                d == null
                    ? t.searchPickDate
                    : '${DateFormat.E(localeOf(context)).format(d)} '
                          '${dayText(context, d)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: d == null ? _C.hint : _C.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// El botón grande azul → menta de la maqueta.
class _GoButton extends StatelessWidget {
  const _GoButton({
    required this.label,
    required this.busy,
    required this.onTap,
  });

  final String label;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: busy ? 0.6 : 1,
        child: Container(
          height: 52,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            gradient: const LinearGradient(
              colors: <Color>[NomadColors.flights, NomadColors.mint],
            ),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x8C3DDC97),
                blurRadius: 24,
                offset: Offset(0, 10),
                spreadRadius: -8,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(
                Icons.search_rounded,
                color: NomadColors.background,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: NomadColors.background,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.weekday,
    required this.day,
    required this.price,
    required this.chosen,
    required this.best,
    required this.bestLabel,
    required this.onTap,
  });

  final String weekday;
  final String day;
  final String price;
  final bool chosen;
  final bool best;
  final String bestLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final Color edge = chosen
        ? NomadColors.flights
        : best
        ? NomadColors.mint
        : _C.line;
    return Material(
      color: chosen ? _C.chip : _C.field,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: edge, width: chosen || best ? 1.6 : 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: 84,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Text(
                weekday.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: _C.label,
                ),
              ),
              Text(
                day,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: _C.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                price,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: best ? NomadColors.mint : _C.accent,
                ),
              ),
              if (best)
                Text(
                  bestLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: NomadColors.mint,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _C.sugs,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _C.line),
    ),
    child: Row(
      children: <Widget>[
        Icon(icon, color: _C.accent),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Color(0xFFDCE5E9),
              fontWeight: FontWeight.w700,
              height: 1.4,
            ),
          ),
        ),
      ],
    ),
  );
}

/// Una oferta, como una tarjeta de embarque: precio grande, horarios y
/// escalas, y los botones de reservar y avisar.
class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.offer,
    required this.adults,
    required this.from,
    required this.to,
    required this.best,
    required this.bestLabel,
    required this.onBook,
    required this.onWatch,
  });

  final Offer offer;
  final int adults;
  final String from;
  final String to;
  final bool best;
  final String bestLabel;
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
    const TextStyle muted = TextStyle(color: _C.label, fontSize: 12.5);
    const TextStyle leg = TextStyle(
      color: _C.ink,
      fontWeight: FontWeight.w700,
      fontSize: 13.5,
    );
    final int hours = offer.durationMinutes ~/ 60;
    final int minutes = offer.durationMinutes % 60;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: best ? NomadColors.mint.withValues(alpha: 0.6) : _C.line,
        ),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF132036), Color(0xFF0E1726)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _CodeBadge(code: from),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6),
                child: Icon(
                  Icons.flight_takeoff_rounded,
                  size: 16,
                  color: _C.accent,
                ),
              ),
              _CodeBadge(code: to),
              const Spacer(),
              if (best)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: NomadColors.mint.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    bestLabel,
                    style: const TextStyle(
                      color: NomadColors.mint,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
              if (offer.carrier.isNotEmpty) ...<Widget>[
                const SizedBox(width: 6),
                Text(
                  offer.carrier,
                  style: const TextStyle(
                    color: _C.label,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(
            t.searchPerPerson(priceText(context, offer.pricePerAdult)),
            style: TextStyle(
              fontFamily: NomadFonts.display,
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: best ? NomadColors.mint : _C.ink,
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
          const SizedBox(height: 10),
          Text(
            '${t.searchDeparture}: '
            '${_leg(context, t, offer.departureAt, offer.transfers)}',
            style: leg,
          ),
          if (offer.returnAt != null)
            Text(
              '${t.searchReturn}: '
              '${_leg(context, t, offer.returnAt!, offer.returnTransfers)}',
              style: leg,
            ),
          if (offer.durationMinutes > 0)
            Text(t.searchDuration(hours, minutes), style: muted),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: NomadColors.mint,
                  foregroundColor: NomadColors.background,
                ),
                onPressed: onBook,
                icon: const Icon(Icons.open_in_new_rounded),
                label: Text(t.flightsBook),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _C.accent,
                  side: const BorderSide(color: _C.line),
                ),
                onPressed: onWatch,
                icon: const Icon(Icons.notifications_active_rounded),
                label: Text(t.flightsNotify),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
