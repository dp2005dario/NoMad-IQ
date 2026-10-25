// Modo coche (maqueta "Coche"): botones grandes para usar con el coche
// parado o que maneje el copiloto, y todo se puede leer en voz alta.
//
//   - Audioguía: el modo viaje te avisa al pasar por cada zona con
//     audioguía; suena por los altavoces del coche (Bluetooth o Android
//     Auto, que ve nuestro reproductor como una app de audio).
//   - Gasolina / cargador eléctrico, Aparcar y Zona ZTL: lo más cercano, de
//     OpenStreetMap, y "Ir" abre Google Maps conduciendo.
//
// La navegación giro a giro de la maqueta la hace Google Maps (un enlace,
// 0 €): hacerla nosotros costaría servidores de rutas y datos de tráfico.
// Los precios de la gasolina y las plazas libres no existen gratis para
// todo el mundo: no se inventan.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../map/location_tracker.dart';
import 'drive_api.dart';

/// Más lejos que esto, una zona ZTL no "está cerca".
const double _lezNearMeters = 15000;

/// La web con las zonas de acceso restringido de toda Europa (gratis).
final Uri lezEuropeUrl = Uri.https('urbanaccessregulations.eu', '/');

enum _Mode { guide, fuel, park, lez }

class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  late final AppServices _services = ServicesScope.of(context);

  _Mode _mode = _Mode.fuel;
  bool _electric = false;
  bool _voice = true;

  StreamSubscription<PositionFix>? _fixes;
  GeoPoint? _me;
  DriveArea? _area;
  GeoPoint? _loadingCell;
  ApiError? _error;
  bool _noLocation = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  @override
  void dispose() {
    unawaited(_fixes?.cancel());
    unawaited(_services.speaker.stop());
    super.dispose();
  }

  Future<void> _start() async {
    final LocationSource gps = _services.location;
    LocationAccess access = await gps.check();
    if (access == LocationAccess.denied) access = await gps.request();
    if (!mounted) return;
    if (access != LocationAccess.granted) {
      setState(() => _noLocation = true);
      return;
    }
    // Se sigue la posición: al cambiar de casilla (~5 km) se pide la nueva.
    _fixes = gps.watch().listen(
      (PositionFix f) {
        setState(() => _me = f.point);
        unawaited(_load(f.point));
      },
      onError: (Object _) {
        if (mounted) setState(() => _noLocation = true);
      },
    );
  }

  Future<void> _load(GeoPoint me, {bool force = false}) async {
    final GeoPoint cell = driveCellOf(me);
    if (!force && (_area?.cell == cell || _loadingCell == cell)) return;
    _loadingCell = cell;
    try {
      final DriveArea area = await _services.drive.around(me);
      if (mounted) setState(() => (_area = area, _error = null));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    } finally {
      _loadingCell = null;
    }
  }

  /// "Ir": Google Maps conduciendo hasta allí (es un enlace, gratis).
  void _go(GeoPoint p) => unawaited(
    _services.openBooking(
      Uri.https('www.google.com', '/maps/dir/', <String, String>{
        'api': '1',
        'destination':
            '${p.lat.toStringAsFixed(5)},${p.lon.toStringAsFixed(5)}',
        'travelmode': 'driving',
        'dir_action': 'navigate',
      }),
    ),
  );

  void _say(String text) {
    if (!_voice) return;
    final String lang = Localizations.localeOf(context).languageCode;
    unawaited(_services.speaker.speak(text, lang));
  }

  void _pick(_Mode m) {
    setState(() => _mode = m);
    final String? line = _headline(AppLocalizations.of(context));
    if (line != null) _say(line);
  }

  Future<void> _setTravel(bool on) async {
    final TravelModeResult result = await _services.tracker.setTravelMode(on);
    if (!mounted) return;
    final AppLocalizations t = AppLocalizations.of(context);
    setState(() {});
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(switch (result) {
            TravelModeResult.on => on ? t.travelOn : t.travelOff,
            TravelModeResult.needsAccount => t.travelNeedsAccount,
            TravelModeResult.needsLocation => t.mapLocationDenied,
            TravelModeResult.needsNotifications => t.travelNeedsNotifications,
          }),
        ),
      );
  }

  DriveKind? get _kind => switch (_mode) {
    _Mode.fuel => _electric ? DriveKind.ev : DriveKind.fuel,
    _Mode.park => DriveKind.parking,
    _Mode.lez => DriveKind.lez,
    _Mode.guide => null,
  };

  List<DriveSpot> _list() {
    final DriveArea? area = _area;
    final GeoPoint? me = _me;
    final DriveKind? kind = _kind;
    if (area == null || me == null || kind == null) return const <DriveSpot>[];
    final List<DriveSpot> all = area.of(kind, me);
    return kind == DriveKind.lez
        ? all
              .where((DriveSpot s) => s.point.distanceTo(me) < _lezNearMeters)
              .toList()
        : all;
  }

  /// La frase de la tarjeta principal (la que se lee en voz alta).
  String? _headline(AppLocalizations t) {
    final GeoPoint? me = _me;
    if (_mode == _Mode.guide) return t.driveGuideTitle;
    final List<DriveSpot> list = _list();
    if (me == null || _area == null) return null;
    if (list.isEmpty) {
      return _mode == _Mode.lez ? t.driveLezNone : t.driveNone;
    }
    final DriveSpot s = list.first;
    final String km = _distance(t, s.point.distanceTo(me));
    return switch (s.kind) {
      DriveKind.fuel => t.driveFuelAt(km),
      DriveKind.ev => t.driveEvAt(km),
      DriveKind.parking => t.driveParkAt(s.label ?? t.driveParking, km),
      DriveKind.lez => t.driveLezAt(s.label ?? 'ZTL', km),
    };
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final DriveArea? area = _area;
    return Scaffold(
      appBar: AppBar(
        title: Text(t.driveTitle),
        actions: <Widget>[
          IconButton(
            tooltip: _voice ? t.driveVoiceOff : t.driveVoiceOn,
            icon: Icon(
              _voice ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            ),
            onPressed: () {
              setState(() => _voice = !_voice);
              if (!_voice) unawaited(_services.speaker.stop());
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          // Botones grandes: se aciertan sin mirar mucho.
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 0.95,
            children: <Widget>[
              for (final _Mode m in _Mode.values)
                _ModeButton(
                  icon: _looks[m]!.$2,
                  color: _looks[m]!.$3,
                  label: _looks[m]!.$1(t),
                  selected: _mode == m,
                  onTap: () => _pick(m),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (_mode == _Mode.guide)
            ..._guide(t, text)
          else if (_noLocation)
            Text(t.cameraNoLocation, style: text.bodyLarge)
          else if (_error != null && area == null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  _error == ApiError.network
                      ? t.errorNetwork
                      : t.errorUnavailable,
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _me == null
                      ? null
                      : () => unawaited(_load(_me!, force: true)),
                  child: Text(t.guideRetry),
                ),
              ],
            )
          else if (area == null || _me == null)
            const Center(child: CircularProgressIndicator())
          else ...<Widget>[
            ..._spots(t, text, _me!),
            const SizedBox(height: 12),
            Text(
              area.attribution,
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

  List<Widget> _guide(AppLocalizations t, TextTheme text) {
    final LocationTracker tracker = _services.tracker;
    return <Widget>[
      Text(t.driveGuideTitle, style: text.titleLarge),
      const SizedBox(height: 8),
      Text(t.driveGuideBody, style: text.bodyMedium),
      const SizedBox(height: 12),
      Card(
        child: SwitchListTile(
          title: Text(t.travelMode),
          subtitle: Text(t.driveGuideSwitch),
          value: tracker.travelMode,
          onChanged: (bool on) => unawaited(_setTravel(on)),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        t.driveAndroidAuto,
        style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
      ),
    ];
  }

  List<Widget> _spots(AppLocalizations t, TextTheme text, GeoPoint me) {
    final List<DriveSpot> list = _list();
    final String? headline = _headline(t);
    return <Widget>[
      if (_mode == _Mode.fuel)
        Wrap(
          spacing: 8,
          children: <Widget>[
            ChoiceChip(
              avatar: const Icon(Icons.local_gas_station_rounded, size: 18),
              label: Text(t.driveFuel),
              selected: !_electric,
              onSelected: (_) => setState(() => _electric = false),
            ),
            ChoiceChip(
              avatar: const Icon(Icons.ev_station_rounded, size: 18),
              label: Text(t.driveElectric),
              selected: _electric,
              onSelected: (_) => setState(() => _electric = true),
            ),
          ],
        ),
      if (_mode == _Mode.fuel) const SizedBox(height: 12),
      if (list.isEmpty)
        Text(headline ?? '', style: text.bodyLarge)
      else ...<Widget>[
        _MainCard(
          color: _looks[_mode]!.$3,
          icon: _looks[_mode]!.$2,
          title: headline ?? '',
          meta: _meta(t, list.first),
          action: _mode == _Mode.lez ? t.driveLezWeb : t.driveGo,
          onAction: _mode == _Mode.lez
              ? (list.first.website == null
                    ? null
                    : () =>
                          unawaited(_services.openBooking(list.first.website!)))
              : () => _go(list.first.point),
        ),
        const SizedBox(height: 8),
        for (final DriveSpot s in list.skip(1).take(5))
          Card(
            child: ListTile(
              leading: Icon(_looks[_mode]!.$2, color: _looks[_mode]!.$3),
              title: Text(s.label ?? _looks[_mode]!.$1(t)),
              subtitle: Text(
                <String>[
                  _distance(t, s.point.distanceTo(me)),
                  ?_meta(t, s),
                ].join(' · '),
              ),
              trailing: _mode == _Mode.lez
                  ? null
                  : IconButton.outlined(
                      tooltip: t.driveGo,
                      icon: const Icon(Icons.navigation_rounded),
                      onPressed: () => _go(s.point),
                    ),
            ),
          ),
      ],
      if (_mode == _Mode.lez) ...<Widget>[
        const SizedBox(height: 12),
        Text(t.driveLezWarning, style: text.bodyMedium),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.open_in_new_rounded),
          label: Text(t.driveLezEurope),
          onPressed: () => unawaited(_services.openBooking(lezEuropeUrl)),
        ),
      ],
    ];
  }

  String? _meta(AppLocalizations t, DriveSpot s) {
    final List<String> parts = <String>[
      if (s.kind == DriveKind.fuel || s.kind == DriveKind.ev) ?s.brand,
      if (s.fee == true) t.nearbyPaid,
      if (s.fee == false) t.nearbyNoFee,
      if (s.capacity != null) t.driveCapacity(s.capacity!),
      if (s.openingHours == '24/7') t.driveAlwaysOpen else ?s.openingHours,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// "800 m" o "1,8 km" (con la coma o el punto de cada idioma).
String _distance(AppLocalizations t, double meters) => meters < 1000
    ? t.nearbyMeters(meters.round())
    : t.driveKm(NumberFormat('0.0', t.localeName).format(meters / 1000));

final Map<_Mode, (String Function(AppLocalizations), IconData, Color)> _looks =
    <_Mode, (String Function(AppLocalizations), IconData, Color)>{
      _Mode.guide: (
        (AppLocalizations t) => t.driveGuide,
        Icons.headphones_rounded,
        NomadColors.group,
      ),
      _Mode.fuel: (
        (AppLocalizations t) => t.driveFuel,
        Icons.local_gas_station_rounded,
        NomadColors.money,
      ),
      _Mode.park: (
        (AppLocalizations t) => t.drivePark,
        Icons.local_parking_rounded,
        NomadColors.flights,
      ),
      _Mode.lez: (
        (AppLocalizations t) => t.driveLez,
        Icons.do_not_disturb_on_rounded,
        NomadColors.safety,
      ),
    };

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: selected ? color : NomadColors.surface,
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(
              icon,
              size: 30,
              color: selected ? NomadColors.background : color,
            ),
            const SizedBox(height: 6),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: selected ? NomadColors.background : null,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _MainCard extends StatelessWidget {
  const _MainCard({
    required this.color,
    required this.icon,
    required this.title,
    required this.meta,
    required this.action,
    required this.onAction,
  });

  final Color color;
  final IconData icon;
  final String title;
  final String? meta;
  final String action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: NomadColors.background),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(title, style: text.titleLarge)),
              ],
            ),
            if (meta != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                meta!,
                style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.navigation_rounded),
              label: Text(action),
              onPressed: onAction,
            ),
          ],
        ),
      ),
    );
  }
}
