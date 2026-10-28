// Cerca de ti (maqueta "Cerca de ti"), con dos pestañas:
//   - Gratis: agua potable, baños, wifi gratis y dónde cargar el móvil.
//   - Tengo 2 horas: un paseo por sitios que ver que vuelve a tiempo.
//
// La maqueta tenía una tercera, "Ofertas ya" (happy hours de bares). No hay
// datos libres y fiables de ofertas en tiempo real: inventarlas sería peor
// que no tenerlas. Queda para cuando haya acuerdos con locales.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import 'nearby_api.dart';
import 'walk.dart';

/// Cuántos sitios de cada tipo se enseñan como mucho (los más cercanos).
const int shownSpots = 12;

enum _Tab { free, walk }

class NearbyScreen extends StatefulWidget {
  const NearbyScreen({super.key});

  @override
  State<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends State<NearbyScreen> {
  late final AppServices _services = ServicesScope.of(context);

  _Tab _tab = _Tab.free;
  NearbyKind _kind = NearbyKind.water;
  int _hours = 2;

  bool _loading = false;
  bool _noLocation = false;
  ApiError? _error;
  GeoPoint? _me;
  NearbyList? _found;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_search()));
  }

  /// Por qué no hay posición: sin permiso / GPS apagado, o aún sin señal.
  bool _noSignal = false;

  Future<GeoPoint?> _position() async {
    final LocationSource gps = _services.location;
    _noSignal = false;
    try {
      LocationAccess access = await gps.check();
      if (access == LocationAccess.denied) access = await gps.request();
      if (access != LocationAccess.granted) return null;
      final PositionFix? fix = await gps.current();
      if (fix == null) _noSignal = true;
      return fix?.point;
    } on Object {
      // Tiempo agotado, GPS que falla a mitad, etc.: cualquier error de
      // geolocator se trata como "todavía sin señal" y se puede reintentar.
      _noSignal = true;
      return null;
    }
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _noLocation = false;
      _error = null;
    });
    final GeoPoint? me = await _position();
    if (!mounted) return;
    if (me == null) {
      setState(() => (_loading = false, _noLocation = true));
      return;
    }
    try {
      final NearbyList found = await _services.nearby.near(me);
      if (mounted) setState(() => (_me = me, _found = found, _loading = false));
    } on ApiException catch (e) {
      if (mounted) setState(() => (_error = e.error, _loading = false));
    }
  }

  /// "Llévame": Google Maps andando hasta ese punto (es un enlace, gratis).
  void _go(GeoPoint p) => unawaited(
    _services.openBooking(
      Uri.https('www.google.com', '/maps/dir/', <String, String>{
        'api': '1',
        'destination':
            '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}',
        'travelmode': 'walking',
      }),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final GeoPoint? me = _me;
    final NearbyList? found = _found;
    return Scaffold(
      appBar: AppBar(title: Text(t.nearbyTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: <Widget>[
          SegmentedButton<_Tab>(
            segments: <ButtonSegment<_Tab>>[
              ButtonSegment<_Tab>(
                value: _Tab.free,
                label: Text(t.nearbyFree),
                icon: const Icon(Icons.water_drop_rounded),
              ),
              ButtonSegment<_Tab>(
                value: _Tab.walk,
                label: Text(t.nearbyWalk),
                icon: const Icon(Icons.directions_walk_rounded),
              ),
            ],
            selected: <_Tab>{_tab},
            onSelectionChanged: (Set<_Tab> s) => setState(() => _tab = s.first),
          ),
          const SizedBox(height: 16),
          if (_loading)
            const Center(child: CircularProgressIndicator())
          else if (_noLocation || _error != null || me == null || found == null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  _noLocation
                      ? (_noSignal ? t.nearbyNoSignal : t.cameraNoLocation)
                      : _error == ApiError.network
                      ? t.errorNetwork
                      : t.errorUnavailable,
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: _search, child: Text(t.guideRetry)),
              ],
            )
          else ...<Widget>[
            ...switch (_tab) {
              _Tab.free => _free(t, text, me, found),
              _Tab.walk => _walk(t, text, me, found),
            },
            const SizedBox(height: 12),
            Text(
              found.attribution,
              style: const TextStyle(
                fontSize: 11,
                color: NomadColors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _free(
    AppLocalizations t,
    TextTheme text,
    GeoPoint me,
    NearbyList found,
  ) {
    final List<NearbySpot> list = found.of(_kind, me).take(shownSpots).toList();
    final (String Function(AppLocalizations), IconData, Color) look =
        _looks[_kind]!;
    return <Widget>[
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (final NearbyKind k in _freeKinds)
            ChoiceChip(
              avatar: Icon(_looks[k]!.$2, size: 18, color: _looks[k]!.$3),
              label: Text(_looks[k]!.$1(t)),
              selected: _kind == k,
              onSelected: (_) => setState(() => _kind = k),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (list.isEmpty)
        Text(t.nearbyNone, style: text.bodyLarge)
      else
        for (final NearbySpot s in list)
          Card(
            child: ListTile(
              leading: Icon(look.$2, color: look.$3),
              title: Text(s.name ?? look.$1(t)),
              subtitle: Text(
                <String>[
                  t.nearbyMeters(me.distanceTo(s.point).round()),
                  if (s.fee == true) t.nearbyPaid,
                  if (s.fee == false) t.nearbyNoFee,
                  ?s.openingHours,
                ].join(' · '),
              ),
              // Un botón de icono: los botones con texto del tema piden
              // todo el ancho y no caben en una fila.
              trailing: IconButton.outlined(
                tooltip: t.nearbyGo,
                icon: const Icon(Icons.directions_walk_rounded),
                onPressed: () => _go(s.point),
              ),
            ),
          ),
    ];
  }

  List<Widget> _walk(
    AppLocalizations t,
    TextTheme text,
    GeoPoint me,
    NearbyList found,
  ) {
    final WalkPlan plan = planWalk(
      me,
      found.of(NearbyKind.sight, me),
      _hours * 60,
    );
    return <Widget>[
      Text(t.nearbyWalkIntro, style: text.bodyMedium),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: <Widget>[
          for (final int h in const <int>[1, 2, 3, 4])
            ChoiceChip(
              label: Text(t.nearbyHours(h)),
              selected: _hours == h,
              onSelected: (_) => setState(() => _hours = h),
            ),
        ],
      ),
      const SizedBox(height: 12),
      if (plan.stops.isEmpty)
        Text(t.nearbyWalkNone, style: text.bodyLarge)
      else ...<Widget>[
        Text(
          t.nearbyWalkTotal(plan.stops.length, plan.totalMinutes),
          style: text.titleMedium,
        ),
        const SizedBox(height: 8),
        _StopRow(number: null, title: t.nearbyStartEnd, detail: t.nearbyYou),
        for (int i = 0; i < plan.stops.length; i++)
          _StopRow(
            number: i + 1,
            title: plan.stops[i].spot.name ?? '',
            detail: t.nearbyStopDetail(
              plan.stops[i].walkMinutes,
              minutesPerStop,
            ),
          ),
        _StopRow(
          number: null,
          title: t.nearbyStartEnd,
          detail: t.nearbyBack(plan.backMinutes),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.map_rounded),
          label: Text(t.nearbyOpenWalk),
          onPressed: () => unawaited(_services.openBooking(plan.mapsUrl)),
        ),
      ],
    ];
  }
}

const List<NearbyKind> _freeKinds = <NearbyKind>[
  NearbyKind.water,
  NearbyKind.toilets,
  NearbyKind.wifi,
  NearbyKind.charging,
];

final Map<NearbyKind, (String Function(AppLocalizations), IconData, Color)>
_looks = <NearbyKind, (String Function(AppLocalizations), IconData, Color)>{
  NearbyKind.water: (
    (AppLocalizations t) => t.nearbyWater,
    Icons.water_drop_rounded,
    NomadColors.flights,
  ),
  NearbyKind.toilets: (
    (AppLocalizations t) => t.nearbyToilets,
    Icons.wc_rounded,
    NomadColors.mint,
  ),
  NearbyKind.wifi: (
    (AppLocalizations t) => t.nearbyWifi,
    Icons.wifi_rounded,
    NomadColors.group,
  ),
  NearbyKind.charging: (
    (AppLocalizations t) => t.nearbyCharging,
    Icons.electrical_services_rounded,
    NomadColors.money,
  ),
  NearbyKind.sight: (
    (AppLocalizations t) => t.nearbyWalk,
    Icons.account_balance_rounded,
    NomadColors.safety,
  ),
};

class _StopRow extends StatelessWidget {
  const _StopRow({
    required this.number,
    required this.title,
    required this.detail,
  });

  /// null = la salida y la llegada (tú).
  final int? number;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: CircleAvatar(
      backgroundColor: number == null ? NomadColors.mint : NomadColors.flights,
      foregroundColor: NomadColors.background,
      child: number == null
          ? const Icon(Icons.person_pin_circle_rounded)
          : Text('$number'),
    ),
    title: Text(title),
    subtitle: Text(detail),
  );
}
