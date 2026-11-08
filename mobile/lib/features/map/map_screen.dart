// La pestaña del Mapa, igual que la maqueta "Mapa 3D": el mapa de verdad de
// la ciudad (MapLibre, con edificios en 3D) y encima, como en la maqueta:
//   1. Arriba: buscar, tu foto (abre Ajustes) y tus sellos nuevos (abre el
//      Pasaporte).
//   2. 3D/2D, girar el mapa y la brújula (toca para mirar al norte).
//   3. El tiempo de ahora (MET Norway) y la hora real.
//   4. Flyra a la derecha (abre el Asistente) y su bocadillo cuando entras
//      en una zona ("Has entrado en…", con vibración suave).
//   5. Abajo, la zona: dónde estás o la que tocaste, con su audioguía, y los
//      atajos Cerca de ti, Radar y Asistente.
//
// La pantalla solo DIBUJA y reparte toques. Lo que hay que hacer en cada
// caso lo decide MapModel (map_model.dart).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../core/motion.dart';
import '../../core/settings.dart';
import '../../widgets/user_avatar.dart';
import '../camera/stamps.dart';
import '../flyra/flyra_mini.dart';
import '../home/home_screen.dart' show displayName;
import '../settings/profile_photo.dart';
import 'geocode_api.dart';
import '../radar/radar_api.dart';
import 'geo.dart';
import 'location.dart';
import 'map_model.dart';
import 'map_style.dart';
import 'map_surface.dart';
import 'weather_overlay.dart';

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
  /// El tiempo que hace de verdad donde miras (MET Norway). Se pone solo,
  /// como en la maqueta: no hay botones de sol, nubes o lluvia.
  MapWeather _weather = MapWeather.sun;

  /// La hora de ahora del tiempo (temperatura y símbolo), para la etiqueta.
  RainHour? _now;

  /// La casilla de ~5 km del último tiempo pedido y cuándo se pidió (se
  /// vuelve a pedir al cambiar de casilla o a los 15 minutos).
  GeoPoint? _weatherCell;
  DateTime? _weatherAt;

  late AppServices _services;
  MapModel? _model;
  SessionStatus? _modelFor;
  MapSurfaceController? _map;
  Timer? _idleDebounce;
  Timer? _lookTimer;

  /// La luz (día, tarde, noche) va sola por la hora, como en la maqueta.
  static const MapLook _chosenLook = MapLook.auto;
  bool _tilted = true;
  final TextEditingController _search = TextEditingController();

  /// Hacia dónde mira el mapa (grados; 0 = norte), para la brújula.
  double _bearing = 0;

  /// Los sitios que encontró el buscador (calles, monumentos...).
  List<GeoPlace> _places = const <GeoPlace>[];
  String? _placesFor;
  bool _searching = false;

  /// El bocadillo de Flyra: la zona en la que acabas de entrar.
  Zone? _bubble;

  /// Cuántos avisos de Flyra habías visto al tocarla (el punto rojo sale
  /// si hay alguno nuevo).
  static int _seenNotes = 0;

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
    FlyraNotes.instance.addListener(_changed);
    ProfilePhotoController.instance.addListener(_changed);
    // El modo "auto" cambia solo al atardecer y al anochecer.
    _lookTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
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
    FlyraNotes.instance.removeListener(_changed);
    ProfilePhotoController.instance.removeListener(_changed);
    super.dispose();
  }

  MapModel get _m => _model!;

  void _changed() {
    if (mounted) setState(() {});
  }

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
      _bubble = entered;
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
      final GeoBox? box = await map.visibleBox();
      await _m.onViewChanged(box);
      if (box != null) {
        unawaited(
          _updateWeather(
            GeoPoint(
              (box.minLat + box.maxLat) / 2,
              (box.minLon + box.maxLon) / 2,
            ),
          ),
        );
      }
    });
  }

  /// Pone el tiempo real de la zona que miras. Si falla (sin internet),
  /// se queda el que había: es solo el adorno del mapa.
  Future<void> _updateWeather(GeoPoint center) async {
    final GeoPoint cell = rainCellOf(center);
    final DateTime now = widget.clock();
    final DateTime? at = _weatherAt;
    final GeoPoint? last = _weatherCell;
    if (last != null &&
        last.lat == cell.lat &&
        last.lon == cell.lon &&
        at != null &&
        now.difference(at) < const Duration(minutes: 15)) {
      return;
    }
    _weatherCell = cell;
    _weatherAt = now;
    try {
      final RainForecast f = await _services.radar.rain(center);
      if (f.hours.isEmpty || !mounted) return;
      final RainHour h = f.hours.first;
      setState(() {
        _now = h;
        _weather = mapWeatherFrom(h.rainMm, h.symbol);
      });
    } on Object {
      _weatherAt = null; // se reintenta la próxima vez que se mueva
    }
  }

  void _focus(GeoPoint target, double? zoom) {
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

  void _toggleTilt() {
    setState(() => _tilted = !_tilted);
    unawaited(_map?.setTilt(_tilted ? 55 : 0));
  }

  /// "Girar el mapa": 45° más cada toque, como en la maqueta.
  void _rotate() {
    final double to = (_bearing + 45) % 360;
    setState(() => _bearing = to);
    unawaited(_map?.setBearing(to));
  }

  /// La brújula: vuelve a poner el norte arriba.
  void _north() {
    setState(() => _bearing = 0);
    unawaited(_map?.setBearing(0));
  }

  void _openGuide(Zone zone) {
    final GeoBox b = zone.bounds;
    unawaited(
      context.push(
        Routes.audioguide(
          zone.id,
          zone.name,
          lat: (b.minLat + b.maxLat) / 2,
          lon: (b.minLon + b.maxLon) / 2,
        ),
      ),
    );
  }

  /// Buscar calles y monumentos (OpenStreetMap, solo con cuenta) cerca de
  /// lo que miras. Las zonas de ECLIPTA se buscan sin red, al escribir.
  Future<void> _searchPlaces(String query) async {
    final String q = query.trim();
    if (q.length < 3 || q == _placesFor) return;
    if (SessionScope.of(context).status != SessionStatus.signedIn) return;
    _placesFor = q;
    setState(() => _searching = true);
    final GeoBox? box = await _map?.visibleBox();
    final GeoPoint near = box == null
        ? (_m.me ?? MapScreen.defaultCenter)
        : GeoPoint(
            (box.minLat + box.maxLat) / 2,
            (box.minLon + box.maxLon) / 2,
          );
    List<GeoPlace> found = const <GeoPlace>[];
    try {
      found = await _services.geocode.search(q, near: near);
    } on Object {
      // Sin red: solo las zonas.
    }
    if (!mounted || _placesFor != q) return;
    setState(() {
      _places = found;
      _searching = false;
    });
  }

  void _clearSearch() {
    _search.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _places = const <GeoPlace>[];
      _placesFor = null;
      _searching = false;
    });
  }

  /// Sellos nuevos desde la última vez que abriste el Pasaporte.
  int _newStamps() {
    final List<Stamp> all = StampBook(_services.prefs).all();
    final DateTime? seen = DateTime.tryParse(
      _services.prefs.readData(LocalData.passportSeen) ?? '',
    );
    if (seen == null) return all.length;
    return all.where((Stamp s) => s.date.isAfter(seen)).length;
  }

  // --- Dibujo ----------------------------------------------------------------

  /// "Ahora: tarde · lluvia ligera · 14°", como en la maqueta.
  String _weatherLabel(MapLook look) {
    final String part = switch (look) {
      MapLook.night => 'noche',
      MapLook.dusk => 'tarde',
      _ => 'día',
    };
    final RainHour? h = _now;
    if (h == null) return 'Ahora: $part';
    final String s = h.symbol ?? '';
    final String sky = switch (_weather) {
      MapWeather.rain => h.rainMm < 1 ? 'lluvia ligera' : 'lluvia',
      MapWeather.clouds => s.contains('fog') ? 'niebla' : 'nublado',
      MapWeather.sun => look == MapLook.night ? 'despejado' : 'sol',
    };
    final double? c = h.tempC;
    return 'Ahora: $part · $sky${c == null ? '' : ' · ${c.round()}°'}';
  }

  /// El dibujo del tiempo (las mismas líneas que la maqueta).
  String _weatherIcon(MapLook look) => switch (_weather) {
    MapWeather.rain => 'M7 14a4 4 0 0 1 0-8 5.5 5.5 0 0 1 10.5 1.5A3.3 3.3 0 0 1 17 14zM8 17l-1 3M12 17l-1 3M16 17l-1 3',
    MapWeather.clouds when (_now?.symbol ?? '').contains('fog') =>
      'M4 9h16M2 13h20M5 17h14',
    MapWeather.clouds =>
      'M7 18a4 4 0 0 1 0-8 5.5 5.5 0 0 1 10.5 1.5A3.3 3.3 0 0 1 17 18z',
    MapWeather.sun when look == MapLook.night =>
      'M20 14.5A8 8 0 1 1 9.5 4 6.5 6.5 0 0 0 20 14.5z',
    MapWeather.sun => 'M17 12a5 5 0 1 1-10 0a5 5 0 1 1 10 0M12 1v2M12 21v2M3 12H1M23 12h-2M5 5l1.4 1.4M17.6 17.6L19 19M5 19l1.4-1.4M17.6 6.4L19 5',
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String language = Localizations.localeOf(context).languageCode;
    final MapLook look = resolveLook(_chosenLook, widget.clock());
    final DateTime now = widget.clock();
    final String query = _search.text;
    final SessionController session = SessionScope.of(context);
    final String name = displayName(session.user?.email) ?? '';
    final bool newNotes = FlyraNotes.instance.count > _seenNotes;
    final int stamps = _newStamps();
    final Zone? bubble = _bubble;

    return Scaffold(
      backgroundColor: NomadColors.background,
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
                onBearing: (double b) {
                  if ((b - _bearing).abs() > 0.5 && mounted) {
                    setState(() => _bearing = b);
                  }
                },
                onTap: (GeoPoint p) {
                  FocusScope.of(context).unfocus();
                  _m.tapAt(p);
                },
              ),
            ),
          ),
          // El tiempo de verdad (sol, nubes o lluvia) va encima del mapa.
          Positioned.fill(child: WeatherOverlay(weather: _weather)),
          SafeArea(
            bottom: false,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 16,
                  right: 16,
                  top: 18,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: _SearchBox(
                              controller: _search,
                              onChanged: (_) => setState(() {}),
                              onSubmit: (String q) =>
                                  unawaited(_searchPlaces(q)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _Me(
                            name: name,
                            photoUrl: session.user?.photoUrl,
                            onTap: () =>
                                unawaited(context.push(Routes.settings)),
                          ),
                          const SizedBox(width: 10),
                          _Stamps(
                            count: stamps,
                            onTap: () async {
                              await context.push(Routes.passport);
                              if (mounted) setState(() {});
                            },
                          ),
                        ],
                      ),
                      if (query.trim().isNotEmpty)
                        _SearchResults(
                          zones: _m.search(query),
                          places: _placesFor == query.trim()
                              ? _places
                              : const <GeoPlace>[],
                          searching: _searching,
                          empty: t.mapSearchNoResults(query.trim()),
                          onZone: (Zone z) {
                            _clearSearch();
                            _m.focusZone(z);
                          },
                          onPlace: (GeoPlace p) {
                            _clearSearch();
                            _focus(p.point, 17);
                          },
                        )
                      else ...<Widget>[
                        const SizedBox(height: 10),
                        Row(
                          children: <Widget>[
                            _Glass(
                              height: 40,
                              radius: 14,
                              tooltip: t.mapTiltTooltip,
                              onTap: _toggleTilt,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              child: Text(
                                // "3D" y "2D" son iguales en todos los idiomas.
                                _tilted ? '3D' : '2D',
                                style: const TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFFF2F5F3),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _Glass(
                              height: 40,
                              width: 40,
                              radius: 14,
                              tooltip: 'Girar el mapa',
                              onTap: _rotate,
                              child: _svg(
                                'M20 12a8 8 0 1 1-2.3-5.7M20 4v5h-5',
                                const Color(0xFFF2F5F3),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _Glass(
                              height: 40,
                              width: 40,
                              radius: 20,
                              tooltip: 'Mirar al norte',
                              onTap: _north,
                              child: AnimatedRotation(
                                // La aguja roja apunta siempre al norte.
                                turns: -_bearing / 360,
                                duration: const Duration(milliseconds: 300),
                                child: SvgPicture.string(
                                  _compass,
                                  width: 26,
                                  height: 26,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Tooltip(
                          message: t.mapWeatherSource,
                          child: Semantics(
                            liveRegion: true,
                            label: t.mapWeatherSource,
                            child: _Glass(
                              height: 34,
                              radius: 14,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  _svg(
                                    _weatherIcon(look),
                                    NomadColors.mint,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 7),
                                  Text(
                                    _weatherLabel(look),
                                    style: const TextStyle(
                                      fontFamily: 'Manrope',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFFF2F5F3),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width - 108,
                          ),
                          child: _Glass(
                            radius: 14,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            minHeight: 28,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const _Dot(NomadColors.mint, 7),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    'Automático · hora real '
                                    '${now.hour.toString().padLeft(2, '0')}:'
                                    '${now.minute.toString().padLeft(2, '0')}'
                                    ' + tiempo real',
                                    style: const TextStyle(
                                      fontFamily: 'Manrope',
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFDCE5E9),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Flyra: abre el Asistente. El punto rojo = aviso nuevo.
                if (query.trim().isEmpty)
                  Positioned(
                    right: 14,
                    top: 184,
                    child: _FlyraButton(
                      badge: newNotes,
                      onTap: () {
                        setState(() => _seenNotes = FlyraNotes.instance.count);
                        unawaited(context.push(Routes.assistant));
                      },
                    ),
                  ),
                if (bubble != null && query.trim().isEmpty)
                  Positioned(
                    left: 16,
                    right: 16,
                    top: 252,
                    child: _EnteredBubble(
                      key: ValueKey<String>('bubble-${bubble.id}'),
                      zone: bubble,
                      onOpen: () => _openGuide(bubble),
                      onDone: () {
                        if (mounted) setState(() => _bubble = null);
                      },
                    ),
                  ),
              ],
            ),
          ),
          PositionedDirectional(
            start: 0,
            end: 0,
            // Deja sitio al botón grande de la cámara, que "muerde" el mapa.
            bottom: 36,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                const _SpinHint(),
                const SizedBox(height: 24),
                _ZonePanel(
                  zone: _m.selected ?? _m.entered,
                  here:
                      _m.entered != null &&
                      (_m.selected ?? _m.entered)?.id == _m.entered?.id,
                  tracking: _m.tracking,
                  status: _m.status,
                  onListen: _openGuide,
                  onEnable: () => unawaited(_enableLocation()),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- Piezas de la pantalla ---------------------------------------------------

/// Un icono de la maqueta (sus mismas líneas, de 24×24).
Widget _svg(String d, Color color, {double size = 18, double width = 2}) {
  final String hex = (color.toARGB32() & 0xFFFFFF)
      .toRadixString(16)
      .padLeft(6, '0');
  return SvgPicture.string(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
    'stroke="#$hex" stroke-width="$width" stroke-linecap="round" '
    'stroke-linejoin="round"><path d="$d"/></svg>',
    width: size,
    height: size,
  );
}

/// La brújula de la maqueta: aguja roja al norte y blanca al sur.
const String _compass =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 26 26">'
    '<path d="M13 2l4 11h-8z" fill="#FF6B6B"/>'
    '<path d="M13 24l-4-11h8z" fill="#DCE5E9"/>'
    '<text x="13" y="10" text-anchor="middle" font-size="5" '
    'font-weight="800" fill="#0B1217">N</text></svg>';

/// El fondo "de cristal" oscuro de los botones de arriba.
class _Glass extends StatelessWidget {
  const _Glass({
    required this.child,
    required this.radius,
    this.height,
    this.width,
    this.minHeight,
    this.padding = EdgeInsets.zero,
    this.onTap,
    this.tooltip,
  });

  final Widget child;
  final double radius;
  final double? height;
  final double? width;
  final double? minHeight;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final BorderRadius r = BorderRadius.circular(radius);
    Widget box = Material(
      color: const Color(0xD10B1217),
      shape: RoundedRectangleBorder(
        borderRadius: r,
        side: const BorderSide(color: Color(0xFF26363F)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: height,
          width: width,
          constraints: BoxConstraints(minHeight: minHeight ?? 0),
          padding: padding,
          alignment: width == null ? null : Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[Flexible(child: child)],
          ),
        ),
      ),
    );
    if (tooltip != null) {
      box = Tooltip(
        message: tooltip,
        child: Semantics(button: true, label: tooltip, child: box),
      );
    }
    return box;
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color, this.size);

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}

class _SearchBox extends StatelessWidget {
  const _SearchBox({
    required this.controller,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: const Color(0xD10B1217),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF26363F)),
      ),
      child: Row(
        children: <Widget>[
          _svg(
            'M18 11a7 7 0 1 1-14 0a7 7 0 1 1 14 0M20 20l-4-4',
            const Color(0xFF9FB0B8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              onSubmitted: onSubmit,
              textInputAction: TextInputAction.search,
              style: const TextStyle(
                fontFamily: 'Manrope',
                fontSize: 15,
                color: Color(0xFFF2F5F3),
              ),
              decoration: const InputDecoration(
                hintText: 'Buscar monumento o calle',
                hintStyle: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 15,
                  color: Color(0xFF7D8E96),
                ),
                isCollapsed: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Tu foto (o tu inicial) con su aro violeta: abre Ajustes.
class _Me extends StatelessWidget {
  const _Me({required this.name, required this.photoUrl, required this.onTap});

  final String name;
  final String? photoUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: 'Tu foto de perfil y ajustes',
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(color: Color(0xFF0B1217), spreadRadius: 2),
            BoxShadow(color: Color(0x55B69CFF), spreadRadius: 4),
          ],
        ),
        child: ExcludeSemantics(
          child: UserAvatar(
            name: name,
            photoUrl: photoUrl,
            size: 48,
            color: NomadColors.group,
            isMe: true,
          ),
        ),
      ),
    ),
  );
}

/// Tus sellos: la medalla y cuántos nuevos (abre el Pasaporte).
class _Stamps extends StatelessWidget {
  const _Stamps({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: count == 0
        ? 'Pasaporte de sellos'
        : 'Pasaporte de sellos, $count ${count == 1 ? 'nuevo' : 'nuevos'}',
    child: ExcludeSemantics(
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          _Glass(
            height: 48,
            width: 48,
            radius: 18,
            onTap: onTap,
            child: _svg(
              'M18 9a6 6 0 1 1-12 0a6 6 0 1 1 12 0M8.5 14l-1.5 7 5-3 5 3-1.5-7',
              NomadColors.money,
              size: 20,
            ),
          ),
          if (count > 0)
            Positioned(
              top: 5,
              right: 5,
              child: IgnorePointer(
                child: Container(
                  constraints: const BoxConstraints(minWidth: 16),
                  height: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: NomadColors.money,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: NomadColors.background,
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

/// Flyra flotando (sube y baja 4 px) con su punto rojo de aviso nuevo.
class _FlyraButton extends StatefulWidget {
  const _FlyraButton({required this.badge, required this.onTap});

  final bool badge;
  final VoidCallback onTap;

  @override
  State<_FlyraButton> createState() => _FlyraButtonState();
}

class _FlyraButtonState extends State<_FlyraButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_fly.isAnimating && !MediaQuery.disableAnimationsOf(context)) {
      Motion.loop(_fly, reverse: true);
    }
  }

  @override
  void dispose() {
    _fly.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 60,
    height: 60,
    child: Stack(
      children: <Widget>[
        Positioned(
          right: 2,
          top: 2,
          child: AnimatedBuilder(
            animation: _fly,
            builder: (BuildContext context, Widget? child) =>
                Transform.translate(
                  offset: Offset(
                    0,
                    -4 * Curves.easeInOut.transform(_fly.value),
                  ),
                  child: child,
                ),
            child: Semantics(
              button: true,
              label: 'Habla con Flyra',
              child: GestureDetector(
                onTap: widget.onTap,
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: NomadColors.background,
                    border: Border.all(color: NomadColors.mint, width: 2),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(
                        color: Color(0x73000000),
                        blurRadius: 24,
                        offset: Offset(0, 10),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: OverflowBox(
                    maxWidth: 60,
                    maxHeight: 60,
                    child: Image.asset(
                      'assets/map/flyra.webp',
                      width: 60,
                      height: 60,
                      excludeFromSemantics: true,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.badge)
          Positioned(
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: const Duration(milliseconds: 600),
                curve: Curves.elasticOut,
                builder: (BuildContext context, double v, Widget? child) =>
                    Transform.scale(scale: v, child: child),
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF6B6B),
                    shape: BoxShape.circle,
                    border: Border.all(color: NomadColors.background, width: 2),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

/// El bocadillo de Flyra al entrar en una zona: aparece, se queda unos
/// segundos y se va solo (7 s, como en la maqueta). Tocarlo abre la
/// audioguía.
class _EnteredBubble extends StatefulWidget {
  const _EnteredBubble({
    super.key,
    required this.zone,
    required this.onOpen,
    required this.onDone,
  });

  final Zone zone;
  final VoidCallback onOpen;
  final VoidCallback onDone;

  @override
  State<_EnteredBubble> createState() => _EnteredBubbleState();
}

class _EnteredBubbleState extends State<_EnteredBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _show = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 7),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_show.forward().whenComplete(widget.onDone));
  }

  @override
  void dispose() {
    _show.dispose();
    super.dispose();
  }

  /// 0 → 8 %: entra; hasta el 86 %: quieto; al final: se va.
  double _in(double t) => t < 0.08
      ? Curves.easeOutBack.transform(t / 0.08)
      : t < 0.86
      ? 1
      : 1 - (t - 0.86) / 0.14;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool guide = widget.zone.kind.hasAudioguide;
    return AnimatedBuilder(
      animation: _show,
      builder: (BuildContext context, Widget? child) {
        final double v = _in(_show.value).clamp(0, 1.2);
        return Opacity(
          opacity: v.clamp(0, 1),
          child: Transform.translate(
            offset: Offset(0, -14 * (1 - v)),
            child: Transform.scale(
              scale: 0.9 + 0.1 * v,
              alignment: const Alignment(0.8, -1),
              child: child,
            ),
          ),
        );
      },
      child: Semantics(
        liveRegion: true,
        child: GestureDetector(
          onTap: guide ? widget.onOpen : null,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF121B21),
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(18),
                    topRight: Radius.circular(6),
                    bottomLeft: Radius.circular(18),
                    bottomRight: Radius.circular(18),
                  ),
                  border: Border.all(color: const Color(0x663DDC97)),
                  boxShadow: const <BoxShadow>[
                    BoxShadow(
                      color: Color(0x99000000),
                      blurRadius: 40,
                      offset: Offset(0, 16),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Padding(
                          padding: EdgeInsets.only(top: 4),
                          child: _Dot(NomadColors.mint, 10),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              const Text(
                                'FLYRA',
                                style: TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.66,
                                  color: NomadColors.mint,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                t.mapEnteredTitle(widget.zone.name),
                                style: const TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFFF2F5F3),
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                guide
                                    ? 'Te he vibrado suave. '
                                          '${t.mapEnteredBody}.'
                                    : t.mapNoAudioguide,
                                style: const TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 12.5,
                                  height: 1.4,
                                  color: Color(0xFFB9C6CC),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          width: 40,
                          height: 40,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: const Color(0xFF16302A),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: _svg(
                            'M9 3h6a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H9a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2zM3 9v6M21 9v6',
                            NomadColors.mint,
                            size: 22,
                          ),
                        ),
                      ],
                    ),
                    if (guide) ...<Widget>[
                      const SizedBox(height: 8),
                      Padding(
                        padding: const EdgeInsets.only(left: 19),
                        child: Container(
                          height: 34,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: NomadColors.mint,
                            borderRadius: BorderRadius.circular(11),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              SvgPicture.string(
                                '<svg xmlns="http://www.w3.org/2000/svg" '
                                'viewBox="0 0 24 24"><path d="M7 4l13 8-13 8z" '
                                'fill="#0B1217"/></svg>',
                                width: 12,
                                height: 12,
                              ),
                              const SizedBox(width: 6),
                              const Text(
                                'Escuchar ahora',
                                style: TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w800,
                                  color: NomadColors.background,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // El piquito del bocadillo, que señala a Flyra.
              Positioned(
                right: 22,
                top: -7,
                child: Transform.rotate(
                  angle: math.pi / 4,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: const BoxDecoration(
                      color: Color(0xFF121B21),
                      border: Border(
                        left: BorderSide(color: Color(0x663DDC97)),
                        top: BorderSide(color: Color(0x663DDC97)),
                      ),
                    ),
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

/// "Arrastra para girar 360°": sale una vez a los 7 s de abrir el mapa y
/// se va a los 5 s.
class _SpinHint extends StatefulWidget {
  const _SpinHint();

  @override
  State<_SpinHint> createState() => _SpinHintState();
}

class _SpinHintState extends State<_SpinHint>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 12),
  );

  @override
  void initState() {
    super.initState();
    // En las pruebas no sale (esperaría 12 s a cada cosa).
    if (Motion.forever) unawaited(_c.forward());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (BuildContext context, Widget? child) {
          // 7 s esperando y luego 5 s: entra (7 %), se queda y se va.
          final double t = ((_c.value * 12) - 7) / 5;
          if (t <= 0 || t >= 1) return const SizedBox(height: 34);
          final double v = t < 0.07
              ? t / 0.07
              : t < 0.82
              ? 1
              : 1 - (t - 0.82) / 0.18;
          return Opacity(
            opacity: v,
            child: Transform.translate(
              offset: Offset(0, -24 * (1 - v)),
              child: child,
            ),
          );
        },
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xDB0B1217),
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: const Color(0xFF26363F)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _svg(
                'M3 12a9 4 0 0 0 18 0 M18 9l3 3-3 3',
                const Color(0xFFF2F5F3),
              ),
              const SizedBox(width: 8),
              const Text(
                'Arrastra con dos dedos para girar 360°',
                style: TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFF2F5F3),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Lo que encontró el buscador: tus zonas y, con cuenta, calles y sitios.
class _SearchResults extends StatelessWidget {
  const _SearchResults({
    required this.zones,
    required this.places,
    required this.searching,
    required this.empty,
    required this.onZone,
    required this.onPlace,
  });

  final List<Zone> zones;
  final List<GeoPlace> places;
  final bool searching;
  final String empty;
  final ValueChanged<Zone> onZone;
  final ValueChanged<GeoPlace> onPlace;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    const TextStyle title = TextStyle(
      fontFamily: 'Manrope',
      fontSize: 14,
      fontWeight: FontWeight.w800,
      color: Color(0xFFF2F5F3),
    );
    const TextStyle sub = TextStyle(
      fontFamily: 'Manrope',
      fontSize: 12,
      color: Color(0xFF9FB0B8),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Material(
        color: const Color(0xF0141E25),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF26363F)),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: zones.isEmpty && places.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(16),
                  child: searching
                      ? const LinearProgressIndicator()
                      : Text(empty, style: sub),
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
                        title: Text(z.name, style: title),
                        subtitle: Text(zoneKindLabel(t, z.kind), style: sub),
                        onTap: () => onZone(z),
                      ),
                    for (final GeoPlace p in places)
                      ListTile(
                        leading: const Icon(
                          Icons.place_rounded,
                          color: NomadColors.money,
                        ),
                        title: Text(p.name, style: title),
                        subtitle: Text(
                          p.address,
                          style: sub,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () => onPlace(p),
                      ),
                    if (searching) const LinearProgressIndicator(),
                  ],
                ),
        ),
      ),
    );
  }
}

/// El panel de abajo: la zona (la tuya o la que tocaste) con el botón de
/// su audioguía, y los atajos Cerca de ti, Radar y Asistente.
class _ZonePanel extends StatelessWidget {
  const _ZonePanel({
    required this.zone,
    required this.here,
    required this.tracking,
    required this.status,
    required this.onListen,
    required this.onEnable,
  });

  final Zone? zone;

  /// true si estás dentro de esta zona ahora mismo.
  final bool here;
  final bool tracking;
  final ZonesStatus status;
  final ValueChanged<Zone> onListen;
  final VoidCallback onEnable;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Zone? z = zone;
    final String kicker;
    final String title;
    final String sub;
    final Color color;
    VoidCallback? action;
    String icon = 'M8 5v14l11-7z';
    if (z != null) {
      color = here ? NomadColors.mint : _kindColor(z.kind);
      kicker = here ? t.mapKickerHere : zoneKindLabel(t, z.kind);
      title = z.name;
      sub = z.kind.hasAudioguide
          ? '${zoneKindLabel(t, z.kind)} · audioguía lista'
          : t.mapNoAudioguide;
      if (z.kind.hasAudioguide) action = () => onListen(z);
    } else if (!tracking) {
      // Sin GPS: el botón grande lo enciende.
      color = NomadColors.mint;
      kicker = 'Tu ubicación';
      title = t.mapEnableLocation;
      sub = status == ZonesStatus.signedOut
          ? t.mapZonesGuest
          : t.mapLocationWhy;
      action = onEnable;
      icon = 'M12 21s-7-6-7-11a7 7 0 0 1 14 0c0 5-7 11-7 11zM12 8a2 2 0 1 0 0.01 0';
    } else {
      color = NomadColors.mint;
      kicker = 'Zonas';
      title = 'Ninguna zona aquí';
      sub = switch (status) {
        ZonesStatus.loading => t.mapZonesLoading,
        ZonesStatus.tooFar => t.mapZonesTooFar,
        ZonesStatus.truncated => t.mapZonesTruncated,
        ZonesStatus.error => t.mapZonesError,
        ZonesStatus.signedOut => t.mapZonesGuest,
        ZonesStatus.idle ||
        ZonesStatus.ready => 'Toca una zona del mapa para ver su audioguía.',
      };
    }
    final bool pin = icon.startsWith('M12 21');
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xF0141E25),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF26363F)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          GestureDetector(
            // Toda la fila hace lo mismo que el botón redondo.
            onTap: action,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          kicker.toUpperCase(),
                          style: TextStyle(
                            fontFamily: 'Manrope',
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.66,
                            color: color,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'BricolageGrotesque',
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.22,
                            color: Color(0xFFF2F5F3),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sub,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Manrope',
                            fontSize: 12,
                            color: Color(0xFF9FB0B8),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Semantics(
                  button: true,
                  enabled: action != null,
                  label: pin ? t.mapEnableLocation : t.mapListen,
                  child: GestureDetector(
                    onTap: action,
                    child: Opacity(
                      opacity: action == null ? 0.4 : 1,
                      child: Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                        ),
                        child: pin
                            ? _svg(icon, NomadColors.background, size: 22)
                            : SvgPicture.string(
                                '<svg xmlns="http://www.w3.org/2000/svg" '
                                'viewBox="0 0 24 24"><path d="$icon" '
                                'fill="#0B1217"/></svg>',
                                width: 22,
                                height: 22,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Row(
            children: <Widget>[
              _Shortcut(
                label: 'Cerca de ti',
                color: NomadColors.mint,
                icon: 'M12 2l3 7h7l-5.5 4 2 7L12 16l-6.5 4 2-7L2 9h7z',
                route: Routes.nearby,
              ),
              SizedBox(width: 8),
              _Shortcut(
                label: 'Radar',
                color: NomadColors.safety,
                icon: 'M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0 -18 0 M12 12l6-6',
                route: '/radar',
              ),
              SizedBox(width: 8),
              _Shortcut(
                label: 'Asistente',
                color: NomadColors.group,
                icon: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z M12 9a3 3 0 1 0 0.01 0',
                route: Routes.assistant,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Un atajo del panel (Cerca de ti, Radar o Asistente).
class _Shortcut extends StatelessWidget {
  const _Shortcut({
    required this.label,
    required this.color,
    required this.icon,
    required this.route,
  });

  final String label;
  final Color color;
  final String icon;
  final String route;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Material(
      color: const Color(0xFF1C2A33),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: Color(0xFF2C3D47)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => unawaited(context.push(route)),
        child: SizedBox(
          height: 74,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: _svg(icon, NomadColors.background, size: 17, width: 2.2),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 10,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFF2F5F3),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
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
