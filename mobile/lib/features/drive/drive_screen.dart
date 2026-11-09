// Modo coche (maqueta "Coche"): la maqueta tal cual (assets/drive/coche.html)
// con lo que tienes cerca de verdad, y todo se puede leer en voz alta.
//
//   - Audioguía: el modo viaje te avisa al pasar por cada zona con
//     audioguía; suena por los altavoces del coche (Bluetooth o Android
//     Auto, que ve nuestro reproductor como una app de audio).
//   - Gasolina (tocándolo otra vez, cargadores eléctricos), Aparcar y Zona
//     ZTL: lo más cercano, de OpenStreetMap, y "Ir" abre Google Maps
//     conduciendo.
//
// La flecha de arriba dice hacia dónde queda el sitio en línea recta; la
// navegación giro a giro la hace Google Maps (un enlace, 0 €): hacerla
// nosotros costaría servidores de rutas y datos de tráfico. Los precios de
// la gasolina y las plazas libres no existen gratis para todo el mundo: no
// se inventan.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/geo.dart';
import '../map/location.dart';
import '../map/location_tracker.dart';
import '../route/web_scene.dart';
import '../sos/where_am_i.dart';
import 'drive_api.dart';
import 'drive_page.dart';

/// Más lejos que esto, una zona ZTL no "está cerca".
const double _lezNearMeters = 15000;

/// La web con las zonas de acceso restringido de toda Europa (gratis).
final Uri lezEuropeUrl = Uri.https('urbanaccessregulations.eu', '/');

enum _Mode { guide, fuel, park, lez }

