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
import 'mini_map.dart';
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
    final GeoPoint? center = _center;
    final List<CravingSpot>? ranked = switch ((_spots, center)) {
      (final List<CravingSpot> s, final GeoPoint at) => rankSpots(
        s,
        at,
        <String, GroupPlan>{
          for (final GroupPlan p in _board?.extras ?? const <GroupPlan>[])
            if (p.kind == PlanKind.crave) p.title.toLowerCase(): p,
        },
      ).take(5).toList(),
      _ => null,
    };
    int section = 0;
    Widget reveal(Widget child) => _Reveal(index: section++, child: child);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        reveal(_Shortcuts(trip: trip, city: _cityName)),
        const SizedBox(height: 18),
        reveal(
          _Section(
            icon: Icons.favorite_rounded,
            color: const Color(0xFFFF6FA5),
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
        ),
        const SizedBox(height: 16),
        reveal(
          _Section(
            icon: Icons.auto_awesome_rounded,
            color: NomadColors.group,
            title: t.hubStepsTitle,
            child: _Steps(
              trip: trip,
              city: _cityName,
              cityPoint: _city,
              zones: _zones,
              onBooking: _city == null
                  ? null
                  : () => unawaited(
                      _openBooking(_zones?.firstOrNull?.point ?? _city!),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        reveal(
          _Section(
            icon: Icons.hotel_rounded,
            color: NomadColors.flights,
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
        ),
        const SizedBox(height: 16),
        reveal(
          _Section(
            icon: Icons.dataset_rounded,
            color: NomadColors.mint,
            title: t.sourcesTitle,
            child: const _Sources(),
          ),
        ),
        const SizedBox(height: 16),
        reveal(
          _Section(
            icon: Icons.near_me_rounded,
            color: NomadColors.safety,
            title: t.nearHowTitle,
            child: _HowNearby(
              city: _cityName,
              gps: _here != null,
              center: center,
              spots: ranked,
            ),
          ),
        ),
        const SizedBox(height: 16),
        reveal(
          _Section(
            icon: Icons.restaurant_rounded,
            color: NomadColors.money,
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
              spots: ranked,
              from: center,
              members: trip.members,
              planOf: (CravingSpot s) => _find(_board, PlanKind.crave, s.name),
              total: _board?.members ?? trip.members.length,
              busy: _voting,
              onVote: (CravingSpot s, bool yes) =>
                  unawaited(_voteSpot(s, yes: yes)),
              onGo: (CravingSpot s) => unawaited(_go(s.point)),
              golden: _city == null ? null : goldenHour(DateTime.now(), _city!),
            ),
          ),
        ),
      ],
    );
  }

  /// "Ir": Google Maps andando hasta el sitio (un enlace, gratis).
  Future<void> _go(GeoPoint p) => _services.openBooking(
    Uri.https('www.google.com', '/maps/dir/', <String, String>{
      'api': '1',
      'destination': '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}',
      'travelmode': 'walking',
    }),
  );
}

/// Cada sección entra subiendo un poco y apareciendo, una detrás de otra.
class _Reveal extends StatelessWidget {
  const _Reveal({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: Duration(milliseconds: 420 + 90 * index),
    curve: Curves.easeOutCubic,
    builder: (BuildContext context, double v, Widget? c) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 24 * (1 - v)), child: c),
    ),
    child: child,
  );
}

/// Un icono "con relieve" como los de la maqueta: degradado, brillo arriba y
/// una sombra de su color.
class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, required this.color, this.size = 48});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.32),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color.lerp(color, Colors.white, 0.25)!,
          color,
          Color.lerp(color, Colors.black, 0.35)!,
        ],
      ),
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: color.withValues(alpha: 0.35),
          blurRadius: 14,
          offset: const Offset(0, 5),
        ),
      ],
    ),
    child: Stack(
      alignment: Alignment.center,
      children: <Widget>[
        // El brillo de arriba (como si le diera la luz).
        Positioned(
          top: 2,
          left: size * 0.12,
          right: size * 0.12,
          height: size * 0.38,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.3),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[
                  Colors.white.withValues(alpha: 0.35),
                  Colors.white.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
        Icon(
          icon,
          color: Colors.white,
          size: size * 0.5,
          shadows: const <Shadow>[
            Shadow(color: Colors.black38, blurRadius: 4, offset: Offset(0, 1)),
          ],
        ),
      ],
    ),
  );
}

