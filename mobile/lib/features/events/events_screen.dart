// Qué pasa en tus fechas (maqueta "Eventos"): festivos y eventos de la
// ciudad a la que vas, día a día.
//
// Lo de la maqueta que NO está, a propósito: el precio medio del hotel por
// noche y frases como "hoteles +55 % esa noche". No hay datos gratis y
// comprobados para eso, y la app no inventa nada. Lo que se ve aquí es real
// y con fuente: festivos oficiales (Nager.Date) y eventos publicados en
// Ticketmaster, con el precio que pone el organizador si lo pone.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../easy/easy_mode.dart';
import '../flights/flights_screen.dart' show showOriginSheet;
import 'events_api.dart';

IconData eventIcon(EventKind k) => switch (k) {
  EventKind.holiday => Icons.celebration_rounded,
  EventKind.music => Icons.music_note_rounded,
  EventKind.sports => Icons.sports_soccer_rounded,
  EventKind.arts => Icons.theater_comedy_rounded,
  EventKind.family => Icons.family_restroom_rounded,
  EventKind.other => Icons.event_rounded,
};

Color eventColor(EventKind k) => switch (k) {
  EventKind.holiday => NomadColors.money,
  EventKind.music => NomadColors.group,
  EventKind.sports => NomadColors.mint,
  EventKind.arts => NomadColors.safety,
  EventKind.family => NomadColors.flights,
  EventKind.other => NomadColors.textMuted,
};

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key, this.iata});

  /// El aeropuerto de la ciudad (si no, el destino del Modo fácil).
  final String? iata;

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final EasyTrip _trip = loadEasyTrip(_services.prefs);
  late String? _iata = widget.iata?.toUpperCase() ?? _trip.to;
  late DateTimeRange _dates = () {
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    final DateTime? dep = _trip.departure;
    final DateTime start = dep != null && !dep.isBefore(today)
        ? DateUtils.dateOnly(dep)
        : today.add(const Duration(days: 14));
    return DateTimeRange(start: start, end: start.add(const Duration(days: 4)));
  }();

  CityEvents? _found;
  bool _loading = false;
  ApiError? _error;
  DateTime? _day;
  bool _onlySaved = false;
  late Set<String> _saved = <String>{
    ...?(_decode(_services.prefs.readData(LocalData.savedEvents))),
  };

  static List<String>? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final Object? v = jsonDecode(raw);
      return v is List<Object?>
          ? <String>[
              for (final Object? x in v.take(200))
                if (x is String) x,
            ]
          : null;
    } on FormatException {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  Future<void> _load() async {
    final String? iata = _iata;
    if (iata == null) return;
    setState(() => (_loading = true, _error = null, _day = null));
    try {
      final CityEvents found = await _services.events.between(
        iata,
        _dates.start,
        _dates.end,
      );
      if (mounted) setState(() => (_found = found, _loading = false));
    } on ApiException catch (e) {
      if (mounted) setState(() => (_error = e.error, _loading = false));
    }
  }

  Future<void> _pickCity() async {
    final String? code = await showOriginSheet(context, current: _iata ?? '');
    if (code == null || !mounted) return;
    setState(() => _iata = code);
    await _load();
  }

  Future<void> _pickDates() async {
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
      initialDateRange: _dates,
    );
    if (range == null || !mounted) return;
    // Como mucho un mes (lo que acepta el servidor).
    final DateTime end = range.end.difference(range.start).inDays > 30
        ? range.start.add(const Duration(days: 30))
        : range.end;
    setState(() => _dates = DateTimeRange(start: range.start, end: end));
    await _load();
  }

  Future<void> _toggleSave(CityEvent e) async {
    setState(() {
      _saved = <String>{..._saved};
      if (!_saved.remove(e.id)) _saved.add(e.id);
    });
    await _services.prefs.writeData(
      LocalData.savedEvents,
      _saved.isEmpty ? null : jsonEncode(_saved.toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final CityEvents? found = _found;
    final List<DateTime> days = <DateTime>[
      for (
        DateTime d = _dates.start;
        !d.isAfter(_dates.end);
        d = DateTime(d.year, d.month, d.day + 1)
      )
        d,
    ];
    final List<CityEvent> all = found?.events ?? const <CityEvent>[];
    final List<CityEvent> shown = <CityEvent>[
      for (final CityEvent e in all)
        if ((_day == null || DateUtils.isSameDay(e.date, _day)) &&
            (!_onlySaved || _saved.contains(e.id)))
          e,
    ];
    final int holidays = all
        .where((CityEvent e) => e.kind == EventKind.holiday)
        .length;
    final String range =
        '${DateFormat.MMMd(locale).format(_dates.start)} – ${DateFormat.MMMd(locale).format(_dates.end)}';
    return Scaffold(
      appBar: AppBar(title: Text(t.eventsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                icon: const Icon(Icons.location_city_rounded),
                label: Text(
                  _iata == null
                      ? t.eventsPickCity
                      : found == null || found.city.isEmpty
                      ? _iata!
                      : '${found.city} · $_iata',
                ),
                onPressed: () => unawaited(_pickCity()),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.date_range_rounded),
                label: Text(range),
                onPressed: () => unawaited(_pickDates()),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_iata == null)
            Text(t.eventsNoCity)
          else if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Text(
              _error == ApiError.network
                  ? t.eventsOffline
                  : t.eventsUnavailable,
            )
          else if (found != null) ...<Widget>[
            // Los días del viaje: cuántas cosas hay cada día (datos reales).
            SizedBox(
              height: 84,
              child: Row(
                children: <Widget>[
                  for (final DateTime d in days.take(31))
                    Expanded(
                      child: _DayColumn(
                        day: d,
                        locale: locale,
                        count: all
                            .where(
                              (CityEvent e) => DateUtils.isSameDay(e.date, d),
                            )
                            .length,
                        holiday: all.any(
                          (CityEvent e) =>
                              e.kind == EventKind.holiday &&
                              DateUtils.isSameDay(e.date, d),
                        ),
                        selected: _day != null && DateUtils.isSameDay(_day, d),
                        onTap: () => setState(
                          () => _day =
                              _day != null && DateUtils.isSameDay(_day, d)
                              ? null
                              : d,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _Tip(
              text: all.isEmpty
                  ? t.eventsNone
                  : t.eventsSummary(
                      t.eventsHolidaysCount(holidays),
                      t.eventsEventsCount(all.length - holidays),
                    ),
            ),
            if (!found.sources.contains('Ticketmaster'))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  t.eventsOnlyHolidays,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FilterChip(
                label: Text(t.eventsSaved(_saved.length)),
                selected: _onlySaved,
                onSelected: (bool v) => setState(() => _onlySaved = v),
              ),
            ),
            const SizedBox(height: 8),
            for (final CityEvent e in shown)
              _EventCard(
                event: e,
                saved: _saved.contains(e.id),
                onSave: () => unawaited(_toggleSave(e)),
                onOpen: e.url == null
                    ? null
                    : () => unawaited(_services.openBooking(e.url!)),
              ),
            const SizedBox(height: 12),
            if (found.sources.isNotEmpty)
              Text(
                t.eventsSources(found.sources.join(', ')),
                style: const TextStyle(
                  fontSize: 12,
                  color: NomadColors.textMuted,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    required this.day,
    required this.locale,
    required this.count,
    required this.holiday,
    required this.selected,
    required this.onTap,
  });

  final DateTime day;
  final String locale;
  final int count;
  final bool holiday;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double h = 8 + (count.clamp(0, 6) * 7).toDouble();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: <Widget>[
            if (count > 0) Text('$count', style: const TextStyle(fontSize: 11)),
            Container(
              height: h,
              decoration: BoxDecoration(
                color: holiday
                    ? NomadColors.money
                    : count > 0
                    ? NomadColors.flights
                    : NomadColors.outline,
                borderRadius: BorderRadius.circular(4),
                border: selected
                    ? Border.all(color: Colors.white, width: 2)
                    : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              DateFormat.E(locale).format(day).characters.first.toUpperCase(),
              style: const TextStyle(
                fontSize: 11,
                color: NomadColors.textMuted,
              ),
            ),
            Text(
              '${day.day}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF13342A),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF23523F)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const FlyraAvatar(size: 28),
        const SizedBox(width: 10),
        Expanded(child: Text(text)),
      ],
    ),
  );
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.saved,
    required this.onSave,
    required this.onOpen,
  });

  final CityEvent event;
  final bool saved;
  final VoidCallback onSave;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final CityEvent e = event;
    final String when = <String>[
      DateFormat.MMMEd(locale).format(e.date),
      ?e.time,
      ?e.venue,
    ].join(' · ');
    final String? price = e.priceMin == null || e.currency == null
        ? null
        : t.eventsFrom(
            NumberFormat.simpleCurrency(
              locale: locale,
              name: e.currency,
            ).format(e.priceMin),
          );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: eventColor(e.kind),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(eventIcon(e.kind), color: const Color(0xFF0B1217)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(e.name, style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    when,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                  if (e.kind == EventKind.holiday)
                    Text(
                      e.regional ? t.eventsHolidayRegional : t.eventsHoliday,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: NomadColors.money,
                      ),
                    ),
                  if (price != null)
                    Text(
                      price,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  if (onOpen != null)
                    TextButton(onPressed: onOpen, child: Text(t.eventsTickets)),
                ],
              ),
            ),
            IconButton(
              tooltip: saved ? t.eventsUnsave : t.eventsSave,
              icon: Icon(
                saved ? Icons.star_rounded : Icons.star_border_rounded,
                color: saved ? NomadColors.money : null,
              ),
              onPressed: onSave,
            ),
          ],
        ),
      ),
    );
  }
}
