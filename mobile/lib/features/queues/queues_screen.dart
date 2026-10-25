// Sin colas (maqueta "Colas"): cuánta cola hay en los sitios famosos de la
// ciudad y a qué hora suele haber menos, más una lista de restaurantes
// cercanos que aceptan reserva.
//
// REGLA: nada inventado. En la maqueta salían barras de afluencia "de
// Google", un "turno virtual" y reservar mesa desde la app. Nada de eso
// existe gratis y de forma honrada para todo el mundo, así que:
//   - Las esperas son las que AVISAN los viajeros que están allí (con un
//     mínimo de personas). Si no hay avisos, se dice tal cual.
//   - El "turno" es un recordatorio del móvil (lo decimos claro).
//   - Los restaurantes son los que en OpenStreetMap dicen que aceptan
//     reserva; se reserva en SU web o llamando (la app no cobra ni reserva).
//   - Un botón abre el sitio en Google Maps, que a veces enseña la afluencia
//     en directo (eso lo pone Google, no nosotros).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_mode.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../nearby/nearby_api.dart';
import '../route/geo.dart' show LatLon;
import '../route/places_api.dart';
import '../route/world_data.dart';
import '../sos/sos_store.dart' show telUri;
import '../sos/where_am_i.dart' show nearestAirport;
import 'queues_api.dart';

String waitLabel(AppLocalizations t, WaitLevel w) => switch (w) {
  WaitLevel.none => t.queuesWaitNone,
  WaitLevel.short => t.queuesWaitShort,
  WaitLevel.medium => t.queuesWaitMedium,
  WaitLevel.long => t.queuesWaitLong,
  WaitLevel.veryLong => t.queuesWaitVeryLong,
};

Color waitColor(WaitLevel w) => switch (w) {
  WaitLevel.none || WaitLevel.short => NomadColors.mint,
  WaitLevel.medium => NomadColors.money,
  WaitLevel.long || WaitLevel.veryLong => NomadColors.safety,
};

/// Los avisos del "recuérdamelo" usan estos números (uno por sitio a la vez).
const int _reminderId = 7400;

class QueuesScreen extends StatefulWidget {
  const QueuesScreen({super.key, this.city});

  final String? city;

  @override
  State<QueuesScreen> createState() => _QueuesScreenState();
}

class _QueuesScreenState extends State<QueuesScreen> {
  late final AppServices _services = ServicesScope.of(context);

  bool _locating = true;
  GeoPoint? _here;
  String? _city;

  List<Attraction>? _places;
  bool _placesFailed = false;
  int _picked = 0;

  PlaceQueue? _queue;
  ApiError? _queueError;

  NearbyList? _tables;
  bool _tablesFailed = false;