/// Una sección con su icono de color, título y subtítulo.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.color,
    required this.title,
    required this.child,
    this.subtitle,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: <Color>[
          Color.lerp(NomadColors.surface, color, 0.1)!,
          NomadColors.surface,
        ],
      ),
      border: Border.all(color: color.withValues(alpha: 0.28)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            _IconTile(icon: icon, color: color, size: 44),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: NomadFonts.display,
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        color: NomadColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
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
    style: const TextStyle(color: NomadColors.textMuted, fontSize: 12.5),
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

/// Una pastilla de color ("Gratis", "Enlace", "1 de 2").
class _Pill extends StatelessWidget {
  const _Pill(this.text, this.color);

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withValues(alpha: 0.45)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

/// Los cuatro atajos de la cabecera, con iconos con relieve.
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
            borderRadius: BorderRadius.circular(18),
            onTap: () => context.push(route),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Column(
                children: <Widget>[
                  _IconTile(icon: icon, color: color, size: 58),
                  const SizedBox(height: 8),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 2,
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
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        item(
          Icons.forum_rounded,
          t.chatTitle,
          const Color(0xFF34C77B),
          Routes.groupChat(trip.id),
        ),
        item(
          Icons.savings_rounded,
          t.kittyName,
          const Color(0xFFF2A33A),
          Routes.money(tab: MoneyTab.kitty),
        ),
        item(
          Icons.favorite_rounded,
          t.plansOpen,
          const Color(0xFFFF5C8A),
          Routes.groupPlans(trip.id, city: city),
        ),
        item(
          Icons.style_rounded,
          t.cardsTitle,
          const Color(0xFF5B8CFF),
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
        // Pestañas de personas, como un interruptor de varias posiciones.
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: NomadColors.background,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: NomadColors.outline),
          ),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < members.length; i++)
                Expanded(
                  child: Semantics(
                    button: true,
                    selected: i == index,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onWho(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: i == index
                              ? faceColor(i).withValues(alpha: 0.9)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(
                          memberName(t, members[i]),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                            color: i == index
                                ? NomadColors.background
                                : NomadColors.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Wrap(
            key: ValueKey<int>(index),
            spacing: 7,
            runSpacing: 7,
            children: <Widget>[
              for (final String id in tasteIds)
                if (person.me || person.tastes.contains(id))
                  _TasteChip(
                    label: tasteLabel(t, id),
                    selected: person.tastes.contains(id),
                    color: color,
                    onTap: person.me && !busy ? () => onToggle(id) : null,
                  ),
            ],
          ),
        ),
        if (!person.me && person.tastes.isEmpty) _Muted(t.tastesNone),
        const SizedBox(height: 10),
        _Muted(
          person.me
              ? t.tastesHintMine
              : t.tastesHintOther(memberName(t, person)),
        ),
        const SizedBox(height: 14),
        // Cómo se ve contárselo a Flyra en el chat (un ejemplo).
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: NomadColors.background,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: NomadColors.outline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      t.tastesChatTitle,
                      style: const TextStyle(
                        color: NomadColors.textMuted,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                  _Pill(t.hubExample, NomadColors.textMuted),
                ],
              ),
              const SizedBox(height: 10),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 280),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: NomadColors.safety.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: NomadColors.safety.withValues(alpha: 0.6),
                    ),
                  ),
                  child: Text(t.hubChatSample),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const FlyraAvatar(size: 28),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: NomadColors.group.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: NomadColors.group.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Text(
                        t.tastesNoted('${t.tasteMusic}, ${t.tasteFish}'),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _Muted(t.tastesNoAi),
      ],
    );
  }
}

/// Un gusto: se rellena de su color y le sale un tick al marcarlo.
class _TasteChip extends StatelessWidget {
  const _TasteChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    selected: selected,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? color.withValues(alpha: 0.2)
              : NomadColors.background,
          borderRadius: BorderRadius.circular(17),
          border: Border.all(
            color: selected ? color : NomadColors.outline,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedScale(
              scale: selected ? 1 : 0,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: selected ? 18 : 0,
                height: 18,
                margin: EdgeInsetsDirectional.only(end: selected ? 6 : 0),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                child: const Icon(
                  Icons.check_rounded,
                  size: 13,
                  color: NomadColors.background,
                ),
              ),
            ),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w800,
                color: selected ? NomadColors.text : NomadColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// "Así lo busca Flyra": 4 pestañas con dibujo; "Repetir" las enseña solas.
class _Steps extends StatefulWidget {
  const _Steps({
    required this.trip,
    required this.city,
    required this.cityPoint,
    required this.zones,
    required this.onBooking,
  });

