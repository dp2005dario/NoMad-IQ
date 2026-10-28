// La pestaña del Mapa (maqueta 3): el mapa de la ciudad con las zonas de
// ECLIPTA, tu posición, el aviso al entrar en una zona y el acceso a su
// audioguía.
//
// La pantalla solo DIBUJA y reparte toques. Lo que hay que hacer en cada
// caso lo decide MapModel (map_model.dart).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../home/feature.dart';
import 'geo.dart';
import 'location.dart';
import 'location_tracker.dart';
import 'map_model.dart';
import 'map_style.dart';
import 'map_surface.dart';
import 'weather_overlay.dart';
import 'street_sheet.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.clock = DateTime.now});

  /// Reloj (los tests lo fijan para elegir día o noche).
  final DateTime Function() clock;

  /// Si no sabemos dónde estás: la Puerta del Sol de Madrid, como en las
  /// maquetas. En cuanto el GPS te encuentra, el mapa va a tu posición.
  static const GeoPoint defaultCenter = GeoPoint(40.41694, -3.70361);

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  /// Clima de adorno del mapa (solo visual).
  MapWeather _weather = MapWeather.sun;

  late AppServices _services;
  MapModel? _model;
  SessionStatus? _modelFor;
  MapSurfaceController? _map;
  Timer? _idleDebounce;
  Timer? _lookTimer;
  // ¿Se está viendo la pestaña del mapa? (ver didChangeDependencies)
  bool _wasVisible = true;

  MapLook _chosenLook = MapLook.auto;
  bool _tilted = true;
  final TextEditingController _search = TextEditingController();

  // Lo último que se mandó al mapa, para no repetir trabajo.
  int _sentZones = -1;
  GeoPoint? _sentMe;
  Zone? _lastEntered;

  // Caché del estilo: solo se recalcula si cambia el aspecto o el idioma.
  (MapLook, String)? _styleKey;
  Map<String, Object?> _style = const <String, Object?>{};

  @override
  void initState() {
    super.initState();
    // El modo "auto" cambia solo al atardecer y al anochecer.
    _lookTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_chosenLook == MapLook.auto && mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _services = ServicesScope.of(context);
    // Si el invitado crea su cuenta, el mapa se rehace con zonas y envío de
    // posiciones (que son solo para cuentas).
    final SessionStatus status = SessionScope.of(context).status;
    if (_model == null || status != _modelFor) _rebuildModel(status);
    // Al volver a la pestaña (las pestañas ocultas tienen los "tickers"
    // apagados) repasamos lo que se vio mientras estaba oculta.
    final bool visible = TickerMode.valuesOf(context).enabled;
    if (visible && !_wasVisible) {
      _sentZones = -1;
      _sentMe = null;
      _syncMap();
      _scheduleIdle();
    }
    _wasVisible = visible;
  }

  void _rebuildModel(SessionStatus status) {
    _model?.removeListener(_onModel);
    _model?.dispose();
    _modelFor = status;
    final MapModel model = MapModel(
      geo: status == SessionStatus.signedIn ? _services.geo : null,
      tracker: _services.tracker,
      clock: widget.clock,
    )..onFocus = _focus;
    model.addListener(_onModel);
    _model = model;
    _sentZones = -1;
    unawaited(model.resumeLocation());
    _scheduleIdle();
  }

  @override
  void dispose() {
    _idleDebounce?.cancel();
    _lookTimer?.cancel();
    _model?.removeListener(_onModel);
    _model?.dispose();
    _search.dispose();
    super.dispose();
  }

  MapModel get _m => _model!;

  // --- Mapa ↔ modelo -------------------------------------------------------

  void _onReady(MapSurfaceController controller) {
    // Se llama también cada vez que cambia el estilo (día/noche): el mapa
    // empieza "vacío" y hay que volver a darle zonas y posición.
    _map = controller;
    _sentZones = -1;
    _sentMe = null;
    _syncMap();
    _scheduleIdle();
  }

  void _onModel() {
    final Zone? entered = _m.entered;
    if (entered != null && entered.id != _lastEntered?.id) {
      // Una vibración suave, como en la maqueta: "has llegado".
      unawaited(HapticFeedback.mediumImpact());
    }
    _lastEntered = entered;
    _syncMap();
    if (mounted) setState(() {});
  }

  void _syncMap() {
    final MapSurfaceController? map = _map;
    if (map == null) return;
    final int revision = Object.hashAll(<Object?>[
      _m.selected?.id,
      ..._m.zones.map((Zone z) => z.id),
    ]);
    if (revision != _sentZones) {
      _sentZones = revision;
      unawaited(map.showZones(_m.zonesGeoJson()));
    }
    if (_m.me != _sentMe) {
      _sentMe = _m.me;
      unawaited(map.showMe(_m.me));
    }
  }

  /// Espera a que el mapa se quede quieto un momento antes de pedir zonas:
  /// mientras arrastras con el dedo no se pide nada.
  void _scheduleIdle() {
    _idleDebounce?.cancel();
    _idleDebounce = Timer(const Duration(milliseconds: 350), () async {
      final MapSurfaceController? map = _map;
      if (map == null || !mounted) return;
      await _m.onViewChanged(await map.visibleBox());
    });
  }

  void _focus(GeoPoint target, double? zoom) {
    // Con la pestaña oculta no movemos la cámara: saltaría al volver.
    if (!_wasVisible) return;
    unawaited(_map?.flyTo(target, zoom: zoom));
  }

  Map<String, Object?> _currentStyle(String language) {
    final MapLook look = resolveLook(_chosenLook, widget.clock());
    final (MapLook, String) key = (look, language);
    if (key != _styleKey) {
      _styleKey = key;
      _style = buildMapStyle(
        look: look,
        language: language,
        tilesUrl: _services.tilesUrl,
        glyphsUrl: _services.glyphsUrl,
      );
    }
    return _style;
  }

  // --- Acciones --------------------------------------------------------------

  /// "Ver la calle de verdad": fotos reales del centro de lo que se ve.
  Future<void> _openStreet() async {
    final GeoBox? box = await _map?.visibleBox();
    if (!mounted) return;
    final GeoPoint center = box == null
        ? (_m.me ?? MapScreen.defaultCenter)
        : GeoPoint(
            (box.minLat + box.maxLat) / 2,
            (box.minLon + box.maxLon) / 2,
          );
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext sheet) => StreetSheet(
        point: center,
        load: _services.streetPhotos.near,
        openLink: _services.openBooking,
      ),
    );
  }

  Future<void> _myLocation() async {
    final GeoPoint? me = _m.me;
    if (me != null) {
      _focus(me, 16.5);
      return;
    }
    await _enableLocation();
  }

  Future<void> _enableLocation() async {
    final LocationAccess access = await _m.enableLocation();
    if (!mounted || access == LocationAccess.granted) return;
    final AppLocalizations t = AppLocalizations.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          access == LocationAccess.serviceOff
              ? t.mapLocationServiceOff
              : t.mapLocationDenied,
        ),
        action: access == LocationAccess.deniedForever
            ? SnackBarAction(
                label: t.mapOpenSettings,
                onPressed: () => unawaited(_m.openLocationSettings()),
              )
            : null,
      ),
    );
  }

  /// Encender o apagar el modo viaje, explicando qué falta si no se puede.
  Future<void> _setTravel(bool on) async {
    final TravelModeResult result = await _services.tracker.setTravelMode(on);
    if (!mounted) return;
    final AppLocalizations t = AppLocalizations.of(context);
    final String text = switch (result) {
      TravelModeResult.on => on ? t.travelOn : t.travelOff,
      TravelModeResult.needsAccount => t.travelNeedsAccount,
      TravelModeResult.needsLocation => t.mapLocationDenied,
      TravelModeResult.needsNotifications => t.travelNeedsNotifications,
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          action: result == TravelModeResult.needsNotifications
              ? SnackBarAction(
                  label: t.mapOpenSettings,
                  onPressed: () => unawaited(_m.openLocationSettings()),
                )
              : null,
        ),
      );
  }

  void _toggleTilt() {
    setState(() => _tilted = !_tilted);
    unawaited(_map?.setTilt(_tilted ? 55 : 0));
  }

  void _openGuide(Zone zone) {
    unawaited(context.push(Routes.audioguide(zone.id, zone.name)));
  }

  // --- Dibujo ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String language = Localizations.localeOf(context).languageCode;
    final Zone? selected = _m.selected;
    final Zone? entered = _m.entered;
    final String query = _search.text;

    return Scaffold(
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: _services.mapSurface(
              MapSurfaceSpec(
                style: _currentStyle(language),
                initialCenter: MapScreen.defaultCenter,
                initialZoom: 15,
                onReady: _onReady,
                onIdle: _scheduleIdle,
                onTap: (GeoPoint p) {
                  FocusScope.of(context).unfocus();
                  _m.tapAt(p);
                },
              ),
            ),
          ),
          // El clima de adorno (Sol/Nubes/Lluvia) va encima del mapa.
          Positioned.fill(child: WeatherOverlay(weather: _weather)),
          SafeArea(
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _SearchBox(
                    controller: _search,
                    hint: t.mapSearchHint,
                    onChanged: (_) => setState(() {}),
                  ),
                  if (query.trim().isNotEmpty)
                    _SearchResults(
                      zones: _m.search(query),
                      empty: t.mapSearchNoResults(query.trim()),
                      onPick: (Zone z) {
                        _search.clear();
                        FocusScope.of(context).unfocus();
                        _m.focusZone(z);
                      },
                    )
                  else ...<Widget>[
                    const SizedBox(height: 10),
                    _ViewControls(
                      look: _chosenLook,
                      tilted: _tilted,
                      onLook: (MapLook l) => setState(() => _chosenLook = l),
                      onTilt: _toggleTilt,
                      weather: _weather,
                      onWeather: (MapWeather w) => setState(() => _weather = w),
                    ),
                    const SizedBox(height: 10),
                    if (entered != null)
                      _EnteredBanner(
                        zone: entered,
                        onOpen: () => _openGuide(entered),
                        onClose: _m.dismissEntered,
                      )
                    else
                      _StatusPill(status: _m.status),
                  ],
                ],
              ),
            ),
          ),
          PositionedDirectional(
            start: 0,
            end: 0,
            // Deja sitio al botón grande de la cámara, que "muerde" el mapa.
            bottom: 36,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 16,
                    end: 16,
                    bottom: 10,
                  ),
                  child: Row(
                    children: <Widget>[
                      // El modo viaje solo tiene sentido con el GPS ya
                      // encendido y con cuenta (el servidor avisa a cuentas).
                      if (_m.tracking && _services.tracker.canTravel)
                        _TravelChip(
                          on: _services.tracker.travelMode,
                          onChanged: (bool on) => unawaited(_setTravel(on)),
                        ),
                      const Spacer(),
                      FloatingActionButton.extended(
                        heroTag: 'map-street',
                        elevation: 1,
                        backgroundColor: NomadColors.surfaceHigh,
                        foregroundColor: NomadColors.text,
                        extendedPadding: const EdgeInsetsDirectional.only(
                          start: 12,
                          end: 16,
                        ),
                        onPressed: () => unawaited(_openStreet()),
                        icon: const Icon(Icons.streetview_rounded),
                        label: Text(t.streetViewButton),
                      ),
                      const SizedBox(width: 8),
                      FloatingActionButton.small(
                        heroTag: 'map-me',
                        tooltip: t.mapMyLocation,
                        elevation: 1,
                        backgroundColor: NomadColors.surfaceHigh,
                        foregroundColor: _m.tracking
                            ? NomadColors.mint
                            : NomadColors.text,
                        onPressed: () => unawaited(_myLocation()),
                        child: Icon(
                          _m.tracking
                              ? Icons.my_location_rounded
                              : Icons.location_searching_rounded,
                        ),
                      ),
                    ],
                  ),
                ),
                if (selected != null)
                  _ZonePanel(
                    zone: selected,
                    here: selected.id == _m.entered?.id,
                    onListen: () => _openGuide(selected),
                    onClose: () => _m.select(null),
                  )
                else ...<Widget>[
                  if (!_m.tracking) _LocationCard(onEnable: _enableLocation),
                  const SizedBox(height: 10),
                  const _MapShortcuts(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Piezas de la pantalla ---------------------------------------------------

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: NomadColors.surface.withValues(alpha: 0.94),
      shape: const StadiumBorder(side: BorderSide(color: NomadColors.outline)),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: const Icon(Icons.search_rounded),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
        ),
      ),
    );
  }
}

