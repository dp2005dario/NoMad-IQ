// Qué pasa en tus fechas: la maqueta "Eventos" tal cual
// (assets/events/eventos.html, dentro de un WebView). Festivos y eventos de
// la ciudad a la que vas:
//   1. El número grande de "cosas pasan en tus fechas".
//   2. "TUS DÍAS · TOCA UNO" y los tipos (Música, Fiestas, Deporte...).
//   3. Las tarjetas: estado de las entradas, cuenta atrás, "Entradas",
//      "+ Planes" (a "Elegid planes" del viaje en grupo) y el corazón (Flyra
//      te avisa la víspera y 2 horas antes).
//   4. "Dónde pasan": los pines a escala, con tu hotel en el punto azul.
//   5. El consejo de Flyra (si dos eventos coinciden el mismo día).
//
// Todo es real y con fuente: festivos oficiales (Nager.Date) y eventos
// publicados en Ticketmaster, con el precio que pone el organizador si lo
// pone. Tocando la ciudad y las fechas (arriba) se cambian, y tu hotel se
// marca tocando el mapa.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:timezone/data/latest_10y.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../map/geo.dart';
import '../stays/pick_point_screen.dart';
import '../flights/flights_page.dart' show unpackJson;
import '../flights/origin_sheet.dart';
import '../route/geo.dart' show LatLon;
import '../route/web_scene.dart';
import 'events_page.dart';
import '../group/group_api.dart';
import '../plans/plans_api.dart';
import '../route/world_data.dart';
import 'event_reminders.dart';
import 'hotel_sheet.dart';
import 'events_api.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key, this.iata});

  /// El aeropuerto de la ciudad (si no, el destino del Modo fácil).
  final String? iata;

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = EventsScreen.lastBridge = WebSceneBridge();

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;
  String? _html;
  String? _sent;

  /// Lo que la página debe enseñar una vez (un aviso).
  Map<String, Object?> _once = <String, Object?>{};
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

  /// La zona horaria de la ciudad ("Europe/Lisbon"), para la cuenta atrás.
  tz.Location? _zone;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(eventsPage, cache: false);
    } on Object {
      return;
    }
    if (!mounted) return;
    setState(() {});
    // Sin ciudad (no hay viaje guardado): se pregunta al momento, por su
    // nombre, en vez de dejar la pantalla vacía.
    if (_iata == null) {
      await _pickCity();
      return;
    }
    await _load();
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
    setState(() => (_loading = true, _error = null));
    unawaited(_findZone(iata));
    try {
      final CityEvents found = await _services.events.between(
        iata,
        _dates.start,
        _dates.end,
      );
      if (!mounted) return;
      // La cuenta atrás la lleva la página (cada segundo).
      setState(() => (_found = found, _loading = false));
    } on ApiException catch (e) {
      if (mounted) setState(() => (_error = e.error, _loading = false));
    }
  }

  Future<void> _pickCity() async {
    final String? code = await showOriginSheet(
      context,
      current: _iata ?? '',
      title: AppLocalizations.of(context).eventsPickCity,
    );
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
    // Como mucho los días que caben en la fila de la maqueta.
    final DateTime end =
        range.end.difference(range.start).inDays >= maxEventDays
        ? range.start.add(const Duration(days: maxEventDays - 1))
        : range.end;
    setState(() => _dates = DateTimeRange(start: range.start, end: end));
    await _load();
  }

  /// Un aviso abajo (lo dibuja la página).
  void _say(String text) =>
      setState(() => _once = <String, Object?>{..._once, 'toast': text});

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

  /// El corazón: [adding] = guardarlo (el aviso lo enseña la página).
  Future<void> _setSaved(CityEvent e, bool adding) async {
    final AppLocalizations t = AppLocalizations.of(context);
    if (adding == _saved.contains(e.id)) return;
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
    await context.push(
      Routes.groupPlans(group.id, city: _found?.city, iata: _iata),
    );
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

  /// Dónde empezar a buscar tu hotel: el que tenías, el centro de los
  /// eventos o el aeropuerto de la ciudad.
  Future<GeoPoint?> _around() async {
    if (_hotel case final GeoPoint h) return h;
    final List<CityEvent> pins = <CityEvent>[
      for (final CityEvent e in _found?.events ?? const <CityEvent>[])
        if (e.lat != null && e.lon != null) e,
    ];
    if (pins.isNotEmpty) return _centerOf(pins);
    final String? iata = _iata;
    if (iata == null) return null;
    try {
      final Airports all = await _services.loadAirports();
      final LatLon? p = all[iata]?.position;
      return p == null ? null : GeoPoint(p.lat, p.lon);
    } on Object {
      return null;
    }
  }

  Future<void> _hotelHere() async {
    final GeoPoint? around = await _around();
    if (around != null && mounted) await _pickHotel(around);
  }

  /// Tocando la ciudad y las fechas: cambiar la ciudad, las fechas o
  /// dónde está tu hotel.
  Future<void> _options() async {
    if (_iata == null) {
      await _pickCity();
      return;
    }
    final AppLocalizations t = AppLocalizations.of(context);
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    final int? pick = await showModalBottomSheet<int>(
      context: context,
      useRootNavigator: true,
      builder: (BuildContext sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.location_city_rounded),
              title: Text(t.eventsPickCity),
              onTap: () => Navigator.of(sheet).pop(0),
            ),
            ListTile(
              leading: const Icon(Icons.date_range_rounded),
              title: Text(m.dateRangePickerHelpText),
              onTap: () => Navigator.of(sheet).pop(1),
            ),
            ListTile(
              leading: const Icon(Icons.hotel_rounded),
              title: Text(
                _hotel == null ? t.eventsSetHotel : t.eventsChangeHotel,
              ),
              onTap: () => Navigator.of(sheet).pop(2),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (pick) {
      case 0:
        await _pickCity();
      case 1:
        await _pickDates();
      case 2:
        await _hotelHere();
    }
  }

  CityEvent? _event(Object? id) =>
      _found?.events.where((CityEvent e) => e.id == id).firstOrNull;

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final Map<String, Object?> data =
        (p.length == 3 ? unpackJson(p[2]) : null) ?? const <String, Object?>{};
    final CityEvent? e = _event(data['id']);
    final Uri? url = Uri.tryParse('${data['u'] ?? ''}');
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'options':
        unawaited(_options());
      case 'hotel':
        unawaited(_hotelHere());
      case 'save' when e != null && n != null:
        unawaited(_setSaved(e, n == 1));
      case 'plan' when e != null:
        unawaited(_toPlans(e));
      // Solo los enlaces de Ticketmaster de los eventos (siempre https).
      case 'open'
          when url != null &&
              (_found?.events.any((CityEvent x) => x.url == url) ?? false):
        unawaited(_services.openBooking(url));
      case 'vote':
        unawaited(_openVote());
    }
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
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final CityEvents? found = _found;
    final Map<String, Object?> data = <String, Object?>{
      ...eventsPageData(
        iata: _iata,
        from: _dates.start,
        to: _dates.end,
        found: found,
        loading: _loading,
        offline: _error == ApiError.network,
        failed: _error != null && _error != ApiError.network,
        saved: _saved,
        planned: _planned,
        hotel: _hotel,
        startOf: _startOf,
        tip: found == null ? null : _tip(t, found.events, locale),
      ),
      ..._once,
    };
    final String push = eventsPushScript(data);
    if (_html == null) {
      _html = eventsPageWith(page, data);
      _sent = push;
      _once = <String, Object?>{};
    } else if (push != _sent) {
      _sent = push;
      _once = <String, Object?>{};
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
}