  final GroupTrip trip;
  final String city;
  final GeoPoint? cityPoint;
  final List<StayZone>? zones;
  final VoidCallback? onBooking;

  @override
  State<_Steps> createState() => _StepsState();
}

class _StepsState extends State<_Steps> {
  int _step = 0;
  Timer? _replay;

  @override
  void dispose() {
    _replay?.cancel();
    super.dispose();
  }

  void _play() {
    _replay?.cancel();
    setState(() => _step = 0);
    _replay = Timer.periodic(const Duration(milliseconds: 1800), (Timer tm) {
      if (!mounted || _step >= 3) {
        tm.cancel();
        return;
      }
      setState(() => _step++);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<(IconData, String, Color)> tabs = <(IconData, String, Color)>[
      (Icons.favorite_rounded, t.hubTabTastes, const Color(0xFFFF6FA5)),
      (Icons.map_rounded, t.hubTabZone, NomadColors.flights),
      (Icons.nights_stay_rounded, t.hubTabSleep, NomadColors.group),
      (Icons.local_activity_rounded, t.hubTabEvents, NomadColors.money),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            for (int i = 0; i < tabs.length; i++)
              Expanded(
                child: Semantics(
                  button: true,
                  selected: i == _step,
                  label: tabs[i].$2,
                  excludeSemantics: true,
                  child: GestureDetector(
                    onTap: () {
                      _replay?.cancel();
                      setState(() => _step = i);
                    },
                    child: Column(
                      children: <Widget>[
                        AnimatedScale(
                          scale: i == _step ? 1.08 : 0.9,
                          duration: const Duration(milliseconds: 250),
                          child: AnimatedOpacity(
                            opacity: i == _step ? 1 : 0.55,
                            duration: const Duration(milliseconds: 250),
                            child: _IconTile(
                              icon: tabs[i].$1,
                              color: tabs[i].$3,
                              size: 46,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          tabs[i].$2,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: i == _step
                                ? NomadColors.text
                                : NomadColors.textMuted,
                          ),
                        ),
                        const SizedBox(height: 4),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          height: 3,
                          width: i == _step ? 28 : 0,
                          decoration: BoxDecoration(
                            color: tabs[i].$3,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: NomadColors.background,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: tabs[_step].$3.withValues(alpha: 0.45)),
          ),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            transitionBuilder: (Widget child, Animation<double> a) =>
                FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.06, 0),
                      end: Offset.zero,
                    ).animate(a),
                    child: child,
                  ),
                ),
            child: KeyedSubtree(
              key: ValueKey<int>(_step),
              child: _content(t, tabs[_step].$3),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(64, 36)),
            icon: const Icon(Icons.replay_rounded, size: 18),
            label: Text(t.hubReplay),
            onPressed: _play,
          ),
        ),
      ],
    );
  }