class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.zones,
    required this.empty,
    required this.onPick,
  });

  final List<Zone> zones;
  final String empty;
  final ValueChanged<Zone> onPick;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: zones.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    empty,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                )
              : ListView(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  children: <Widget>[
                    for (final Zone z in zones)
                      ListTile(
                        leading: Icon(
                          _kindIcon(z.kind),
                          color: _kindColor(z.kind),
                        ),
                        title: Text(z.name),
                        subtitle: Text(zoneKindLabel(t, z.kind)),
                        onTap: () => onPick(z),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _ViewControls extends StatelessWidget {
  const _ViewControls({
    required this.look,
    required this.tilted,
    required this.onLook,
    required this.onTilt,
    required this.weather,
    required this.onWeather,
  });

  final MapLook look;
  final bool tilted;
  final ValueChanged<MapLook> onLook;
  final VoidCallback onTilt;
  final MapWeather weather;
  final ValueChanged<MapWeather> onWeather;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    String label(MapLook l) => switch (l) {
      MapLook.auto => t.mapLookAuto,
      MapLook.day => t.mapLookDay,
      MapLook.dusk => t.mapLookDusk,
      MapLook.night => t.mapLookNight,
    };
    // Wrap: si un idioma tiene palabras largas, los botones bajan de línea
    // en vez de salirse de la pantalla.
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Semantics(
          label: t.mapLookTitle,
          child: SegmentedButton<MapLook>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              backgroundColor: NomadColors.surface.withValues(alpha: 0.94),
              selectedBackgroundColor: NomadColors.mint,
              selectedForegroundColor: NomadColors.background,
              visualDensity: VisualDensity.compact,
            ),
            segments: <ButtonSegment<MapLook>>[
              for (final MapLook l in MapLook.values)
                ButtonSegment<MapLook>(value: l, label: Text(label(l))),
            ],
            selected: <MapLook>{look},
            onSelectionChanged: (Set<MapLook> s) => onLook(s.first),
          ),
        ),
        Semantics(
          label: t.mapWeatherTitle,
          child: SegmentedButton<MapWeather>(
            showSelectedIcon: false,
            style: SegmentedButton.styleFrom(
              backgroundColor: NomadColors.surface.withValues(alpha: 0.94),
              selectedBackgroundColor: NomadColors.mint,
              selectedForegroundColor: NomadColors.background,
              visualDensity: VisualDensity.compact,
            ),
            segments: <ButtonSegment<MapWeather>>[
              ButtonSegment<MapWeather>(
                value: MapWeather.sun,
                icon: const Icon(Icons.wb_sunny_rounded),
                tooltip: t.mapWeatherSun,
              ),
              ButtonSegment<MapWeather>(
                value: MapWeather.clouds,
                icon: const Icon(Icons.cloud_rounded),
                tooltip: t.mapWeatherClouds,
              ),
              ButtonSegment<MapWeather>(
                value: MapWeather.rain,
                icon: const Icon(Icons.water_drop_rounded),
                tooltip: t.mapWeatherRain,
              ),
            ],
            selected: <MapWeather>{weather},
            onSelectionChanged: (Set<MapWeather> s) => onWeather(s.first),
          ),
        ),
        Tooltip(
          message: t.mapTiltTooltip,
          child: FilledButton.tonal(
            style: FilledButton.styleFrom(
              minimumSize: const Size(56, 40),
              backgroundColor: NomadColors.surface.withValues(alpha: 0.94),
              foregroundColor: NomadColors.mint,
            ),
            onPressed: onTilt,
            // "3D" y "2D" son iguales en todos los idiomas.
            child: Text(tilted ? '3D' : '2D'),
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});

  final ZonesStatus status;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String? text = switch (status) {
      ZonesStatus.loading => t.mapZonesLoading,
      ZonesStatus.tooFar => t.mapZonesTooFar,
      ZonesStatus.truncated => t.mapZonesTruncated,
      ZonesStatus.error => t.mapZonesError,
      ZonesStatus.signedOut => t.mapZonesGuest,
      ZonesStatus.idle || ZonesStatus.ready => null,
    };
    if (text == null) return const SizedBox.shrink();
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Semantics(
        liveRegion: true,
        child: DecoratedBox(
          decoration: ShapeDecoration(
            color: NomadColors.surface.withValues(alpha: 0.94),
            shape: const StadiumBorder(),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Text(text, style: const TextStyle(fontSize: 13)),
          ),
        ),
      ),
    );
  }
}

