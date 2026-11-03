// Qué pasa en tus fechas (maqueta "Eventos", pantalla 40): festivos y
// eventos de la ciudad a la que vas, en el mismo orden que la maqueta:
//   1. El número grande de "cosas pasan en tus fechas".
//   2. "TUS DÍAS · TOCA UNO" y los tipos (Música, Fiestas, Deporte...).
//   3. Las tarjetas: estado de las entradas, cuenta atrás, "Entradas",
//      "+ Planes" (a "Elegid planes" del viaje en grupo) y el corazón (Flyra
//      te avisa la víspera y 2 horas antes).
//   4. "Dónde pasan": los pines en su sitio real (coordenadas de
//      Ticketmaster).
//   5. El consejo de Flyra (solo si dos eventos coinciden el mismo día).
//
// Lo de la maqueta que NO está, a propósito: el precio medio del hotel por
// noche y frases como "hoteles +55 % esa noche". No hay datos gratis y
// comprobados para eso, y la app no inventa nada. Lo que se ve aquí es real
// y con fuente: festivos oficiales (Nager.Date) y eventos publicados en
// Ticketmaster, con el precio que pone el organizador si lo pone.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../easy/easy_mode.dart';
import '../map/geo.dart';
import '../map/map_style.dart';
import '../map/map_surface.dart';
import '../stays/pick_point_screen.dart';
import '../flights/flights_screen.dart' show showOriginSheet;
import '../group/group_api.dart';
import '../plans/plans_api.dart';
import '../route/world_data.dart';
import 'event_reminders.dart';
import 'hotel_sheet.dart';
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

