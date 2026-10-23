// El "cerebro" de la pantalla del mapa, sin nada de dibujo:
//   - pide las zonas que se ven (y no vuelve a pedir si ya las tiene);
//   - sabe qué zona has tocado y en cuál acabas de entrar;
//   - enciende el GPS cuando tú lo pides y manda tus posiciones por lotes.
//
// Es un ChangeNotifier (un "altavoz"): cuando algo cambia, la pantalla se
// entera y se redibuja. Al no dibujar nada, se prueba con tests rápidos.
import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../core/api_client.dart';
import 'geo.dart';
import 'geo_api.dart';
import 'location.dart';
import 'position_reporter.dart';
import 'zone_watcher.dart';

/// En qué punto está la carga de zonas (para el aviso de la pantalla).
enum ZonesStatus {
  idle, // aún no se ha pedido nada
  loading,
  ready,
  truncated, // hay demasiadas: acércate para verlas todas
  tooFar, // el mapa está demasiado alejado para pedir zonas
  signedOut, // invitado: las zonas y audioguías son para cuentas
  error, // sin conexión o el servidor falló (se reintenta al mover el mapa)
}

class MapModel extends ChangeNotifier {
  MapModel({
    required GeoApi? geo,
    required this._location,
    required String Function() language,
    DateTime Function()? clock,
    PositionReporter? reporter,
    ZoneWatcher? watcher,
  }) : _geo = geo,
       _now = clock ?? DateTime.now,
       _watcher = watcher ?? ZoneWatcher(),
       _reporter =
           reporter ??
           (geo == null
               ? null
               : PositionReporter(
                   send: (List<PositionFix> fixes) =>
                       geo.sendPositions(language(), fixes),
                 )) {
    if (geo == null) _status = ZonesStatus.signedOut;
  }

  final GeoApi? _geo;
  final LocationSource _location;
  final DateTime Function() _now;
  final ZoneWatcher _watcher;
  final PositionReporter? _reporter;

  /// Como mucho tantas zonas en memoria; las más antiguas se olvidan.
  static const int maxZones = 1000;

  /// Lo ya descargado vale durante este tiempo sin volver a preguntar.
  static const Duration freshFor = Duration(minutes: 5);

  // LinkedHashMap recuerda el orden de llegada: así se sabe cuál es la más vieja.
  final LinkedHashMap<String, Zone> _zones = LinkedHashMap<String, Zone>();
  ZonesStatus _status = ZonesStatus.idle;
  GeoBox? _covered;
  DateTime? _coveredAt;
  int _ticket = 0;

  Zone? _selected;
  Zone? _entered;
  GeoPoint? _me;
  LocationAccess? _access;
  StreamSubscription<PositionFix>? _fixes;
  bool _firstFix = true;
  bool _disposed = false;

  /// La pantalla se apunta aquí para mover la cámara (p. ej. a tu posición
  /// la primera vez que el GPS te encuentra).
  void Function(GeoPoint target, double? zoom)? onFocus;

  Iterable<Zone> get zones => _zones.values;
  ZonesStatus get status => _status;
  Zone? get selected => _selected;

  /// La zona en la que acabas de entrar (para el aviso "Has entrado en...").
  Zone? get entered => _entered;
  GeoPoint? get me => _me;
  LocationAccess? get access => _access;
  bool get tracking => _fixes != null;

  /// El mapa se ha parado en [view]: pide sus zonas si hace falta.
  Future<void> onViewChanged(GeoBox? view) async {
    final GeoApi? geo = _geo;
    if (geo == null || _status == ZonesStatus.signedOut) return;
    if (view == null || !view.fitsServerLimit) {
      _set(ZonesStatus.tooFar);
      return;
    }
    final GeoBox? covered = _covered;
    final DateTime? at = _coveredAt;
    if (covered != null &&
        at != null &&
        covered.containsBox(view) &&
        _now().difference(at) < freshFor) {
      _set(ZonesStatus.ready);
      return;
    }
    // Se pide un poco más de lo que se ve: al mover un poco el mapa ya no
    // hace falta volver a preguntar. El "ticket" descarta respuestas viejas
    // si el usuario movió el mapa otra vez antes de que llegaran.
    final GeoBox ask = view.grow(1.5);
    final int ticket = ++_ticket;
    _set(ZonesStatus.loading);
    try {
      final ZonePage page = await geo.zones(ask);
      if (ticket != _ticket || _disposed) return;
      for (final Zone zone in page.zones) {
        _zones.remove(zone.id); // al volver a meterla pasa a ser "la más nueva"
        _zones[zone.id] = zone;
      }
      while (_zones.length > maxZones) {
        _zones.remove(_zones.keys.first);
      }
      // Si la respuesta vino recortada, no se da el área por "completa":
      // al acercar el mapa se volverá a preguntar.
      _covered = page.truncated ? null : ask;
      _coveredAt = _now();
      _set(page.truncated ? ZonesStatus.truncated : ZonesStatus.ready);
    } on ApiException catch (e) {
      if (ticket != _ticket || _disposed) return;
      _set(
        e.error == ApiError.signedOut
            ? ZonesStatus.signedOut
            : ZonesStatus.error,
      );
    }
  }

