// Dormir barato (maqueta "Hoteles"): ¿y si duermes unas paradas más lejos?
//
// 1. Eliges adónde vas (cerca de ti o en el mapa), las fechas y cuántos sois.
// 2. El servidor devuelve ZONAS: junto al sitio (andando) y estaciones de
//    tren o metro con alojamientos alrededor, en tres radios (2, 15, 35 km).
// 3. "Ver precios" abre Booking.com en esa zona con tus fechas: el precio
//    real de ese día. Si lo apuntas aquí (y el billete de tren), la app
//    calcula el "total real" y cuánto te ahorras frente a dormir al lado.
//
// Lo que NO hace, a propósito: inventarse precios. No hay datos gratis y
// fiables de precios de hotel para todo el mundo; mejor un número de verdad
// en Booking que uno bonito y falso aquí.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/config.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../map/geo.dart';
import '../map/location.dart';
import 'pick_point_screen.dart';
import 'stays_api.dart';
import 'stays_math.dart';

/// Los tres radios de la maqueta: solo cerca, hasta 15 km, hasta 35 km.
const List<double> stayRadiiKm = <double>[2, 15, 35];

class StaysScreen extends StatefulWidget {
  const StaysScreen({super.key, this.target, this.name});

  /// Adónde vas (si viene de otra pantalla).
  final GeoPoint? target;
  final String? name;

  @override
  State<StaysScreen> createState() => _StaysScreenState();
}

/// Lo que la persona apunta de una zona (lo que vio en Booking).
class _Prices {
  double? night;
  double? fare;
}

class _StaysScreenState extends State<StaysScreen> {
  late final AppServices _services = ServicesScope.of(context);

  late GeoPoint? _target = widget.target;
  late String? _name = widget.name;
  late DateTimeRange _dates = () {
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    return DateTimeRange(
      start: today.add(const Duration(days: 14)),
      end: today.add(const Duration(days: 17)),
    );
  }();
  int _adults = 2;
  int _radius = 1;

  StayArea? _area;
  bool _loading = false;
  bool _noLocation = false;
  ApiError? _error;
  final Map<String, _Prices> _prices = <String, _Prices>{};

  @override
  void initState() {
    super.initState();
    if (_target != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
    }
  }

  int get _nights => _dates.duration.inDays.clamp(1, 60);

  Future<void> _load() async {
    final GeoPoint? target = _target;
    if (target == null) return;
    setState(() => (_loading = true, _error = null));
    try {
      final StayArea area = await _services.stays.around(target);
      if (mounted) setState(() => (_area = area, _loading = false));
    } on ApiException catch (e) {
      if (mounted) setState(() => (_error = e.error, _loading = false));
    }
  }

  Future<void> _nearMe() async {
    final LocationSource gps = _services.location;
    LocationAccess access = await gps.check();
    if (access == LocationAccess.denied) access = await gps.request();
    GeoPoint? me;
    if (access == LocationAccess.granted) {
      try {
        me = (await gps.watch().first.timeout(const Duration(seconds: 15)))
            .point;
      } on TimeoutException {
        me = null;
      } on StateError {
        me = null;
      }
    }
    if (!mounted) return;
    if (me == null) {
      setState(() => _noLocation = true);
      return;
    }
    setState(() => (_target = me, _name = null, _noLocation = false));
    await _load();
  }

  Future<void> _onMap() async {
    final GeoPoint? p = await Navigator.of(context).push<GeoPoint>(
      MaterialPageRoute<GeoPoint>(
        builder: (_) => PickPointScreen(initial: _target),
      ),
    );
    if (p == null || !mounted) return;
    setState(() => (_target = p, _name = null, _noLocation = false));
    await _load();
  }

  Future<void> _pickDates() async {
    final DateTime today = DateUtils.dateOnly(DateTime.now());
    final DateTimeRange? range = await showDateRangePicker(
      context: context,
      firstDate: today,
      lastDate: today.add(const Duration(days: 500)),
      initialDateRange: _dates,
    );
    if (range != null && mounted) {
      setState(
        () => _dates = range.duration.inDays < 1
            ? DateTimeRange(
                start: range.start,
                end: range.start.add(const Duration(days: 1)),
              )
            : range,
      );
    }
  }

