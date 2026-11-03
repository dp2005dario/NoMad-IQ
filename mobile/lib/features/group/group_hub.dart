// La pantalla Grupo cuando ya hay destino (maqueta 7, "Viaje en grupo").
//
// Debajo del resultado de la negociación van, como en la maqueta:
//   - Atajos: chat, bote común, elegir planes y cromos.
//   - "Gustos de cada uno": cada uno marca los suyos y TODOS los ven.
//   - "Así lo busca Flyra": los 4 pasos (gustos, zona, dormir, eventos).
//   - "Votad dónde dormir": dos zonas reales de OpenStreetMap; cuando todos
//     votan la misma, confeti y el enlace a Booking.
//   - "De dónde saca Flyra los datos" y "Cómo elige sitios cerca".
//   - "¿Qué os apetece?": un antojo, sitios reales a un paseo, "Me apetece /
//     Paso" (lo ve el grupo) y la hora dorada calculada con el sol.
//
// Nada de esto usa IA ni datos inventados: si algo no se encuentra, se dice.
// Lo que NO hay (y por qué): precios de hoteles y de sitios (no hay fuente
// gratis fiable) y quién votó qué (los votos son secretos, solo cuántos).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../map/geo.dart';
import '../map/geocode_api.dart';
import '../map/location.dart';
import '../money/money_screen.dart' show MoneyTab;
import '../plans/plans_api.dart';
import '../stays/stays_api.dart';
import '../stays/stays_math.dart';
import 'cravings_api.dart';
import 'group_api.dart';
import 'group_widgets.dart';
import 'sun.dart';

/// El nombre de un gusto en el idioma de cada uno.
String tasteLabel(AppLocalizations t, String id) => switch (id) {
  'tapas' => t.tasteTapas,
  'music' => t.tasteMusic,
  'views' => t.tasteViews,
  'fish' => t.tasteFish,
  'veggie' => t.tasteVeggie,
  'late' => t.tasteLate,
  _ => tagLabel(t, id),
};

/// "O contándoselo a Flyra en el chat": los gustos que se nombran en un
/// mensaje, por palabras clave (sin IA). Vale el nombre del gusto en tu
/// idioma ("pescado", "museos") y unas pocas palabras que se dicen igual en
/// casi todos (fado, jazz, sushi...).
List<String> tastesInText(AppLocalizations t, String text) {
  final String low = text.toLowerCase();
  const Map<String, List<String>> universal = <String, List<String>>{
    'music': <String>['fado', 'jazz', 'flamenco', 'tango', 'karaoke'],
    'fish': <String>['sushi', 'marisco', 'seafood'],
    'veggie': <String>['vegan', 'vegano', 'vegana'],
    'beach': <String>['playa', 'beach'],
  };
  return <String>[
    for (final String id in tasteIds)
      if (low.contains(tasteLabel(t, id).toLowerCase()) ||
          (universal[id] ?? const <String>[]).any(
            (String w) => RegExp('\\b$w\\b').hasMatch(low),
          ))
        id,
  ];
}

String cravingLabel(AppLocalizations t, Craving c) => switch (c) {
  Craving.tapas => t.tasteTapas,
  Craving.fish => t.tasteFish,
  Craving.veggie => t.tasteVeggie,
  Craving.cafe => t.craveCafe,
  Craving.views => t.tasteViews,
};

/// El gusto que encaja con cada antojo (para "Encaja con Marta").
String? tasteOfCraving(Craving c) => switch (c) {
  Craving.tapas => 'tapas',
  Craving.fish => 'fish',
  Craving.veggie => 'veggie',
  Craving.views => 'views',
  Craving.cafe => null,
};