/// Los tipos de la fila de filtros (null = "Todo").
const List<EventKind?> _cats = <EventKind?>[
  null,
  EventKind.music,
  EventKind.holiday,
  EventKind.sports,
  EventKind.arts,
  EventKind.family,
];

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
  EventKind? _cat;

  /// El evento del pin que tocaste en el mapa (null = todos).
  String? _pin;

  /// Los que ya mandaste a "Elegid planes" en esta visita.
  final Set<String> _planned = <String>{};
  late Set<String> _saved = <String>{
    ...?(_decode(_services.prefs.readData(LocalData.savedEvents))),
  };

  /// Dónde está tu hotel en esta ciudad (lo marcas tú en el mapa).
  late GeoPoint? _hotel = _hotelFor(_iata);

  /// El centro de unos eventos (para empezar el mapa ahí).
  static GeoPoint _centerOf(List<CityEvent> pins) => GeoPoint(
    pins.map((CityEvent e) => e.lat!).reduce((double a, double b) => a + b) /
        pins.length,
    pins.map((CityEvent e) => e.lon!).reduce((double a, double b) => a + b) /
        pins.length,
  );

  /// El hotel guardado, solo si es de esta ciudad.
  GeoPoint? _hotelFor(String? iata) {
    final String? raw = _services.prefs.readData(LocalData.eventsHotel);
    if (raw == null || iata == null) return null;
    try {
      final Object? v = jsonDecode(raw);
      if (v is! Map<String, Object?> || v['iata'] != iata) return null;
      final Object? lat = v['lat'];
      final Object? lon = v['lon'];
      if (lat is! num || lon is! num) return null;
      return GeoPoint(lat.toDouble(), lon.toDouble());
    } on FormatException {
      return null;
    }
  }

  /// Decir dónde está el hotel: buscándolo (Modo fácil, una reserva de la
  /// Bóveda o escribiendo el nombre) o marcándolo en el mapa con la diana.
  Future<void> _pickHotel(GeoPoint around) async {
    final String? iata = _iata;
    if (iata == null) return;
    final HotelChoice? choice = await showHotelSheet(context, around);
    if (choice == null || !mounted) return;
    final GeoPoint? p = switch (choice) {
      HotelFound(:final GeoPoint point) => point,
      HotelOnMap() => await Navigator.of(context).push<GeoPoint>(
        MaterialPageRoute<GeoPoint>(
          builder: (_) => PickPointScreen(initial: _hotel ?? around),
        ),
      ),
    };
    if (p == null || !mounted) return;
    await _services.prefs.writeData(
      LocalData.eventsHotel,
      jsonEncode(<String, Object?>{'iata': iata, 'lat': p.lat, 'lon': p.lon}),
    );
    if (mounted) setState(() => _hotel = p);
  }

  /// "A 12 min andando de tu hotel" (a 80 m por minuto) o, si está lejos,
  /// "A 7,5 km de tu hotel".
  String? _fromHotel(AppLocalizations t, CityEvent e, String locale) {
    final GeoPoint? h = _hotel;
    if (h == null || e.lat == null || e.lon == null) return null;
    final double m = h.distanceTo(GeoPoint(e.lat!, e.lon!));
    if (m <= 3000) return t.eventsWalkFromHotel(math.max(1, (m / 80).round()));
    return t.eventsKmFromHotel(NumberFormat('0.#', locale).format(m / 1000));
  }

  /// La zona horaria de la ciudad ("Europe/Lisbon"), para la cuenta atrás.
  tz.Location? _zone;
  Timer? _tick;

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

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  static bool _tzReady = false;

  Future<void> _findZone(String iata) async {
    try {
      final Airports all = await _services.loadAirports();
      final String? zone = all[iata]?.timeZone;
      if (zone == null || zone.isEmpty) return;
      if (!_tzReady) {
        tzdata.initializeTimeZones();
        _tzReady = true;
      }
      final tz.Location loc = tz.getLocation(zone);
      if (mounted) setState(() => _zone = loc);
    } on Object {
      // Sin zona horaria no hay cuenta atrás (el resto sale igual).
    }
  }

  Future<void> _load() async {
    final String? iata = _iata;
    if (iata == null) return;
    setState(() => (_loading = true, _error = null, _day = null, _pin = null));
    unawaited(_findZone(iata));
    try {
      final CityEvents found = await _services.events.between(
        iata,
        _dates.start,
        _dates.end,
      );
      if (!mounted) return;
      setState(() => (_found = found, _loading = false));
      // La cuenta atrás: se repinta cada segundo mientras estás aquí.
      _tick?.cancel();
      if (found.events.any((CityEvent e) => e.time != null)) {
        _tick = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) setState(() {});
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => (_error = e.error, _loading = false));
    }
  }

  Future<void> _pickCity() async {
    final String? code = await showOriginSheet(context, current: _iata ?? '');
    if (code == null || !mounted) return;
    setState(() => (_iata = code, _zone = null, _hotel = _hotelFor(code)));
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

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Cuándo empieza (hora absoluta), si se sabe la hora y la zona.
  DateTime? _startOf(CityEvent e) {
    final tz.Location? zone = _zone;
    final String? time = e.time;
    if (zone == null || time == null) return null;
    final List<String> hm = time.split(':');
    if (hm.length < 2) return null;
    final int? h = int.tryParse(hm[0]);
    final int? m = int.tryParse(hm[1]);
    if (h == null || m == null) return null;
    return tz.TZDateTime(zone, e.date.year, e.date.month, e.date.day, h, m);
  }

  Future<void> _toggleSave(CityEvent e) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool adding = !_saved.contains(e.id);
    setState(() {
      _saved = <String>{..._saved};
      if (!_saved.remove(e.id)) _saved.add(e.id);
    });
    await _services.prefs.writeData(
      LocalData.savedEvents,
      _saved.isEmpty ? null : jsonEncode(_saved.toList()),
    );
    if (!adding) {
      await _services.eventReminders.cancel(e.id);
      return;
    }
    // La víspera a las 20:00 (hora de la ciudad si la sabemos) y 2 horas
    // antes de que empiece (si se sabe la hora).
    final tz.Location? zone = _zone;
    final DateTime eve = zone == null
        ? DateTime(e.date.year, e.date.month, e.date.day - 1, 20)
        : tz.TZDateTime(zone, e.date.year, e.date.month, e.date.day - 1, 20);
    final DateTime? start = _startOf(e);
    final String when = _whenText(e);
    await _services.eventReminders.schedule(e.id, <EventReminder>[
      EventReminder(at: eve, title: t.eventsReminderEve(e.name), body: when),
      if (start != null)
        EventReminder(
          at: start.subtract(const Duration(hours: 2)),
          title: t.eventsReminderSoon(e.name),
          body: when,
        ),
    ]);
    if (mounted) _say(t.eventsSavedToast);
  }

  String _whenText(CityEvent e) {
    final String locale = Localizations.localeOf(context).toLanguageTag();
    return <String>[
      DateFormat.MMMEd(locale).format(e.date),
      ?e.time,
      ?e.venue,
    ].join(' · ');
  }

  /// Tus viajes en grupo (para "+ Planes"). Si hay varios, eliges uno.
  Future<GroupTrip?> _pickGroup() async {
    final AppLocalizations t = AppLocalizations.of(context);
    List<GroupTrip> trips;
    try {
      trips = await _services.group.list();
    } on ApiException catch (e) {
      if (mounted) {
        _say(e.error == ApiError.network ? t.errorNetwork : t.eventsNoGroup);
      }
      return null;
    }
    if (!mounted) return null;
    if (trips.isEmpty) {
      _say(t.eventsNoGroup);
      return null;
    }
    if (trips.length == 1) return trips.single;
    return showModalBottomSheet<GroupTrip>(
      context: context,
      useRootNavigator: true,
      builder: (BuildContext sheet) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              title: Text(
                t.eventsPickGroup,
                style: Theme.of(sheet).textTheme.titleMedium,
              ),
            ),
            for (final GroupTrip g in trips)
              ListTile(
                leading: const Icon(Icons.groups_rounded),
                title: Text(g.title),
                onTap: () => Navigator.of(sheet).pop(g),
              ),
          ],
        ),
      ),
    );
  }

  /// "+ Planes": el evento entra en "Elegid planes" del viaje en grupo.
  Future<void> _toPlans(CityEvent e) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final GroupTrip? group = await _pickGroup();
    if (group == null || !mounted) return;
    try {
      await _services.plans.add(group.id, <NewPlan>[
        NewPlan(title: e.name, note: _whenText(e)),
      ]);
    } on ApiException catch (err) {
      if (mounted) {
        _say(switch (err.error) {
          ApiError.network => t.errorNetwork,
          ApiError.conflict => t.plansTooMany,
          _ => t.errorUnavailable,
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _planned.add(e.id));
    _say(t.eventsSentToPlans);
  }

  Future<void> _openVote() async {
    final GroupTrip? group = await _pickGroup();
    if (group == null || !mounted) return;
    await context.push(Routes.groupPlans(group.id, city: _found?.city));
  }

  /// El consejo de Flyra: solo si dos eventos (no festivos) coinciden el
  /// mismo día. Nada inventado: sale de los propios eventos.
  String? _tip(AppLocalizations t, List<CityEvent> all, String locale) {
    final Map<DateTime, List<CityEvent>> byDay = <DateTime, List<CityEvent>>{};
    for (final CityEvent e in all) {
      byDay.putIfAbsent(e.date, () => <CityEvent>[]).add(e);
    }
    final MapEntry<DateTime, List<CityEvent>>? busy = byDay.entries
        .where((MapEntry<DateTime, List<CityEvent>> d) => d.value.length >= 2)
        .fold<MapEntry<DateTime, List<CityEvent>>?>(
          null,
          (MapEntry<DateTime, List<CityEvent>>? best, d) =>
              best == null || d.value.length > best.value.length ? d : best,
        );
    if (busy == null) return null;
    return t.eventsTipBusy(
      DateFormat.MMMEd(locale).format(busy.key),
      busy.value[0].name,
      busy.value[1].name,
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
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
        if (_pin != null
            ? e.id == _pin
            : (_day == null || DateUtils.isSameDay(e.date, _day)) &&
                  (_cat == null || e.kind == _cat))
          e,
    ];
    final String range =
        '${DateFormat.MMMd(locale).format(_dates.start)} – ${DateFormat.MMMd(locale).format(_dates.end)}';
    final List<CityEvent> pins = <CityEvent>[
      for (final CityEvent e in all)
        if (e.lat != null && e.lon != null) e,
    ];
    final String? tip = found == null ? null : _tip(t, all, locale);
    final bool tm = found?.sources.contains('Ticketmaster') ?? false;
    return Scaffold(
      appBar: AppBar(title: Text(t.eventsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: <Widget>[
          // La ciudad y las fechas (se pueden cambiar).
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
                icon: const Icon(Icons.location_city_rounded),
                label: Text(
                  _iata == null
                      ? t.eventsPickCity
                      : found == null || found.city.isEmpty
                      ? _iata!
                      : found.city,
                ),
                onPressed: () => unawaited(_pickCity()),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 36)),
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
            // 1. El número grande.
            _Hero(
              count: all.length,
              sub: _pin != null ? t.eventsMapFiltered : t.eventsHeroSub,
              ticketmaster: tm,
            ),
            if (!tm)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  t.eventsOnlyHolidays,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
              ),
            const SizedBox(height: 16),
            // 2. Los días y los tipos.
            Text(
              t.eventsDaysTitle,
              style: text.labelMedium?.copyWith(
                color: NomadColors.textMuted,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 72,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: <Widget>[
                  _DayChip(
                    top: t.eventsAllDays,
                    big: '★',
                    count: all.length,
                    on: _day == null,
                    onTap: () => setState(() => (_day = null, _pin = null)),
                  ),
                  for (final DateTime d in days.take(31))
                    _DayChip(
                      top: DateFormat.E(locale).format(d).toUpperCase(),
                      big: '${d.day}',
                      count: all
                          .where(
                            (CityEvent e) => DateUtils.isSameDay(e.date, d),
                          )
                          .length,
                      on: _day != null && DateUtils.isSameDay(_day, d),
                      onTap: () => setState(() => (_day = d, _pin = null)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: <Widget>[
                  for (final EventKind? k in _cats)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: ChoiceChip(
                        avatar: Icon(
                          k == null
                              ? Icons.confirmation_number_rounded
                              : eventIcon(k),
                          size: 18,
                        ),
                        label: Text(switch (k) {
                          null => t.eventsCatAll,
                          EventKind.music => t.eventsCatMusic,
                          EventKind.holiday => t.eventsCatParty,
                          EventKind.sports => t.eventsCatSports,
                          EventKind.arts => t.eventsCatArts,
                          EventKind.family => t.eventsCatFamily,
                          EventKind.other => t.eventsCatAll,
                        }),
                        selected: _cat == k,
                        onSelected: (_) =>
                            setState(() => (_cat = k, _pin = null)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 3. Las tarjetas.
            if (all.isEmpty)
              Text(t.eventsNone)
            else if (shown.isEmpty)
              Text(
                t.eventsEmptyFilter,
                style: const TextStyle(color: NomadColors.textMuted),
              ),
            for (final CityEvent e in shown)
              _EventCard(
                event: e,
                saved: _saved.contains(e.id),
                planned: _planned.contains(e.id),
                start: _startOf(e),
                fromHotel: _fromHotel(t, e, locale),
                onSave: () => unawaited(_toggleSave(e)),
                onPlans: e.kind == EventKind.holiday
                    ? null
                    : () => unawaited(_toPlans(e)),
                onOpen: e.url == null
                    ? null
                    : () => unawaited(_services.openBooking(e.url!)),
              ),
            // 4. Dónde pasan.
            if (pins.length >= 2) ...<Widget>[
              const SizedBox(height: 20),
              Text(t.eventsMapTitle, style: text.titleLarge),
              Text(
                t.eventsMapSub,
                style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 8),
              _PinMap(
                events: pins,
                selected: _pin,
                hotel: _hotel,
                onPick: (CityEvent e) => setState(
                  () => (
                    _pin = _pin == e.id ? null : e.id,
                    _day = null,
                    _cat = null,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Tu hotel: para saber qué te queda cerca.
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () => unawaited(_pickHotel(_centerOf(pins))),
                  icon: const Icon(Icons.hotel_rounded),
                  label: Text(
                    _hotel == null ? t.eventsSetHotel : t.eventsChangeHotel,
                  ),
                ),
              ),
            ],
            // 5. El consejo de Flyra.
            if (tip != null) ...<Widget>[
              const SizedBox(height: 16),
              _Tip(text: tip),
            ],
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.favorite_rounded),
              label: Text(t.eventsVoteLink),
              onPressed: () => unawaited(_openVote()),
            ),
            const SizedBox(height: 8),
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

/// El número grande de arriba, con notas musicales que suben.
class _Hero extends StatefulWidget {
  const _Hero({
    required this.count,
    required this.sub,
    required this.ticketmaster,
  });

  final int count;
  final String sub;
  final bool ticketmaster;

  @override
  State<_Hero> createState() => _HeroState();
}

class _HeroState extends State<_Hero> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Con "reducir movimiento", sin notas que se muevan. Solo 3 vueltas
      // (12 s) para no gastar batería.
      if (mounted && !MediaQuery.of(context).disableAnimations) {
        unawaited(_c.repeat(count: 3));
      }
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Container(
      clipBehavior: Clip.antiAlias,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[Color(0xFF2A1A5A), Color(0xFF1D1636)],
        ),
        border: Border.all(color: const Color(0xFF3E3163)),
      ),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: _c,
                builder: (BuildContext context, _) =>
                    CustomPaint(painter: _Notes(_c.value)),
              ),
            ),
          ),
          Row(
            children: <Widget>[
              Text(
                '${widget.count}',
                style: text.displayMedium?.copyWith(
                  fontWeight: FontWeight.w900,
                  color: const Color(0xFFFFD27A),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t.eventsHeroLabel(widget.count),
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      widget.sub,
                      style: const TextStyle(color: Color(0xFFE3DAFF)),
                    ),
                    if (widget.ticketmaster) ...<Widget>[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF026CDF),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'TICKETMASTER',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Las notas ♪ que suben por detrás del número.
class _Notes extends CustomPainter {
  const _Notes(this.t);

  final double t;

  static const List<Color> _colors = <Color>[
    Color(0xFFFFD27A),
    Color(0xFFFF7AB6),
    Color(0xFFB69CFF),
    Color(0xFF7FE8B9),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (int k = 0; k < 6; k++) {
      final double p = (t + k / 6) % 1;
      final TextPainter note = TextPainter(
        text: TextSpan(
          text: '♪',
          style: TextStyle(
            fontSize: 14 + (k % 3) * 4,
            color: _colors[k % 4].withValues(alpha: (1 - p) * 0.7),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final double x =
          size.width * (0.35 + 0.1 * k) + math.sin(p * math.pi * 2 + k) * 10;
      final double y = size.height * (1 - p) - 8;
      note.paint(canvas, Offset(x % size.width, y));
    }
  }

  @override
  bool shouldRepaint(_Notes old) => old.t != t;
}

/// Un día de la fila "TUS DÍAS": el día de la semana, el número y puntos
/// según cuántas cosas pasan.
class _DayChip extends StatelessWidget {
  const _DayChip({
    required this.top,
    required this.big,
    required this.count,
    required this.on,
    required this.onTap,
  });

  final String top;
  final String big;
  final int count;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(end: 8),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: 58,
      transform: Matrix4.translationValues(0, on ? -3 : 0, 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: on
            ? const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[Color(0xFFFFD27A), Color(0xFFFF7AB6)],
              )
            : null,
        color: on ? null : NomadColors.surface,
        border: on ? null : Border.all(color: NomadColors.outline),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text(
              top,
              maxLines: 1,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: on ? const Color(0xFF120C24) : NomadColors.textMuted,
              ),
            ),
            Text(
              big,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: on ? const Color(0xFF120C24) : NomadColors.text,
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (int j = 0; j < 3; j++)
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: j < math.min(3, count)
                          ? (on
                                ? const Color(0xFF120C24)
                                : const Color(0xFFFF7AB6))
                          : Colors.transparent,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// "Dónde pasan": el mapa de verdad (OpenStreetMap, el mismo de la pantalla
/// Mapa) con un punto de color por evento y uno blanco para tu hotel. Toca
/// un punto para ver solo su evento.
class _PinMap extends StatefulWidget {
  const _PinMap({
    required this.events,
    required this.selected,
    required this.hotel,
    required this.onPick,
  });

  final List<CityEvent> events;
  final String? selected;
  final GeoPoint? hotel;
  final ValueChanged<CityEvent> onPick;

  @override
  State<_PinMap> createState() => _PinMapState();
}

class _PinMapState extends State<_PinMap> {
  late final AppServices _services = ServicesScope.of(context);
  MapSurfaceController? _map;
  Map<String, Object?>? _style;

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  @override
  void didUpdateWidget(_PinMap old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected ||
        old.hotel != widget.hotel ||
        old.events != widget.events) {
      unawaited(_draw());
    }
  }

  /// Los puntos (GeoJSON): los eventos con su color y el hotel en blanco.
  Future<void> _draw() async {
    final MapSurfaceController? map = _map;
    if (map == null) return;
    final GeoPoint? h = widget.hotel;
    await map.showPins(<String, Object?>{
      'type': 'FeatureCollection',
      'features': <Object?>[
        for (final CityEvent e in widget.events)
          <String, Object?>{
            'type': 'Feature',
            'id': e.id,
            'geometry': <String, Object?>{
              'type': 'Point',
              'coordinates': <double>[e.lon!, e.lat!],
            },
            'properties': <String, Object?>{
              'color': _hex(eventColor(e.kind)),
              'selected': e.id == widget.selected,
            },
          },
        if (h != null)
          <String, Object?>{
            'type': 'Feature',
            'id': 'hotel',
            'geometry': <String, Object?>{
              'type': 'Point',
              'coordinates': <double>[h.lon, h.lat],
            },
            'properties': <String, Object?>{
              'color': '#ffffff',
              'selected': false,
            },
          },
      ],
    });
  }

  /// Tocar el mapa: el evento más cercano al dedo (si está cerca).
  void _tap(GeoPoint p) {
    CityEvent? best;
    double bestM = double.infinity;
    for (final CityEvent e in widget.events) {
      final double m = p.distanceTo(GeoPoint(e.lat!, e.lon!));
      if (m < bestM) (best, bestM) = (e, m);
    }
    // Más lejos de 600 m no cuenta como tocar ese punto.
    if (best != null && bestM <= 600) widget.onPick(best);
  }

  @override
  Widget build(BuildContext context) {
    final List<CityEvent> ev = widget.events;
    double minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
    for (final CityEvent e in ev) {
      minLat = math.min(minLat, e.lat!);
      maxLat = math.max(maxLat, e.lat!);
      minLon = math.min(minLon, e.lon!);
      maxLon = math.max(maxLon, e.lon!);
    }
    // El zum para que quepan todos: cada nivel ve la mitad que el anterior.
    final double span = math.max(
      math.max(maxLat - minLat, maxLon - minLon),
      0.005,
    );
    final double zoom = (math.log(360 / span) / math.ln2 - 1.2).clamp(9, 15);
    _style ??= buildMapStyle(
      look: resolveLook(MapLook.auto, DateTime.now()),
      language: Localizations.localeOf(context).languageCode,
      tilesUrl: _services.tilesUrl,
      glyphsUrl: _services.glyphsUrl,
    );
    return AspectRatio(
      aspectRatio: 1.4,
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: NomadColors.outline),
        ),
        child: _services.mapSurface(
          MapSurfaceSpec(
            style: _style!,
            initialCenter: GeoPoint(
              (minLat + maxLat) / 2,
              (minLon + maxLon) / 2,
            ),
            initialZoom: zoom,
            onReady: (MapSurfaceController c) {
              _map = c;
              unawaited(_draw());
            },
            onIdle: () {},
            onTap: _tap,
          ),
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

/// "1 d 04:13:32".
String _countdown(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final int days = d.inDays;
  final String hms =
      '${two(d.inHours % 24)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  return days > 0 ? '$days d $hms' : hms;
}

class _EventCard extends StatelessWidget {
  const _EventCard({
    required this.event,
    required this.saved,
    required this.planned,
    required this.start,
    required this.onSave,
    required this.onPlans,
    required this.onOpen,
    this.fromHotel,
  });

  /// "A 12 min andando de tu hotel" (null = sin hotel o sin sitio).
  final String? fromHotel;

  final CityEvent event;
  final bool saved;
  final bool planned;

  /// Cuándo empieza (null = no se sabe la hora): para la cuenta atrás.
  final DateTime? start;
  final VoidCallback onSave;
  final VoidCallback? onPlans;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final CityEvent e = event;
    final Color color = eventColor(e.kind);
    final String when = <String>[
      DateFormat.MMMEd(locale).format(e.date),
      ?e.time,
      ?e.venue,
    ].join(' · ');
    final String? price = e.priceMin == null || e.currency == null
        ? (e.kind != EventKind.holiday && e.url != null
              ? t.eventsPriceAt
              : null)
        : t.eventsFrom(
            NumberFormat.simpleCurrency(
              locale: locale,
              name: e.currency,
            ).format(e.priceMin),
          );
    final (String, Color)? badge = e.kind == EventKind.holiday
        ? (t.eventsStatusHoliday, NomadColors.money)
        : switch (e.status) {
            SaleStatus.onsale => (t.eventsStatusOnsale, NomadColors.flights),
            SaleStatus.offsale => (
              t.eventsStatusOffsale,
              const Color(0xFFFFD27A),
            ),
            SaleStatus.cancelled => (
              t.eventsStatusCancelled,
              const Color(0xFFFF6B6B),
            ),
            SaleStatus.rescheduled => (
              t.eventsStatusRescheduled,
              NomadColors.safety,
            ),
            null => null,
          };
    final DateTime? start = this.start;
    final Duration? left = start?.difference(DateTime.now());
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[Color(0xFF1D1636), Color(0xFF141E25)],
          ),
          border: Border.all(color: const Color(0xFF2E2650)),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // La columna de color con el día.
              Container(
                width: 70,
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.4, -0.6),
                    radius: 1.2,
                    colors: <Color>[color, color.withValues(alpha: 0.35)],
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Icon(eventIcon(e.kind), color: Colors.white),
                    Text(
                      DateFormat.E(locale).format(e.date).toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      '${e.date.day}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          if (badge != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 1,
                              ),
                              margin: const EdgeInsetsDirectional.only(end: 6),
                              decoration: BoxDecoration(
                                color: badge.$2,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                badge.$1,
                                style: const TextStyle(
                                  color: Color(0xFF120C24),
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              e.kind == EventKind.holiday
                                  ? 'Nager.Date'
                                  : 'Ticketmaster',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: NomadColors.textMuted,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: saved ? t.eventsUnsave : t.eventsSave,
                            visualDensity: VisualDensity.compact,
                            icon: AnimatedScale(
                              scale: saved ? 1.15 : 1,
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.elasticOut,
                              child: Icon(
                                saved
                                    ? Icons.favorite_rounded
                                    : Icons.favorite_border_rounded,
                                color: saved ? const Color(0xFFFF7AB6) : null,
                              ),
                            ),
                            onPressed: onSave,
                          ),
                        ],
                      ),
                      Text(
                        e.name,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      Text(
                        when,
                        style: const TextStyle(color: NomadColors.textMuted),
                      ),
                      if (fromHotel case final String h)
                        Text(
                          '🏨 $h',
                          style: const TextStyle(
                            color: NomadColors.mint,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      if (e.kind == EventKind.holiday)
                        Text(
                          e.regional
                              ? t.eventsHolidayRegional
                              : t.eventsHoliday,
                          style: const TextStyle(color: NomadColors.money),
                        ),
                      if (price != null)
                        Text(
                          price,
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Color(0xFFFFD27A),
                          ),
                        ),
                      if (left != null)
                        Text(
                          '⏱ ${left.isNegative ? t.eventsHappening : t.eventsStartsIn(_countdown(left))}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontFeatures: <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      if (onOpen != null || onPlans != null) ...<Widget>[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: <Widget>[
                            if (onOpen != null)
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(0, 32),
                                  backgroundColor: color,
                                  foregroundColor: const Color(0xFF120C24),
                                ),
                                onPressed: onOpen,
                                child: Text(t.eventsTickets),
                              ),
                            if (onPlans != null)
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 32),
                                ),
                                onPressed: planned ? null : onPlans,
                                child: Text(
                                  planned ? t.eventsInPlans : t.eventsToPlans,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