  @override
  void initState() {
    super.initState();
    _city = widget.city?.toUpperCase();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  String get _lang => Localizations.localeOf(context).languageCode;

  Future<void> _start() async {
    final LocationSource gps = _services.location;
    LocationAccess access = await gps.check();
    if (access == LocationAccess.denied) access = await gps.request();
    if (access == LocationAccess.granted) {
      try {
        final PositionFix fix = await gps.watch().first.timeout(
          const Duration(seconds: 10),
        );
        _here = fix.point;
        if (_city == null) {
          final Airports airports = await _services.loadAirports();
          final Airport? a = nearestAirport(
            airports.all,
            LatLon(fix.point.lat, fix.point.lon),
          );
          // La ciudad = la del aeropuerto más cercano (a menos de 80 km).
          if (a != null &&
              fix.point.distanceTo(GeoPoint(a.position.lat, a.position.lon)) <
                  80000) {
            _city = a.iata;
          }
        }
      } on Object {
        // Sin GPS a tiempo: seguimos con la ciudad del viaje (si hay).
      }
    }
    // Sin GPS: el destino del viaje del Modo fácil.
    _city ??= loadEasyTrip(_services.prefs).to;
    if (!mounted) return;
    setState(() => _locating = false);
    await Future.wait(<Future<void>>[_loadPlaces(), _loadTables()]);
  }

  Future<void> _loadPlaces() async {
    final String? city = _city;
    if (city == null) return;
    try {
      final PlaceCard? card = await _services.places.get(city, _lang);
      if (!mounted) return;
      setState(
        () => _places = <Attraction>[
          for (final Attraction a in card?.attractions ?? <Attraction>[])
            if (a.wikidataId != null) a,
        ].take(8).toList(),
      );
      await _loadQueue();
    } on ApiException {
      if (mounted) setState(() => _placesFailed = true);
    }
  }

  Attraction? get _place {
    final List<Attraction>? places = _places;
    if (places == null || places.isEmpty) return null;
    return places[_picked.clamp(0, places.length - 1)];
  }

  Future<void> _loadQueue() async {
    final String? qid = _place?.wikidataId;
    if (qid == null) return;
    setState(() => (_queue = null, _queueError = null));
    try {
      final PlaceQueue q = await _services.queues.place(
        qid,
        DateTime.now().hour,
      );
      if (mounted && _place?.wikidataId == qid) setState(() => _queue = q);
    } on ApiException catch (e) {
      if (mounted) setState(() => _queueError = e.error);
    }
  }

  Future<void> _loadTables() async {
    final GeoPoint? here = _here;
    if (here == null) return;
    try {
      final NearbyList list = await _services.nearby.near(here);
      if (mounted) setState(() => _tables = list);
    } on ApiException {
      if (mounted) setState(() => _tablesFailed = true);
    }
  }

  Future<void> _report(WaitLevel w) async {
    final String? qid = _place?.wikidataId;
    if (qid == null) return;
    try {
      await _services.queues.report(qid, DateTime.now().hour, w);
      _snack((AppLocalizations t) => t.queuesThanks);
      await _loadQueue();
    } on ApiException catch (e) {
      _snack(
        (AppLocalizations t) => e.error == ApiError.rateLimited
            ? t.radarTooMany
            : t.radarSendFailed,
      );
    }
  }

  Future<void> _remind(Attraction place, int hour) async {
    final DateTime now = DateTime.now();
    final DateTime at = DateTime(
      now.year,
      now.month,
      now.day,
      hour,
    ).subtract(const Duration(minutes: 10));
    if (!at.isAfter(now)) return;
    final AppLocalizations t = AppLocalizations.of(context);
    final String time = DateFormat.Hm(_lang).format(at);
    await _services.reminders.schedule(
      id: _reminderId,
      at: at,
      title: place.name,
      body: t.queuesReminderBody(place.name),
      channelName: t.queuesReminderChannel,
      route: Routes.queues(city: _city),
    );
    _snack((AppLocalizations t) => t.queuesReminderSet(time));
  }

  // Recibe una función que elige el texto, para no leer el contexto antes
  // de comprobar que la pantalla sigue abierta.
  void _snack(String Function(AppLocalizations t) text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text(AppLocalizations.of(context)))),
      );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(t.queuesTitle)),
      body: _locating
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
              children: <Widget>[
                Text(
                  t.queuesSubtitle,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
                const SizedBox(height: 16),
                ..._placesSection(t),
                const SizedBox(height: 24),
                Text(t.queuesTablesTitle, style: text.titleMedium),
                const SizedBox(height: 6),
                ..._tablesSection(t),
              ],
            ),
    );
  }

  List<Widget> _placesSection(AppLocalizations t) {
    if (_city == null) return <Widget>[Text(t.queuesNoCity)];
    if (_placesFailed) return <Widget>[Text(t.radarSendFailed)];
    final List<Attraction>? places = _places;
    if (places == null) return <Widget>[const LinearProgressIndicator()];
    if (places.isEmpty) return <Widget>[Text(t.queuesNoPlaces)];
    final Attraction place = _place!;
    return <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (int i = 0; i < places.length; i++)
            ChoiceChip(
              label: Text(places[i].name),
              selected: i == _picked,
              onSelected: (_) {
                setState(() => _picked = i);
                unawaited(_loadQueue());
              },
            ),
        ],
      ),
      const SizedBox(height: 12),
      _queueCard(t, place),
    ];
  }

  Widget _queueCard(AppLocalizations t, Attraction place) {
    final Widget body;
    if (_queueError == ApiError.signedOut) {
      body = Text(t.queuesSignIn);
    } else if (_queueError != null) {
      body = Text(t.radarSendFailed);
    } else if (_queue == null) {
      body = const LinearProgressIndicator();
    } else {
      body = _queueBody(t, place, _queue!);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            body,
            const SizedBox(height: 6),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                icon: const Icon(Icons.map_rounded),
                label: Text(t.queuesSeeMaps),
                // Google Maps a veces enseña la afluencia en directo (es suya).
                onPressed: () => unawaited(
                  _services.openBooking(
                    Uri.https(
                      'www.google.com',
                      '/maps/search/',
                      <String, String>{'api': '1', 'query': place.name},
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _queueBody(AppLocalizations t, Attraction place, PlaceQueue q) {
    final WaitNow? now = q.now;
    final int hourNow = DateTime.now().hour;
    final WaitHour? best = q.bestFrom(hourNow + 1);
    final Map<int, WaitHour> byHour = <int, WaitHour>{
      for (final WaitHour h in q.hours) h.hour: h,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (now != null) ...<Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: waitColor(now.wait),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              waitLabel(t, now.wait),
              style: const TextStyle(
                color: NomadColors.background,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.queuesNowBy(now.reporters, now.minutesAgo),
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        ] else
          Text(t.queuesNowUnknown),
        const SizedBox(height: 14),
        if (q.hours.isEmpty)
          Text(
            t.queuesNoHours,
            style: const TextStyle(color: NomadColors.textMuted),
          )
        else ...<Widget>[
          SizedBox(
            height: 76,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                for (int h = 8; h <= 22; h++)
                  Expanded(
                    child: _HourBar(
                      hour: h,
                      data: byHour[h],
                      now: h == hourNow,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.queuesHoursNote,
            style: const TextStyle(fontSize: 11, color: NomadColors.textMuted),
          ),
          if (best != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              t.queuesBest('${best.hour}:00', waitLabel(t, best.wait)),
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              icon: const Icon(Icons.alarm_add_rounded),
              label: Text(t.queuesRemindMe('${best.hour}:00')),
              onPressed: () => unawaited(_remind(place, best.hour)),
            ),
            Text(
              t.queuesReminderNote,
              style: const TextStyle(
                fontSize: 11,
                color: NomadColors.textMuted,
              ),
            ),
          ],
        ],
        const SizedBox(height: 14),
        Text(
          q.reportedThisHour ? t.queuesReported : t.queuesAskNow,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final WaitLevel w in WaitLevel.values)
              ActionChip(
                label: Text(waitLabel(t, w)),
                onPressed: () => unawaited(_report(w)),
              ),
          ],
        ),
      ],
    );
  }

  List<Widget> _tablesSection(AppLocalizations t) {
    final GeoPoint? here = _here;
    if (here == null) return <Widget>[Text(t.queuesTablesNoLocation)];
    if (_tablesFailed) return <Widget>[Text(t.radarSendFailed)];
    final NearbyList? list = _tables;
    if (list == null) return <Widget>[const LinearProgressIndicator()];
    final List<NearbySpot> tables = list
        .of(NearbyKind.table, here)
        .take(10)
        .toList();
    return <Widget>[
      if (tables.isEmpty)
        Text(t.queuesNoTables)
      else
        for (final NearbySpot s in tables)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.restaurant_rounded),
            title: Text(s.name ?? ''),
            subtitle: Text(
              <String>[
                if (s.cuisine != null) s.cuisine!.replaceAll('_', ' '),
                t.nearbyMeters(here.distanceTo(s.point).round()),
                if (s.reservationRequired) t.queuesReservationRequired,
              ].join(' · '),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (s.website != null)
                  IconButton(
                    tooltip: t.queuesBookWeb,
                    icon: const Icon(Icons.language_rounded),
                    onPressed: () =>
                        unawaited(_services.openBooking(s.website!)),
                  ),
                if (s.phone != null)
                  IconButton(
                    tooltip: t.queuesCall,
                    icon: const Icon(Icons.call_rounded),
                    onPressed: () =>
                        unawaited(_services.openLink(telUri(s.phone!))),
                  ),
              ],
            ),
          ),
      const SizedBox(height: 6),
      Text(
        '${t.queuesTablesNote} ${list.attribution}',
        style: const TextStyle(fontSize: 11, color: NomadColors.textMuted),
      ),
    ];
  }
}

class _HourBar extends StatelessWidget {
  const _HourBar({required this.hour, required this.data, required this.now});

  final int hour;
  final WaitHour? data;
  final bool now;

  @override
  Widget build(BuildContext context) {
    final WaitHour? d = data;
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 2),
          // Sin avisos en esa hora: una raya gris (no nos inventamos nada).
          height: d == null ? 3 : 10 + d.wait.index * 12,
          decoration: BoxDecoration(
            color: d == null ? NomadColors.outline : waitColor(d.wait),
            borderRadius: BorderRadius.circular(3),
            border: now
                ? Border.all(color: NomadColors.text, width: 1.5)
                : null,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '$hour',
          style: TextStyle(
            fontSize: 10,
            fontWeight: now ? FontWeight.w800 : FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