/// Los gustos del grupo de más a menos repetidos (para el paso 1).
List<(String, int)> topTastes(List<TripMember> members) {
  final Map<String, int> count = <String, int>{};
  for (final TripMember m in members) {
    for (final String id in m.tastes) {
      count[id] = (count[id] ?? 0) + 1;
    }
  }
  final List<(String, int)> out = <(String, int)>[
    for (final MapEntry<String, int> e in count.entries) (e.key, e.value),
  ];
  // Más votos primero; a igualdad, el orden de los chips.
  out.sort(
    ((String, int) a, (String, int) b) => a.$2 != b.$2
        ? b.$2.compareTo(a.$2)
        : tasteIds.indexOf(a.$1).compareTo(tasteIds.indexOf(b.$1)),
  );
  return out;
}

/// El antojo con el que se abre "¿Qué os apetece?": el del gusto más
/// repetido del grupo, o tapas.
Craving firstCraving(List<TripMember> members) {
  for (final (String id, int _) in topTastes(members)) {
    for (final Craving c in Craving.values) {
      if (tasteOfCraving(c) == id) return c;
    }
  }
  return Craving.tapas;
}

/// El orden de los sitios: cercanía + lo que el grupo vota. Cada "Me
/// apetece" del grupo acerca el sitio 250 m; si tú dijiste "Paso", al final.
List<CravingSpot> rankSpots(
  List<CravingSpot> spots,
  GeoPoint from,
  Map<String, GroupPlan> votes,
) {
  double score(CravingSpot s) {
    final GroupPlan? p = votes[s.name.toLowerCase()];
    final double d = from.distanceTo(s.point);
    if (p?.myVote == false) return d + 100000;
    return d - 250 * (p?.yes ?? 0);
  }

  return <CravingSpot>[
    for (final CravingSpot s in spots)
      if (from.distanceTo(s.point) <= cravingRadiusM) s,
  ]..sort((CravingSpot a, CravingSpot b) => score(a).compareTo(score(b)));
}

class TripHub extends StatefulWidget {
  const TripHub({super.key, required this.trip, required this.onTrip});

  final GroupTrip trip;

  /// Cuando cambian tus gustos, el viaje nuevo (para repintar arriba).
  final void Function(GroupTrip) onTrip;

  @override
  State<TripHub> createState() => _TripHubState();
}

class _TripHubState extends State<TripHub> {
  late final AppServices _services = ServicesScope.of(context);
  bool _started = false;

  /// El destino en el mapa (null mientras se busca; [_noCity] si no está).
  GeoPoint? _city;
  bool _noCity = false;

  /// Tu GPS, solo si ya diste permiso y estás en la ciudad (a 30 km).
  GeoPoint? _here;
  List<StayZone>? _zones;
  bool _zonesFailed = false;
  PlanBoard? _board;
  late Craving _crave = firstCraving(widget.trip.members);
  List<CravingSpot>? _spots;
  bool _spotsFailed = false;
  bool _savingTastes = false;
  bool _voting = false;

  /// Qué pestaña de "Gustos de cada uno" se ve (0 = la primera persona).
  int _who = 0;
  DateTimeRange? _dates;

  String get _cityName =>
      widget.trip.option(widget.trip.result?.chosenOptionId)?.label ??
      widget.trip.title;