  Widget _title(String text, Color color) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      text,
      style: TextStyle(fontWeight: FontWeight.w800, color: color),
    ),
  );

  Widget _content(AppLocalizations t, Color color) {
    switch (_step) {
      case 0:
        final List<(String, int)> top = topTastes(widget.trip.members)
            .take(4)
            .toList();
        final int most = top.isEmpty ? 1 : top.first.$2;
        final int people = math.max(1, widget.trip.members.length);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _title(t.hubStep1, color),
            if (top.isEmpty)
              _Muted(t.hubStep1Empty)
            else ...<Widget>[
              Text(
                t.hubStep1Text(
                  top
                      .take(3)
                      .map(
                        ((String, int) e) => '${tasteLabel(t, e.$1)} (${e.$2})',
                      )
                      .join(' · '),
                ),
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 10),
              // Una barra por gusto: cuánta gente del grupo lo marcó.
              for (final (String id, int n) in top)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 120,
                        child: Text(
                          tasteLabel(t, id),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Expanded(
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(begin: 0, end: n / people),
                          duration: const Duration(milliseconds: 700),
                          curve: Curves.easeOutCubic,
                          builder: (_, double v, _) => ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: LinearProgressIndicator(
                              value: v,
                              minHeight: 10,
                              color: n == most
                                  ? color
                                  : color.withValues(alpha: 0.55),
                              backgroundColor: NomadColors.surfaceHigh,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$n/$people',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        );
      case 1:
        final GeoPoint? city = widget.cityPoint;
        final List<StayZone> zones = widget.zones ?? const <StayZone>[];
        final StayZone? zone = zones.firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _title(t.hubStep2, color),
            if (city != null) ...<Widget>[
              MiniMap(
                center: city,
                radiusM: math.max(
                  1200,
                  zones.fold<double>(
                    0,
                    (double m, StayZone z) =>
                        math.max(m, city.distanceTo(z.point)),
                  ),
                ),
                pins: <MapPin>[
                  for (int i = 0; i < zones.length; i++)
                    MapPin(
                      at: zones[i].point,
                      color: i == 0 ? NomadColors.mint : NomadColors.money,
                      label: zones[i].name ?? t.sleepZoneCenter(widget.city),
                      icon: Icons.hotel_rounded,
                    ),
                ],
                youLabel: widget.city,
                height: 170,
              ),
              const SizedBox(height: 8),
            ],
            Text(
              t.hubStep2Text(widget.city),
              style: const TextStyle(fontSize: 12.5),
            ),
            if (zone != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  t.hubStep2Zone(zone.name ?? t.sleepZoneCenter(widget.city)),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
          ],
        );
      case 2:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _title(t.hubStep3, color),
            _Muted(t.hubStep3Text),
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 42),
                backgroundColor: color,
                foregroundColor: NomadColors.background,
              ),
              icon: const Icon(Icons.hotel_rounded, size: 18),
              label: Text(t.hubOpenBooking),
              onPressed: widget.onBooking,
            ),
          ],
        );
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _title(t.hubStep4, color),
            _Muted(t.hubStep4Text),
            const SizedBox(height: 10),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 42),
                backgroundColor: color,
                foregroundColor: NomadColors.background,
              ),
              icon: const Icon(Icons.event_rounded, size: 18),
              label: Text(t.hubSeeEvents),
              onPressed: () => context.push(Routes.events()),
            ),
          ],
        );
    }
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
                won: deal?.id == z.id,
                onVote: () => onVote(z),
              ),
              const SizedBox(height: 10),
            ],
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 400),
              child: deal != null
                  ? Container(
                      key: const ValueKey<String>('deal'),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        gradient: const LinearGradient(
                          colors: <Color>[Color(0xFF1F5B44), Color(0xFF17324A)],
                        ),
                        border: Border.all(color: NomadColors.mint),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const Icon(
                                Icons.celebration_rounded,
                                color: NomadColors.mint,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  t.sleepDeal,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(64, 46),
                            ),
                            icon: const Icon(Icons.hotel_rounded),
                            label: Text(t.hubOpenBooking),
                            onPressed: () => onBook(deal!),
                          ),
                        ],
                      ),
                    )
                  : Row(
                      key: const ValueKey<String>('wait'),
                      children: <Widget>[
                        const Icon(
                          Icons.hourglass_top_rounded,
                          size: 16,
                          color: NomadColors.textMuted,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: _Muted(
                            iVoted
                                ? t.sleepVoted(missing)
                                : t.sleepNotVoted(missing),
                          ),
                        ),
                      ],
                    ),
            ),
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
    required this.won,
    required this.onVote,
  });

  final StayZone zone;
  final String title;
  final GroupPlan? plan;
  final int members;
  final bool busy;
  final bool won;
  final VoidCallback onVote;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool mine = plan?.myVote == true;
    final int yes = plan?.yes ?? 0;
    final Color accent = won ? NomadColors.mint : NomadColors.group;
    return AnimatedScale(
      scale: mine ? 1 : 0.98,
      duration: const Duration(milliseconds: 250),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: busy ? null : onVote,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 280),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: mine
                  ? LinearGradient(
                      colors: <Color>[
                        accent.withValues(alpha: 0.22),
                        NomadColors.background,
                      ],
                    )
                  : null,
              color: mine ? null : NomadColors.background,
              border: Border.all(
                color: mine ? accent : NomadColors.outline,
                width: mine ? 2 : 1,
              ),
            ),
            child: Row(
              children: <Widget>[
                _IconTile(
                  icon: zone.by == StayBy.walk
                      ? Icons.directions_walk_rounded
                      : Icons.train_rounded,
                  color: zone.by == StayBy.walk
                      ? NomadColors.mint
                      : NomadColors.flights,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      const SizedBox(height: 2),
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
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    // Un punto por persona: relleno = la ha elegido.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (int i = 0; i < members; i++)
                          AnimatedContainer(
                            duration: Duration(milliseconds: 250 + 80 * i),
                            width: 10,
                            height: 10,
                            margin: const EdgeInsetsDirectional.only(start: 3),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < yes ? accent : Colors.transparent,
                              border: Border.all(
                                color: i < yes ? accent : NomadColors.outline,
                                width: 1.5,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.sleepVotes(yes, members),
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "De dónde saca Flyra los datos": cada fuente con su icono y etiqueta.
class _Sources extends StatelessWidget {
  const _Sources();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    Widget row(
      IconData icon,
      Color color,
      String title,
      String text,
      String? badge,
      Color badgeColor,
    ) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _IconTile(icon: icon, color: color, size: 40),
          const SizedBox(width: 12),
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
          if (badge != null) ...<Widget>[
            const SizedBox(width: 8),
            _Pill(badge, badgeColor),
          ],
        ],
      ),
    );
    return Column(
      children: <Widget>[
        row(
          Icons.place_rounded,
          NomadColors.flights,
          t.sourcePlaces,
          t.sourcePlacesText,
          t.sourceFree,
          NomadColors.mint,
        ),
        row(
          Icons.confirmation_number_rounded,
          NomadColors.safety,
          t.sourceEvents,
          t.sourceEventsText,
          t.sourceFree,
          NomadColors.mint,
        ),
        row(
          Icons.hotel_rounded,
          const Color(0xFF7C6CF2),
          t.sourceHotels,
          t.sourceHotelsText,
          t.sourceLink,
          NomadColors.money,
        ),
        row(
          Icons.recommend_rounded,
          NomadColors.money,
          t.sourcePicks,
          t.sourcePicksText,
          t.sourceFree,
          NomadColors.mint,
        ),
        row(
          Icons.how_to_vote_rounded,
          const Color(0xFF34C77B),
          t.sourceOurs,
          t.sourceOursText,
          t.sourceYours,
          NomadColors.group,
        ),
      ],
    );
  }
}

/// "Cómo elige sitios cerca": minimapa con tu radio y 4 recuadros.
class _HowNearby extends StatelessWidget {
  const _HowNearby({
    required this.city,
    required this.gps,
    required this.center,
    required this.spots,
  });

  final String city;
  final bool gps;
  final GeoPoint? center;
  final List<CravingSpot>? spots;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final GeoPoint? at = center;
    Widget box(int n, String text) => Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: NomadColors.background,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NomadColors.outline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: NomadColors.flights,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$n',
              style: const TextStyle(
                color: NomadColors.background,
                fontWeight: FontWeight.w900,
                fontSize: 12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
    final List<String> texts = <String>[
      gps ? t.nearHowWhereGps : t.nearHowWhereCity(city),
      t.nearHowWhat,
      t.nearHowTime,
      t.nearHowOrder,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (at != null) ...<Widget>[
          MiniMap(
            center: at,
            ring: true,
            youLabel: t.hubYouPin,
            badge: t.nearHowRadius,
            pins: <MapPin>[
              for (final (int i, CravingSpot s)
                  in (spots ?? const <CravingSpot>[]).take(3).indexed)
                MapPin(at: s.point, color: NomadColors.mint, number: i + 1),
            ],
          ),
          const SizedBox(height: 10),
        ] else
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _Pill(t.nearHowRadius, NomadColors.group),
          ),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double w = (c.maxWidth - 8) / 2;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (int i = 0; i < texts.length; i++)
                  SizedBox(width: w, child: box(i + 1, texts[i])),
              ],
            );
          },
        ),
        const SizedBox(height: 10),
        _Muted(t.nearHowNoReviews),
      ],
    );
  }
}