  void _openPrices(StayZone zone) {
    final String lang = Localizations.localeOf(context).languageCode;
    unawaited(
      _services.openBooking(
        bookingSearch(
          at: zone.point,
          checkIn: _dates.start,
          checkOut: _dates.end,
          adults: _adults,
          language: lang,
          affiliateId: AppConfig.bookingAffiliateId,
        ),
      ),
    );
  }

  StayCost? _cost(StayZone zone) {
    final _Prices? p = _prices[zone.id];
    final double? night = p?.night;
    if (night == null) return null;
    return StayCost(
      nights: _nights,
      people: _adults,
      nightPrice: night,
      fare: zone.by == StayBy.walk ? 0 : (p?.fare ?? 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final StayArea? area = _area;
    final double maxKm = stayRadiiKm[_radius];
    final List<StayZone> visible = <StayZone>[
      if (area != null)
        for (final StayZone z in area.zones)
          if (z.km <= maxKm) z,
    ];
    final String datesLabel =
        '${DateFormat.MMMd(locale).format(_dates.start)} – ${DateFormat.MMMd(locale).format(_dates.end)} · ${t.staysNights(_nights)}';
    return Scaffold(
      appBar: AppBar(title: Text(t.staysTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
        children: <Widget>[
          Text(
            t.staysSubtitle,
            style: const TextStyle(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 12),
          // ¿Adónde vas?
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const Icon(Icons.place_rounded, color: NomadColors.money),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _target == null
                              ? t.staysWhere
                              : _name ??
                                    t.staysPoint(
                                      _target!.lat.toStringAsFixed(3),
                                      _target!.lon.toStringAsFixed(3),
                                    ),
                          style: text.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      OutlinedButton.icon(
                        icon: const Icon(Icons.my_location_rounded),
                        label: Text(t.staysNearMe),
                        onPressed: () => unawaited(_nearMe()),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.map_rounded),
                        label: Text(t.staysOnMap),
                        onPressed: () => unawaited(_onMap()),
                      ),
                    ],
                  ),
                  if (_noLocation)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        t.staysNoLocation,
                        style: const TextStyle(color: NomadColors.textMuted),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Fechas y personas (para Booking y para las cuentas).
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.date_range_rounded),
                  label: Text(datesLabel, overflow: TextOverflow.ellipsis),
                  onPressed: () => unawaited(_pickDates()),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: t.staysFewer,
                icon: const Icon(Icons.remove_rounded),
                onPressed: _adults > 1 ? () => setState(() => _adults--) : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(t.staysAdults(_adults)),
              ),
              IconButton.outlined(
                tooltip: t.staysMore,
                icon: const Icon(Icons.add_rounded),
                onPressed: _adults < 9 ? () => setState(() => _adults++) : null,
              ),
            ],
          ),
          const SizedBox(height: 12),
          SegmentedButton<int>(
            segments: <ButtonSegment<int>>[
              ButtonSegment<int>(value: 0, label: Text(t.staysRadiusNear)),
              ButtonSegment<int>(value: 1, label: Text(t.staysRadiusKm(15))),
              ButtonSegment<int>(value: 2, label: Text(t.staysRadiusKm(35))),
            ],
            selected: <int>{_radius},
            showSelectedIcon: false,
            onSelectionChanged: (Set<int> v) =>
                setState(() => _radius = v.first),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            Text(
              _error == ApiError.network ? t.staysOffline : t.staysUnavailable,
            )
          else if (area != null) ...<Widget>[
            _Tip(text: _tipFor(t, area, visible)),
            const SizedBox(height: 8),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(t.staysNone),
              ),
            for (final StayZone z in visible)
              _ZoneCard(
                zone: z,
                prices: _prices.putIfAbsent(z.id, _Prices.new),
                cost: _cost(z),
                nearCost: area.zones
                    .where((StayZone x) => x.by == StayBy.walk)
                    .map(_cost)
                    .firstOrNull,
                onPrices: () => _openPrices(z),
                onMaps: () =>
                    unawaited(_services.openBooking(mapsHotels(z.point))),
                onChanged: () => setState(() {}),
              ),
            const SizedBox(height: 16),
            Text(t.staysFactorsTitle, style: text.titleSmall),
            for (final String f in <String>[
              t.staysFactorTime,
              t.staysFactorOffer,
              t.staysFactorBudget,
              t.staysFactorTotal,
            ])
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: <Widget>[
                    const Icon(
                      Icons.check_rounded,
                      size: 18,
                      color: NomadColors.mint,
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(f)),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '${t.staysEstimateNote} ${area.attribution}',
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

  /// El consejo de Flyra según lo que hay en el radio elegido.
  String _tipFor(AppLocalizations t, StayArea area, List<StayZone> visible) {
    final StayZone? walk = visible
        .where((StayZone z) => z.by == StayBy.walk)
        .firstOrNull;
    final List<StayZone> trains = visible
        .where((StayZone z) => z.by == StayBy.train)
        .toList();
    if (trains.isEmpty) {
      final bool more = area.zones.any((StayZone z) => z.by == StayBy.train);
      return more
          ? t.staysTipWiden(walk?.lodgings ?? 0)
          : t.staysTipOnlyNear(walk?.lodgings ?? 0);
    }
    final StayZone best = trains.reduce(
      (StayZone a, StayZone b) => b.lodgings > a.lodgings ? b : a,
    );
    return t.staysTipBest(best.name ?? '', best.lodgings, best.minutes);
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

class _ZoneCard extends StatelessWidget {
  const _ZoneCard({
    required this.zone,
    required this.prices,
    required this.cost,
    required this.nearCost,
    required this.onPrices,
    required this.onMaps,
    required this.onChanged,
  });

  final StayZone zone;
  final _Prices prices;
  final StayCost? cost;
  final StayCost? nearCost;
  final VoidCallback onPrices;
  final VoidCallback onMaps;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final NumberFormat n = NumberFormat.decimalPatternDigits(
      locale: locale,
      decimalDigits: 0,
    );
    final StayCost? c = cost;
    final StayCost? near = nearCost;
    final bool walk = zone.by == StayBy.walk;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  walk ? Icons.directions_walk_rounded : Icons.train_rounded,
                  color: walk ? NomadColors.money : NomadColors.flights,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    zone.name ?? t.staysNearSite,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              walk
                  ? t.staysWalkMeta(zone.minutes)
                  : t.staysTrainMeta(
                      zone.km.toStringAsFixed(zone.km < 10 ? 1 : 0),
                      zone.minutes,
                    ),
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            Text(t.staysLodgings(zone.lodgings, zone.budget)),
            if (zone.examples.isNotEmpty)
              Text(
                zone.examples.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: NomadColors.textMuted,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.hotel_rounded),
                    label: Text(t.staysSeePrices),
                    onPressed: onPrices,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: t.staysOnGoogleMaps,
                  icon: const Icon(Icons.map_outlined),
                  onPressed: onMaps,
                ),
              ],
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(t.staysCalcTitle),
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _Amount(
                        label: t.staysNightPrice,
                        onChanged: (double? v) {
                          prices.night = v;
                          onChanged();
                        },
                      ),
                    ),
                    if (!walk) ...<Widget>[
                      const SizedBox(width: 8),
                      Expanded(
                        child: _Amount(
                          label: t.staysFare,
                          onChanged: (double? v) {
                            prices.fare = v;
                            onChanged();
                          },
                        ),
                      ),
                    ],
                  ],
                ),
                if (c != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    t.staysTotal(n.format(c.total)),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    t.staysTotalParts(
                      n.format(c.hotel),
                      n.format(c.transport),
                      c.trips,
                    ),
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                  if (!walk && near != null)
                    Text(
                      near.total > c.total
                          ? t.staysSave(n.format(near.total - c.total))
                          : t.staysNoSave,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: near.total > c.total
                            ? NomadColors.mint
                            : NomadColors.safety,
                      ),
                    ),
                ],
                const SizedBox(height: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Amount extends StatelessWidget {
  const _Amount({required this.label, required this.onChanged});

  final String label;
  final ValueChanged<double?> onChanged;

  @override
  Widget build(BuildContext context) => TextField(
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
    ],
    decoration: InputDecoration(labelText: label),
    onChanged: (String v) {
      final double? x = double.tryParse(v.replaceAll(',', '.'));
      onChanged(x != null && x >= 0 && x < 1e6 ? x : null);
    },
  );
}