  GeoPoint? get _center => _here ?? _city;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final int mine = widget.trip.members.indexWhere((TripMember m) => m.me);
    _who = mine < 0 ? 0 : mine;
    unawaited(_load());
  }

  Future<void> _load() async {
    unawaited(_loadBoard());
    try {
      final List<GeoPlace> found = await _services.geocode.search(_cityName);
      if (!mounted) return;
      if (found.isEmpty) {
        setState(() => _noCity = true);
        return;
      }
      setState(() => _city = found.first.point);
    } on ApiException {
      if (mounted) setState(() => _noCity = true);
      return;
    }
    await _locate();
    await Future.wait(<Future<void>>[_loadZones(), _loadSpots()]);
  }

  /// Sin preguntar nada: si ya hay permiso y estás en la ciudad, se usa tu
  /// GPS ("Dónde estás"); si no, el centro de la ciudad.
  Future<void> _locate() async {
    final GeoPoint? city = _city;
    if (city == null) return;
    try {
      final LocationSource gps = _services.location;
      if (await gps.check() != LocationAccess.granted) return;
      final PositionFix? fix = await gps.current();
      if (fix != null && fix.point.distanceTo(city) <= 30000 && mounted) {
        setState(() => _here = fix.point);
      }
    } on Object {
      // Sin GPS no pasa nada: se usa el centro de la ciudad.
    }
  }

  Future<void> _loadZones() async {
    final GeoPoint? city = _city;
    if (city == null) return;
    try {
      final StayArea area = await _services.stays.around(city);
      if (mounted) setState(() => _zones = area.zones.take(2).toList());
    } on ApiException {
      if (mounted) setState(() => _zonesFailed = true);
    }
  }

  Future<void> _loadSpots() async {
    final GeoPoint? at = _center;
    if (at == null) return;
    final Craving asked = _crave;
    setState(() => (_spots = null, _spotsFailed = false));
    try {
      final List<CravingSpot> spots = await _services.cravings.near(at, asked);
      if (mounted && asked == _crave) setState(() => _spots = spots);
    } on ApiException {
      if (mounted && asked == _crave) setState(() => _spotsFailed = true);
    }
  }

  Future<void> _loadBoard() async {
    try {
      final PlanBoard board = await _services.plans.board(widget.trip.id);
      if (mounted) setState(() => _board = board);
    } on ApiException {
      // Sin tablero se ven los sitios igual; los votos, al reintentar.
    }
  }

  void _error(ApiException e) {
    if (!mounted) return;
    final AppLocalizations t = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          e.error == ApiError.network ? t.errorNetwork : t.errorUnavailable,
        ),
      ),
    );
  }

  Future<void> _toggleTaste(String id) async {
    final TripMember? me = widget.trip.me;
    if (me == null || _savingTastes) return;
    final List<String> next = me.tastes.contains(id)
        ? <String>[
            for (final String x in me.tastes)
              if (x != id) x,
          ]
        : <String>[...me.tastes, id];
    setState(() => _savingTastes = true);
    try {
      widget.onTrip(await _services.group.setTastes(widget.trip.id, next));
    } on ApiException catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _savingTastes = false);
    }
  }

  /// El voto de un sitio o zona: si aún no está en el tablero, se añade
  /// (el servidor no lo repite) y luego se vota.
  Future<void> _vote(List<NewPlan> ensure, Map<String, bool> votes) async {
    if (_voting) return;
    setState(() => _voting = true);
    try {
      PlanBoard board = _board ?? await _services.plans.board(widget.trip.id);
      bool missing(NewPlan p) => _find(board, p.kind, p.title) == null;
      if (ensure.any(missing)) {
        board = await _services.plans.add(widget.trip.id, ensure);
      }
      for (final MapEntry<String, bool> v in votes.entries) {
        final GroupPlan? plan = _find(board, ensure.first.kind, v.key);
        if (plan == null || plan.myVote == v.value) continue;
        board = await _services.plans.vote(
          widget.trip.id,
          plan.id,
          yes: v.value,
        );
      }
      if (mounted) setState(() => _board = board);
    } on ApiException catch (e) {
      _error(e);
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  static GroupPlan? _find(PlanBoard? board, PlanKind kind, String title) {
    if (board == null) return null;
    final String key = title.toLowerCase();
    for (final GroupPlan p in board.extras) {
      if (p.kind == kind && p.title.toLowerCase() == key) return p;
    }
    return null;
  }

  String _zoneTitle(AppLocalizations t, StayZone z) =>
      z.name ?? t.sleepZoneCenter(_cityName);

  Future<void> _voteSleep(StayZone chosen) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<StayZone> zones = _zones ?? const <StayZone>[];
    await _vote(
      <NewPlan>[
        for (final StayZone z in zones)
          NewPlan(title: _zoneTitle(t, z), kind: PlanKind.sleep),
      ],
      <String, bool>{
        for (final StayZone z in zones) _zoneTitle(t, z): z.id == chosen.id,
      },
    );
  }

  Future<void> _voteSpot(CravingSpot spot, {required bool yes}) => _vote(
    <NewPlan>[
      NewPlan(
        title: spot.name,
        note: cravingLabel(AppLocalizations.of(context), _crave),
        kind: PlanKind.crave,
      ),
    ],
    <String, bool>{spot.name: yes},
  );

  /// "Abrir Booking": con las fechas que elijas y todo el grupo.
  Future<void> _openBooking(GeoPoint at) async {
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 500)),
      initialDateRange: _dates,
    );
    if (range == null || !mounted) return;
    final DateTimeRange dates = range.duration.inDays < 1
        ? DateTimeRange(
            start: range.start,
            end: range.start.add(const Duration(days: 1)),
          )
        : range;
    setState(() => _dates = dates);
    unawaited(
      _services.openBooking(
        bookingSearch(
          at: at,
          checkIn: dates.start,
          checkOut: dates.end,
          adults: math.max(1, widget.trip.members.length),
          language: Localizations.localeOf(context).languageCode,
          affiliateId: AppConfig.bookingAffiliateId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final GroupTrip trip = widget.trip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Shortcuts(trip: trip, city: _cityName),
        const SizedBox(height: 20),
        _Card(
          title: t.tastesTitle,
          subtitle: t.tastesSubtitle,
          child: _Tastes(
            trip: trip,
            who: _who,
            busy: _savingTastes,
            onWho: (int i) => setState(() => _who = i),
            onToggle: (String id) => unawaited(_toggleTaste(id)),
          ),
        ),
        const SizedBox(height: 16),
        _Card(
          title: t.hubStepsTitle,
          child: _Steps(
            trip: trip,
            city: _cityName,
            zones: _zones,
            onBooking: _city == null
                ? null
                : () => unawaited(
                    _openBooking(_zones?.firstOrNull?.point ?? _city!),
                  ),
          ),
        ),
        const SizedBox(height: 16),
        _Card(
          title: t.sleepTitle,
          subtitle: t.sleepSubtitle,
          child: _noCity
              ? _Muted(t.hubNoCity(_cityName))
              : _zonesFailed
              ? _Muted(t.errorUnavailable)
              : _zones == null
              ? const _Loading()
              : _zones!.isEmpty
              ? _Muted(t.sleepNoZones)
              : _SleepVote(
                  zones: _zones!,
                  members: _board?.members ?? trip.members.length,
                  titleOf: (StayZone z) => _zoneTitle(t, z),
                  planOf: (StayZone z) =>
                      _find(_board, PlanKind.sleep, _zoneTitle(t, z)),
                  busy: _voting,
                  onVote: (StayZone z) => unawaited(_voteSleep(z)),
                  onBook: (StayZone z) => unawaited(_openBooking(z.point)),
                ),
        ),
        const SizedBox(height: 16),
        _Card(title: t.sourcesTitle, child: const _Sources()),
        const SizedBox(height: 16),
        _Card(
          title: t.nearHowTitle,
          child: _HowNearby(city: _cityName, gps: _here != null),
        ),
        const SizedBox(height: 16),
        _Card(
          title: t.craveTitle,
          subtitle: t.craveSubtitle,
          child: _Cravings(
            crave: _crave,
            onCrave: (Craving c) {
              if (c == _crave) return;
              setState(() => _crave = c);
              unawaited(_loadSpots());
            },
            noCity: _noCity,
            failed: _spotsFailed,
            spots: switch ((_spots, _center)) {
              (final List<CravingSpot> s, final GeoPoint at) => rankSpots(
                s,
                at,
                <String, GroupPlan>{
                  for (final GroupPlan p
                      in _board?.extras ?? const <GroupPlan>[])
                    if (p.kind == PlanKind.crave) p.title.toLowerCase(): p,
                },
              ).take(5).toList(),
              _ => null,
            },
            from: _center,
            members: trip.members,
            planOf: (CravingSpot s) => _find(_board, PlanKind.crave, s.name),
            total: _board?.members ?? trip.members.length,
            busy: _voting,
            onVote: (CravingSpot s, bool yes) =>
                unawaited(_voteSpot(s, yes: yes)),
            golden: _city == null ? null : goldenHour(DateTime.now(), _city!),
          ),
        ),
      ],
    );
  }
}