IconData _cravingIcon(Craving c) => switch (c) {
  Craving.tapas => Icons.tapas_rounded,
  Craving.fish => Icons.set_meal_rounded,
  Craving.veggie => Icons.eco_rounded,
  Craving.cafe => Icons.local_cafe_rounded,
  Craving.views => Icons.landscape_rounded,
};

/// "¿Qué os apetece?": antojo, minimapa, sitios y Me apetece / Paso / Ir.
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
    required this.onGo,
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
  final void Function(CravingSpot) onGo;
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
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (final Craving c in Craving.values)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 7),
                  child: Semantics(
                    button: true,
                    selected: c == crave,
                    child: GestureDetector(
                      onTap: () => onCrave(c),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        height: 36,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          gradient: c == crave
                              ? const LinearGradient(
                                  colors: <Color>[
                                    Color(0xFF7FF0BF),
                                    NomadColors.mint,
                                  ],
                                )
                              : null,
                          color: c == crave ? null : NomadColors.background,
                          border: Border.all(
                            color: c == crave
                                ? NomadColors.mint
                                : NomadColors.outline,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              _cravingIcon(c),
                              size: 17,
                              color: c == crave
                                  ? NomadColors.background
                                  : NomadColors.money,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              cravingLabel(t, c),
                              style: TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12.5,
                                color: c == crave
                                    ? NomadColors.background
                                    : NomadColors.text,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
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
        else ...<Widget>[
          MiniMap(
            center: at,
            youLabel: t.hubYouPin,
            height: 170,
            pins: <MapPin>[
              for (final (int i, CravingSpot s) in list.indexed)
                MapPin(
                  at: s.point,
                  color: NomadColors.money,
                  number: i + 1,
                  label: i == 0 ? s.name : null,
                ),
            ],
          ),
          const SizedBox(height: 10),
          for (final (int i, CravingSpot s) in list.indexed)
            _SpotCard(
              number: i + 1,
              spot: s,
              minutes: walkMinutes(at.distanceTo(s.point)),
              fans: fans,
              plan: planOf(s),
              total: total,
              busy: busy,
              onVote: (bool yes) => onVote(s, yes),
              onGo: () => onGo(s),
            ),
        ],
        if (golden != null) ...<Widget>[
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                colors: <Color>[
                  NomadColors.money.withValues(alpha: 0.22),
                  const Color(0xFFFF6FA5).withValues(alpha: 0.12),
                ],
              ),
              border: Border.all(
                color: NomadColors.money.withValues(alpha: 0.5),
              ),
            ),
            child: Row(
              children: <Widget>[
                const _IconTile(
                  icon: Icons.wb_twilight_rounded,
                  color: Color(0xFFFF9A5A),
                  size: 38,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.craveGolden(
                      DateFormat.Hm(
                        Localizations.localeOf(context).toLanguageTag(),
                      ).format(golden!.toLocal()),
                    ),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
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
    required this.number,
    required this.spot,
    required this.minutes,
    required this.fans,
    required this.plan,
    required this.total,
    required this.busy,
    required this.onVote,
    required this.onGo,
  });

  final int number;
  final CravingSpot spot;
  final int minutes;
  final List<String> fans;
  final GroupPlan? plan;
  final int total;
  final bool busy;
  final void Function(bool) onVote;
  final VoidCallback onGo;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool? mine = plan?.myVote;
    final int yes = plan?.yes ?? 0;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: mine == false ? 0.5 : 1,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: NomadColors.background,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: mine == true ? NomadColors.mint : NomadColors.outline,
            width: mine == true ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    color: NomadColors.money,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$number',
                    style: const TextStyle(
                      color: NomadColors.background,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    spot.name,
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 15,
                    ),
                  ),
                ),
                _Pill(t.craveWalk(minutes), NomadColors.flights),
              ],
            ),
            if (fans.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  t.craveFits(fans.join(', ')),
                  style: const TextStyle(
                    color: NomadColors.mint,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            if (spot.openingHours != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.schedule_rounded,
                      size: 13,
                      color: NomadColors.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Expanded(child: _Muted(spot.openingHours!)),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                AnimatedScale(
                  scale: mine == true ? 1.05 : 1,
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 38),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      backgroundColor: mine == true
                          ? NomadColors.mint
                          : NomadColors.surfaceHigh,
                      foregroundColor: mine == true
                          ? NomadColors.background
                          : NomadColors.text,
                    ),
                    icon: Icon(
                      mine == true
                          ? Icons.favorite_rounded
                          : Icons.favorite_border_rounded,
                      size: 17,
                    ),
                    onPressed: busy ? null : () => onVote(true),
                    label: Text(t.craveLike),
                  ),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(56, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  onPressed: busy ? null : () => onVote(false),
                  child: Text(t.craveSkip),
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(56, 38),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    foregroundColor: NomadColors.flights,
                  ),
                  icon: const Icon(Icons.directions_walk_rounded, size: 17),
                  onPressed: onGo,
                  label: Text(t.craveGo),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(
                      begin: 0,
                      end: total == 0 ? 0 : yes / total,
                    ),
                    duration: const Duration(milliseconds: 500),
                    curve: Curves.easeOutCubic,
                    builder: (_, double v, _) => ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: v,
                        minHeight: 6,
                        color: yes >= 2 ? NomadColors.mint : NomadColors.money,
                        backgroundColor: NomadColors.surfaceHigh,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  t.craveJoined(yes, total),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: yes >= 2 ? NomadColors.mint : NomadColors.textMuted,
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