class _EnteredBanner extends StatelessWidget {
  const _EnteredBanner({
    required this.zone,
    required this.onOpen,
    required this.onClose,
  });

  final Zone zone;
  final VoidCallback onOpen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    return Semantics(
      liveRegion: true,
      child: Material(
        color: NomadColors.mint,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 4, 12),
            child: Row(
              children: <Widget>[
                const Icon(
                  Icons.headphones_rounded,
                  color: NomadColors.background,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        t.mapEnteredTitle(zone.name),
                        style: const TextStyle(
                          color: NomadColors.background,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        t.mapEnteredBody,
                        style: const TextStyle(color: NomadColors.background),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: m.closeButtonTooltip,
                  color: NomadColors.background,
                  onPressed: onClose,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ZonePanel extends StatelessWidget {
  const _ZonePanel({
    required this.zone,
    required this.here,
    required this.onListen,
    required this.onClose,
  });

  final Zone zone;

  /// true si estás dentro de esta zona ahora mismo.
  final bool here;
  final VoidCallback onListen;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    final Color color = _kindColor(zone.kind);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Card(
        color: NomadColors.surface,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(18, 14, 8, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(_kindIcon(zone.kind), color: color, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      (here ? t.mapKickerHere : zoneKindLabel(t, zone.kind))
                          .toUpperCase(),
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: m.closeButtonTooltip,
                    onPressed: onClose,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              Text(zone.name, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 10),
                child: zone.kind.hasAudioguide
                    ? FilledButton.icon(
                        onPressed: onListen,
                        icon: const Icon(Icons.headphones_rounded),
                        label: Text(t.mapListen),
                      )
                    : Text(
                        t.mapNoAudioguide,
                        style: const TextStyle(color: NomadColors.textMuted),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  const _LocationCard({required this.onEnable});

  final Future<void> Function() onEnable;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Card(
        color: NomadColors.surface,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const FlyraAvatar(size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t.mapLocationWhy,
                      style: const TextStyle(color: NomadColors.textMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => unawaited(onEnable()),
                icon: const Icon(Icons.my_location_rounded),
                label: Text(t.mapEnableLocation),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// El interruptor del "modo viaje": avisos aunque cierres la app.
class _TravelChip extends StatelessWidget {
  const _TravelChip({required this.on, required this.onChanged});

  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Tooltip(
      message: t.travelExplain,
      child: FilterChip(
        selected: on,
        showCheckmark: false,
        avatar: Icon(
          Icons.luggage_rounded,
          size: 18,
          color: on ? NomadColors.background : NomadColors.mint,
        ),
        label: Text(t.travelMode),
        labelStyle: TextStyle(
          color: on ? NomadColors.background : NomadColors.text,
          fontWeight: FontWeight.w600,
        ),
        backgroundColor: NomadColors.surfaceHigh,
        selectedColor: NomadColors.mint,
        onSelected: onChanged,
      ),
    );
  }
}

/// La tira de atajos de la maqueta (Cerca de ti, Moverte, Radar...).
class _MapShortcuts extends StatelessWidget {
  const _MapShortcuts();

  static const List<Feature> _features = <Feature>[
    Feature.nearby,
    Feature.transport,
    Feature.radar,
    Feature.queues,
    Feature.assistant,
  ];

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: <Widget>[
          for (final Feature f in _features)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ActionChip(
                avatar: Icon(f.icon, color: f.color, size: 18),
                label: Text(f.label(t)),
                backgroundColor: NomadColors.surface.withValues(alpha: 0.94),
                side: const BorderSide(color: NomadColors.outline),
                onPressed: () => unawaited(
                  context.push(switch (f) {
                    Feature.nearby => Routes.nearby,
                    Feature.transport => Routes.transport(),
                    Feature.radar => Routes.radar(),
                    Feature.queues => Routes.queues(),
                    Feature.assistant => Routes.assistant,
                    _ => Routes.home,
                  }),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- Textos y colores por tipo de zona ---------------------------------------

String zoneKindLabel(AppLocalizations t, ZoneKind kind) => switch (kind) {
  ZoneKind.cityCenter => t.zoneKindCityCenter,
  ZoneKind.touristArea => t.zoneKindTouristArea,
  ZoneKind.airport => t.zoneKindAirport,
  ZoneKind.restricted => t.zoneKindRestricted,
};

Color _kindColor(ZoneKind kind) => switch (kind) {
  ZoneKind.cityCenter || ZoneKind.touristArea => ZoneColors.audioguide,
  ZoneKind.airport => ZoneColors.airport,
  ZoneKind.restricted => ZoneColors.restricted,
};

IconData _kindIcon(ZoneKind kind) => switch (kind) {
  ZoneKind.cityCenter => Icons.location_city_rounded,
  ZoneKind.touristArea => Icons.account_balance_rounded,
  ZoneKind.airport => Icons.flight_rounded,
  ZoneKind.restricted => Icons.do_not_disturb_on_rounded,
};