/// Una tarjeta de sección con su título (y subtítulo) como en la maqueta.
class _Card extends StatelessWidget {
  const _Card({required this.title, required this.child, this.subtitle});

  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: NomadColors.surface,
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: NomadColors.outline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17),
        ),
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style: const TextStyle(color: NomadColors.textMuted, fontSize: 12),
          ),
        ],
        const SizedBox(height: 12),
        child,
      ],
    ),
  );
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(color: NomadColors.textMuted, fontSize: 13),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(12),
    child: Center(
      child: SizedBox.square(
        dimension: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
    ),
  );
}

/// Los cuatro atajos de la cabecera de la maqueta.
class _Shortcuts extends StatelessWidget {
  const _Shortcuts({required this.trip, required this.city});

  final GroupTrip trip;
  final String city;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    Widget item(IconData icon, String label, Color color, String route) =>
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => context.push(route),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: <Widget>[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: color.withValues(alpha: 0.5)),
                    ),
                    child: Icon(icon, color: color),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        item(
          Icons.forum_rounded,
          t.chatTitle,
          NomadColors.group,
          Routes.groupChat(trip.id),
        ),
        item(
          Icons.savings_rounded,
          t.kittyName,
          NomadColors.money,
          Routes.money(tab: MoneyTab.kitty),
        ),
        item(
          Icons.swipe_rounded,
          t.plansOpen,
          NomadColors.mint,
          Routes.groupPlans(trip.id, city: city),
        ),
        item(
          Icons.style_rounded,
          t.cardsTitle,
          NomadColors.flights,
          Routes.cards,
        ),
      ],
    );
  }
}