class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = DriveScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  // Como en la maqueta, empieza en "Audioguía".
  _Mode _mode = _Mode.guide;
  bool _electric = false;
  bool _voice = true;

  StreamSubscription<PositionFix>? _fixes;
  GeoPoint? _me;
  double? _heading;
  String? _city;
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
    try {
      _pageCache ??= await rootBundle.loadString(drivePage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
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
        final GeoPoint? before = _me;
        setState(() {
          _heading = headingOf(before, f.point) ?? _heading;
          _me = f.point;
        });
        if (before == null) unawaited(_findCity(f.point));
        unawaited(_load(f.point));
      },
      onError: (Object _) {
        if (mounted) setState(() => _noLocation = true);
      },
    );
  }

  /// La ciudad grande más cercana (sin Internet), para el subtítulo.
  Future<void> _findCity(GeoPoint me) async {
    try {
      final Whereabouts w = await whereabouts(me);
      if (mounted) setState(() => _city = w.city);
    } on Object {
      // Sin ciudad, el subtítulo dice solo "Android Auto".
    }
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
    setState(() {
      // Tocar "Gasolina" otra vez cambia a cargadores eléctricos (y vuelta).
      if (m == _Mode.fuel && _mode == _Mode.fuel) _electric = !_electric;
      _mode = m;
    });
    final String? line = _headline(AppLocalizations.of(context));
    if (line != null) _say(line);
  }

  /// Lo que pide la página.
  void _onMessage(String msg) {
    final List<String> p = msg.split(':');
    final _Mode? m = p.length > 1 ? _modeOf[p[1]] : null;
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'mode' when m != null:
        _pick(m);
      case 'go' when m != null:
        _act(m);
      case 'voice':
        setState(() => _voice = !_voice);
        if (!_voice) unawaited(_services.speaker.stop());
    }
  }

  /// El botón de la tarjeta.
  void _act(_Mode m) {
    if (m == _Mode.guide) {
      unawaited(_setTravel(!_services.tracker.travelMode));
      return;
    }
    final GeoPoint? me = _me;
    if (_error != null && _area == null) {
      if (me != null) unawaited(_load(me, force: true));
      return;
    }
    final List<DriveSpot> list = _list();
    if (list.isEmpty) {
      if (m == _Mode.lez) unawaited(_services.openBooking(lezEuropeUrl));
      return;
    }
    if (m == _Mode.lez) {
      unawaited(_services.openBooking(list.first.website ?? lezEuropeUrl));
    } else {
      _go(list.first.point);
    }
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

  DriveKind? _kindOf(_Mode mode) => switch (mode) {
    _Mode.fuel => _electric ? DriveKind.ev : DriveKind.fuel,
    _Mode.park => DriveKind.parking,
    _Mode.lez => DriveKind.lez,
    _Mode.guide => null,
  };

  /// Los sitios de un modo (si no se dice, el que está elegido), del más
  /// cercano al más lejano.
  List<DriveSpot> _list([_Mode? mode]) {
    final DriveArea? area = _area;
    final GeoPoint? me = _me;
    final DriveKind? kind = _kindOf(mode ?? _mode);
    if (area == null || me == null || kind == null) return const <DriveSpot>[];
    final List<DriveSpot> all = area.of(kind, me);
    return kind == DriveKind.lez
        ? all
              .where((DriveSpot s) => s.point.distanceTo(me) < _lezNearMeters)
              .toList()
        : all;
  }

  /// La frase de la tarjeta principal (la que se lee en voz alta).
  String? _headline(AppLocalizations t, [_Mode? mode]) {
    final _Mode m = mode ?? _mode;
    final GeoPoint? me = _me;
    if (m == _Mode.guide) return t.driveGuideTitle;
    final List<DriveSpot> list = _list(m);
    if (me == null || _area == null) return null;
    if (list.isEmpty) {
      return m == _Mode.lez ? t.driveLezNone : t.driveNone;
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

  /// Las tarjetas, la flecha y las etiquetas del mapa para la página.
  Map<String, Object?> _data(AppLocalizations t) {
    final GeoPoint? me = _me;
    final DriveArea? area = _area;
    final bool travel = _services.tracker.travelMode;
    final String readAloud = _voice
        ? 'Se lee en voz alta. Toca aquí para silenciarla.'
        : 'Voz apagada. Toca aquí para que se lea en voz alta.';

    // Lo que dice la tarjeta de un modo con sitios (gasolina, aparcar, ZTL).
    Map<String, Object?> spotsCard(_Mode m) {
      final String btn = m == _Mode.lez ? t.driveLezWeb : t.driveGo;
      if (_noLocation) {
        return <String, Object?>{
          'title': t.cameraNoLocation,
          'voice': readAloud,
        };
      }
      if (_error != null && area == null) {
        return <String, Object?>{
          'title': _error == ApiError.network
              ? t.errorNetwork
              : t.errorUnavailable,
          'btn': t.guideRetry,
          'voice': readAloud,
        };
      }
      if (area == null || me == null) {
        return <String, Object?>{'title': '…', 'voice': readAloud};
      }
      final List<DriveSpot> list = _list(m);
      final String? headline = _headline(t, m);
      if (list.isEmpty) {
        return <String, Object?>{
          'title': headline ?? '',
          'meta': area.attribution,
          // Sin zonas en OpenStreetMap: la web con todas las de Europa.
          if (m == _Mode.lez) 'btn': t.driveLezEurope,
          'voice': m == _Mode.lez ? t.driveLezWarning : readAloud,
        };
      }
      final DriveSpot s = list.first;
      return <String, Object?>{
        'title': headline ?? '',
        'meta': <String>[?_meta(t, s), area.attribution].join(' · '),
        'btn': btn,
        if (m != _Mode.lez)
          'done': 'Abierto en Google Maps. Todo por voz, sin tocar el móvil.',
        'voice': m == _Mode.lez ? t.driveLezWarning : readAloud,
      };
    }

    // La flecha hacia el primer sitio de un modo.
    Map<String, Object?> turn(_Mode m) {
      final DriveSpot? s = _firstOf(m);
      if (s == null || me == null) {
        return <String, Object?>{
          'icon': 'ahead',
          'dist': _city ?? t.driveTitle,
          'name': m == _Mode.guide ? t.driveGuideSwitch : '',
        };
      }
      final (String icon, String words) = directionTo(me, s.point, _heading);
      return <String, Object?>{
        'icon': icon,
        'dist': '${_distance(t, s.point.distanceTo(me))} · $words',
        'name': s.label ?? _looks[m]!(t),
      };
    }

    final DriveSpot? fuel = _firstOf(_Mode.fuel);
    final DriveSpot? park = _firstOf(_Mode.park);
    return <String, Object?>{
      'title': t.driveTitle,
      'sub': _city == null ? 'Android Auto' : 'Android Auto · $_city',
      'labels': <String, String>{
        'guide': t.driveGuide,
        'fuel': _electric ? t.driveElectric : t.driveFuel,
        'park': t.drivePark,
        'ztl': t.driveLez,
      },
      'cards': <String, Object?>{
        'guide': <String, Object?>{
          'title': t.driveGuideTitle,
          'meta': travel ? '${t.travelMode} · encendido' : t.driveGuideSwitch,
          'btn': travel ? 'Apagar' : 'Encender',
          'voice': t.driveAndroidAuto,
        },
        'fuel': spotsCard(_Mode.fuel),
        'park': spotsCard(_Mode.park),
        'ztl': spotsCard(_Mode.lez),
      },
      'turns': <String, Object?>{
        'guide': turn(_Mode.guide),
        'fuel': turn(_Mode.fuel),
        'park': turn(_Mode.park),
        'ztl': turn(_Mode.lez),
      },
      // Las etiquetas del mapa: tu ciudad, la gasolinera y el parking ("P").
      'pois': <Object?>[
        if (_city != null)
          <String, String>{'label': _city!, 'kind': 'guide'}
        else
          null,
        if (fuel != null)
          <String, String>{'label': fuel.label ?? t.driveFuel, 'kind': 'fuel'}
        else
          null,
        if (park != null)
          <String, String>{'label': 'P', 'kind': 'park'}
        else
          null,
      ],
      'doneBtn': 'Hecho',
    };
  }

  /// El sitio más cercano de un modo (null = ninguno o aún no se sabe).
  DriveSpot? _firstOf(_Mode m) => _list(m).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = _data(AppLocalizations.of(context));
    final String push = drivePushScript(data);
    if (_html == null) {
      _html = drivePageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
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

/// El nombre de cada modo.
final Map<_Mode, String Function(AppLocalizations)> _looks =
    <_Mode, String Function(AppLocalizations)>{
      _Mode.guide: (AppLocalizations t) => t.driveGuide,
      _Mode.fuel: (AppLocalizations t) => t.driveFuel,
      _Mode.park: (AppLocalizations t) => t.drivePark,
      _Mode.lez: (AppLocalizations t) => t.driveLez,
    };

/// El nombre de cada modo en la página.
const Map<String, _Mode> _modeOf = <String, _Mode>{
  'guide': _Mode.guide,
  'fuel': _Mode.fuel,
  'park': _Mode.park,
  'ztl': _Mode.lez,
};