  /// Toque en el mapa: selecciona la zona tocada (o quita la selección).
  void tapAt(GeoPoint point) {
    Zone? hit;
    for (final Zone zone in _zones.values) {
      if (!zone.contains(point)) continue;
      // Si hay varias una dentro de otra, la más pequeña (la más concreta).
      if (hit == null || _area(zone) < _area(hit)) hit = zone;
    }
    select(hit);
  }

  void select(Zone? zone) {
    if (zone?.id == _selected?.id) return;
    _selected = zone;
    _notify();
  }

  /// Ir a una zona elegida en el buscador.
  void focusZone(Zone zone) {
    select(zone);
    onFocus?.call(zone.bounds.center, 15.5);
  }

  void dismissEntered() {
    if (_entered == null) return;
    _entered = null;
    _notify();
  }

  /// Zonas cargadas cuyo nombre contiene [query] (sin distinguir mayúsculas).
  List<Zone> search(String query) {
    final String q = query.trim().toLowerCase();
    if (q.isEmpty) return const <Zone>[];
    return _zones.values
        .where((Zone z) => z.name.toLowerCase().contains(q))
        .take(20)
        .toList(growable: false);
  }

  /// Las zonas en GeoJSON, con la seleccionada marcada (se pinta más fuerte).
  Map<String, Object?> zonesGeoJson() => <String, Object?>{
    'type': 'FeatureCollection',
    'features': <Object?>[
      for (final Zone zone in _zones.values)
        zone.toFeature(selected: zone.id == _selected?.id),
    ],
  };

  /// Comprueba el permiso SIN preguntar (al abrir el mapa). Si ya estaba
  /// concedido, el GPS se enciende solo.
  Future<void> resumeLocation() async {
    _access = await _location.check();
    if (_access == LocationAccess.granted) _startTracking();
    _notify();
  }

  /// El usuario pulsó "Activar ubicación": ahora sí se pregunta.
  Future<LocationAccess> enableLocation() async {
    LocationAccess access = await _location.check();
    if (access == LocationAccess.denied) access = await _location.request();
    _access = access;
    if (access == LocationAccess.granted) {
      _startTracking();
      final GeoPoint? me = _me;
      if (me != null) onFocus?.call(me, 16);
    }
    _notify();
    return access;
  }

  Future<void> openLocationSettings() => _location.openSettings();

  /// La app pasa a segundo plano: se manda lo pendiente y se apaga el GPS
  /// (el seguimiento con la app cerrada llega en otro PR, con su permiso).
  Future<void> pause() async {
    await _fixes?.cancel();
    _fixes = null;
    await _reporter?.flush();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_fixes?.cancel());
    _fixes = null;
    // Lo que quede en la cola se intenta mandar una última vez.
    final PositionReporter? reporter = _reporter;
    if (reporter != null) {
      unawaited(reporter.flush().whenComplete(reporter.dispose));
    }
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  void _startTracking() {
    if (_fixes != null) return;
    _fixes = _location.watch().listen(
      _onFix,
      onError: (Object _) {
        // El GPS falló (p. ej. lo apagaron): se para y se vuelve a comprobar.
        _fixes = null;
        _access = null;
        _notify();
      },
      cancelOnError: true,
    );
  }

  void _onFix(PositionFix fix) {
    if (!fix.point.isValid) return;
    _me = fix.point;
    _reporter?.add(fix);
    if (_firstFix) {
      _firstFix = false;
      onFocus?.call(fix.point, 16);
    }
    final Zone? entered = _watcher.update(fix, _zones.values);
    if (entered != null) {
      _entered = entered;
      _selected = entered;
    }
    _notify();
  }

  void _set(ZonesStatus status) {
    if (_status == status) return;
    _status = status;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static double _area(Zone z) {
    final GeoBox b = z.bounds;
    return b.lonSpan * b.latSpan;
  }
}