/// "Gustos de cada uno": una pestaña por persona; los tuyos se tocan.
class _Tastes extends StatelessWidget {
  const _Tastes({
    required this.trip,
    required this.who,
    required this.busy,
    required this.onWho,
    required this.onToggle,
  });

  final GroupTrip trip;
  final int who;
  final bool busy;
  final void Function(int) onWho;
  final void Function(String) onToggle;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<TripMember> members = trip.members;
    if (members.isEmpty) return const SizedBox.shrink();
    final int index = who.clamp(0, members.length - 1);
    final TripMember person = members[index];
    final Color color = faceColor(index);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (int i = 0; i < members.length; i++)
              ChoiceChip(
                selected: i == index,
                onSelected: (_) => onWho(i),
                avatar: CircleAvatar(backgroundColor: faceColor(i), radius: 6),
                label: Text(memberName(t, members[i])),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final String id in tasteIds)
              if (person.me || person.tastes.contains(id))
                FilterChip(
                  selected: person.tastes.contains(id),
                  selectedColor: color.withValues(alpha: 0.22),
                  checkmarkColor: color,
                  side: BorderSide(
                    color: person.tastes.contains(id)
                        ? color
                        : NomadColors.outline,
                  ),
                  label: Text(tasteLabel(t, id)),
                  onSelected: person.me && !busy ? (_) => onToggle(id) : null,
                ),
          ],
        ),
        if (!person.me && person.tastes.isEmpty) _Muted(t.tastesNone),
        const SizedBox(height: 8),
        _Muted(
          person.me
              ? t.tastesHintMine
              : t.tastesHintOther(memberName(t, person)),
        ),
        const SizedBox(height: 12),
        Text(
          t.tastesChatTitle,
          style: const TextStyle(
            color: NomadColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const FlyraAvatar(size: 28),
            const SizedBox(width: 8),
            Expanded(child: Text(t.tastesChatExample)),
          ],
        ),
        const SizedBox(height: 8),
        _Muted(t.tastesNoAi),
      ],
    );
  }
}

/// "Así lo busca Flyra": los 4 pasos con datos reales.
class _Steps extends StatelessWidget {
  const _Steps({
    required this.trip,
    required this.city,
    required this.zones,
    required this.onBooking,
  });

  final GroupTrip trip;
  final String city;
  final List<StayZone>? zones;
  final VoidCallback? onBooking;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<(String, int)> top = topTastes(trip.members).take(3).toList();
    final StayZone? zone = zones?.firstOrNull;
    Widget step(String title, Widget body) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: NomadColors.group,
            ),
          ),
          const SizedBox(height: 4),
          body,
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        step(
          t.hubStep1,
          top.isEmpty
              ? _Muted(t.hubStep1Empty)
              : Text(
                  t.hubStep1Text(
                    top
                        .map(
                          ((String, int) e) =>
                              '${tasteLabel(t, e.$1)} (${e.$2})',
                        )
                        .join(' · '),
                  ),
                ),
        ),
        step(
          t.hubStep2,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(t.hubStep2Text(city)),
              if (zone != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    t.hubStep2Zone(zone.name ?? t.sleepZoneCenter(city)),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
            ],
          ),
        ),
        step(
          t.hubStep3,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Muted(t.hubStep3Text),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(64, 40),
                ),
                icon: const Icon(Icons.hotel_rounded, size: 18),
                label: Text(t.hubOpenBooking),
                onPressed: onBooking,
              ),
            ],
          ),
        ),
        step(
          t.hubStep4,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _Muted(t.hubStep4Text),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(64, 40),
                ),
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(t.hubSeeEvents),
                onPressed: () => context.push(Routes.events()),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// "Votad dónde dormir": dos zonas; cuando todos eligen la misma, acuerdo.
class _SleepVote extends StatelessWidget {
  const _SleepVote({
    required this.zones,
    required this.members,
    required this.titleOf,
    required this.planOf,
    required this.busy,
    required this.onVote,
    required this.onBook,
  });

  final List<StayZone> zones;
  final int members;
  final String Function(StayZone) titleOf;
  final GroupPlan? Function(StayZone) planOf;
  final bool busy;
  final void Function(StayZone) onVote;
  final void Function(StayZone) onBook;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    StayZone? deal;
    int voters = 0;
    bool iVoted = false;
    for (final StayZone z in zones) {
      final GroupPlan? p = planOf(z);
      if (p == null) continue;
      voters = math.max(voters, p.voted);
      if (p.myVote != null) iVoted = true;
      if (members > 0 && p.yes >= members) deal = z;
    }
    final int missing = math.max(0, members - voters);
    return Stack(
      children: <Widget>[
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final StayZone z in zones) ...<Widget>[
              _ZoneOption(
                zone: z,
                title: titleOf(z),
                plan: planOf(z),
                members: members,
                busy: busy,
                onVote: () => onVote(z),
              ),
              const SizedBox(height: 8),
            ],
            if (deal != null) ...<Widget>[
              Text(
                t.sleepDeal,
                style: const TextStyle(
                  color: NomadColors.mint,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
                icon: const Icon(Icons.hotel_rounded),
                label: Text(t.hubOpenBooking),
                onPressed: () => onBook(deal!),
              ),
            ] else
              _Muted(iVoted ? t.sleepVoted(missing) : t.sleepNotVoted(missing)),
          ],
        ),
        if (deal != null)
          const Positioned.fill(child: IgnorePointer(child: _ConfettiOnce())),
      ],
    );
  }
}

class _ZoneOption extends StatelessWidget {
  const _ZoneOption({
    required this.zone,
    required this.title,
    required this.plan,
    required this.members,
    required this.busy,
    required this.onVote,
  });

  final StayZone zone;
  final String title;
  final GroupPlan? plan;
  final int members;
  final bool busy;
  final VoidCallback onVote;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool mine = plan?.myVote == true;
    return Material(
      color: mine ? const Color(0xFF2B2150) : NomadColors.background,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: busy ? null : onVote,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: mine ? NomadColors.group : NomadColors.outline,
              width: mine ? 2 : 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                mine
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                color: mine ? NomadColors.group : NomadColors.textMuted,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    Text(
                      '${zone.by == StayBy.walk ? t.sleepWalk(zone.minutes) : t.sleepTrain(zone.minutes)}'
                      ' · ${t.sleepLodgings(zone.lodgings)}',
                      style: const TextStyle(
                        color: NomadColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                t.sleepVotes(plan?.yes ?? 0, members),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "De dónde saca Flyra los datos": cada fuente con su etiqueta.
class _Sources extends StatelessWidget {
  const _Sources();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    Widget row(IconData icon, String title, String text, String? badge) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(icon, size: 20, color: NomadColors.mint),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    _Muted(text),
                  ],
                ),
              ),
              if (badge != null)
                Container(
                  margin: const EdgeInsetsDirectional.only(start: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: NomadColors.mint.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    badge,
                    style: const TextStyle(
                      color: NomadColors.mint,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        );
    return Column(
      children: <Widget>[
        row(
          Icons.place_rounded,
          t.sourcePlaces,
          t.sourcePlacesText,
          t.sourceFree,
        ),
        row(
          Icons.event_rounded,
          t.sourceEvents,
          t.sourceEventsText,
          t.sourceFree,
        ),
        row(
          Icons.hotel_rounded,
          t.sourceHotels,
          t.sourceHotelsText,
          t.sourceLink,
        ),
        row(Icons.recommend_rounded, t.sourcePicks, t.sourcePicksText, null),
        row(
          Icons.how_to_vote_rounded,
          t.sourceOurs,
          t.sourceOursText,
          t.sourceYours,
        ),
      ],
    );
  }
}

/// "Cómo elige sitios cerca, en cualquier ciudad".
class _HowNearby extends StatelessWidget {
  const _HowNearby({required this.city, required this.gps});

  final String city;
  final bool gps;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: NomadColors.group),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          margin: const EdgeInsets.only(bottom: 10),
          decoration: BoxDecoration(
            color: NomadColors.group.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            t.nearHowRadius,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12),
          ),
        ),
        line(
          Icons.my_location_rounded,
          gps ? t.nearHowWhereGps : t.nearHowWhereCity(city),
        ),
        line(Icons.map_rounded, t.nearHowWhat),
        line(Icons.directions_walk_rounded, t.nearHowTime),
        line(Icons.sort_rounded, t.nearHowOrder),
        _Muted(t.nearHowNoReviews),
      ],
    );
  }
}

/// "¿Qué os apetece?": antojo, sitios a un paseo y Me apetece / Paso.
class _Cravings extends StatelessWidget {
  const _Cravings({
    required this.crave,
    required this.onCrave,
    required this.noCity,
    required this.failed,
    required this.spots,
    required this.from,
    required this.members,
    required this.planOf,
    required this.total,
    required this.busy,
    required this.onVote,
    required this.golden,
  });

  final Craving crave;
  final void Function(Craving) onCrave;
  final bool noCity;
  final bool failed;
  final List<CravingSpot>? spots;
  final GeoPoint? from;
  final List<TripMember> members;
  final GroupPlan? Function(CravingSpot) planOf;
  final int total;
  final bool busy;
  final void Function(CravingSpot, bool) onVote;
  final DateTime? golden;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? taste = tasteOfCraving(crave);
    final List<String> fans = <String>[
      if (taste != null)
        for (final TripMember m in members)
          if (m.tastes.contains(taste)) memberName(t, m),
    ];
    final List<CravingSpot>? list = spots;
    final GeoPoint? at = from;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: <Widget>[
            for (final Craving c in Craving.values)
              ChoiceChip(
                selected: c == crave,
                selectedColor: NomadColors.mint,
                label: Text(
                  cravingLabel(t, c),
                  style: TextStyle(
                    color: c == crave ? NomadColors.background : null,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                onSelected: (_) => onCrave(c),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (noCity)
          _Muted(t.craveNone)
        else if (failed)
          _Muted(t.errorUnavailable)
        else if (list == null || at == null)
          const _Loading()
        else if (list.isEmpty)
          _Muted(t.craveNone)
        else
          for (final CravingSpot s in list)
            _SpotCard(
              spot: s,
              minutes: walkMinutes(at.distanceTo(s.point)),
              fans: fans,
              plan: planOf(s),
              total: total,
              busy: busy,
              onVote: (bool yes) => onVote(s, yes),
            ),
        if (golden != null) ...<Widget>[
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.wb_twilight_rounded,
                color: NomadColors.money,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.craveGolden(
                    DateFormat.Hm(
                      Localizations.localeOf(context).toLanguageTag(),
                    ).format(golden!.toLocal()),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        _Muted(t.craveSource),
      ],
    );
  }
}

class _SpotCard extends StatelessWidget {
  const _SpotCard({
    required this.spot,
    required this.minutes,
    required this.fans,
    required this.plan,
    required this.total,
    required this.busy,
    required this.onVote,
  });

  final CravingSpot spot;
  final int minutes;
  final List<String> fans;
  final GroupPlan? plan;
  final int total;
  final bool busy;
  final void Function(bool) onVote;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool? mine = plan?.myVote;
    return Opacity(
      opacity: mine == false ? 0.5 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: NomadColors.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: mine == true ? NomadColors.mint : NomadColors.outline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    spot.name,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                Text(
                  t.craveWalk(minutes),
                  style: const TextStyle(
                    color: NomadColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            if (fans.isNotEmpty)
              Text(
                t.craveFits(fans.join(', ')),
                style: const TextStyle(color: NomadColors.mint, fontSize: 12),
              ),
            if (spot.openingHours != null)
              Text(
                spot.openingHours!,
                style: const TextStyle(
                  color: NomadColors.textMuted,
                  fontSize: 11.5,
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                FilledButton(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 36),
                    backgroundColor: mine == true
                        ? NomadColors.mint
                        : NomadColors.surface,
                    foregroundColor: mine == true
                        ? NomadColors.background
                        : NomadColors.text,
                  ),
                  onPressed: busy ? null : () => onVote(true),
                  child: Text(t.craveLike),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(64, 36),
                  ),
                  onPressed: busy ? null : () => onVote(false),
                  child: Text(t.craveSkip),
                ),
                Text(
                  t.craveJoined(plan?.yes ?? 0, total),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: (plan?.yes ?? 0) >= 2
                        ? NomadColors.mint
                        : NomadColors.textMuted,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Confeti una vez, cuando hay acuerdo para dormir (como en la maqueta).
class _ConfettiOnce extends StatefulWidget {
  const _ConfettiOnce();

  @override
  State<_ConfettiOnce> createState() => _ConfettiOnceState();
}

class _ConfettiOnceState extends State<_ConfettiOnce>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (BuildContext context, Widget? _) =>
        CustomPaint(painter: _Confetti(_c.value)),
  );
}

class _Confetti extends CustomPainter {
  const _Confetti(this.t);

  final double t;

  static const List<Color> _colors = <Color>[
    Color(0xFFFFD27A),
    Color(0xFFFF7AB6),
    Color(0xFFB69CFF),
    Color(0xFF7FE8B9),
    Color(0xFF6CA8FF),
    Colors.white,
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0 || t >= 1) return;
    // Siempre la misma "lluvia" (números fijos): no salta al repintar.
    final math.Random r = math.Random(7);
    final Paint paint = Paint();
    for (int i = 0; i < 36; i++) {
      final double x = r.nextDouble() * size.width;
      final double drift = (r.nextDouble() - 0.5) * 100;
      final double delay = r.nextDouble() * 0.4;
      final double p = ((t - delay) / (1 - delay)).clamp(0.0, 1.0);
      if (p <= 0) continue;
      paint.color = _colors[i % _colors.length].withValues(alpha: 1 - p * 0.6);
      canvas
        ..save()
        ..translate(x + drift * p, -20 + p * (size.height + 40))
        ..rotate(p * 8 + i)
        ..drawRect(const Rect.fromLTWH(-4, -6, 8, 12), paint)
        ..restore();
    }
  }

  @override
  bool shouldRepaint(_Confetti old) => old.t != t;
}
