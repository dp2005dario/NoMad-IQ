// El "rastreador" de la app: el ÚNICO sitio que enciende y apaga el GPS.
//
// Antes lo hacía la pantalla del mapa; ahora vive a nivel de app porque el
// "modo viaje" sigue funcionando con el mapa cerrado (y con la app cerrada).
// Cualquier pantalla puede escuchar sus posiciones con [fixes].
//
// Dos maneras de funcionar:
//   - Normal: GPS solo con la app en pantalla. Al salir, se apaga.
//   - Modo viaje: sigue con la app cerrada, con una notificación fija que lo
//     dice ("servicio en primer plano"). Así el servidor puede avisarte de que
//     hay una audioguía aunque lleves el móvil en el bolsillo.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../auth/session.dart';
import '../../core/settings.dart';
import 'geo.dart';
import 'geo_api.dart';
import 'location.dart';
import 'position_reporter.dart';

/// Por qué no se pudo encender el modo viaje.
enum TravelModeResult {
  on,
  needsAccount, // invitado: el servidor no sabría a quién avisar
  needsLocation, // sin permiso de ubicación
  needsNotifications, // sin permiso de notificaciones (Android 13+)
}

class LocationTracker extends ChangeNotifier {
  LocationTracker({
    required this._location,
    required this._geo,
    required this._session,
    required this._prefs,
    Future<bool> Function()? askNotifications,
    PositionReporter Function(SendPositions send)? newReporter,
  }) : _askNotifications = askNotifications ?? _alwaysAllowed,
       _newReporter = newReporter ?? _defaultReporter,
       _travel = _prefs.readTravelMode() {
    _session.addListener(_onSession);
    _onSession();
  }

  final LocationSource _location;
  final GeoApi _geo;
  final SessionController _session;
  final SettingsStore _prefs;
  final Future<bool> Function() _askNotifications;
  final PositionReporter Function(SendPositions send) _newReporter;

  /// Idioma de la app (para el envío de posiciones). Lo pone la app.
  String language = 'en';

  /// Texto traducido de la notificación fija. Lo pone la app.
  TrackingNotice notice = const TrackingNotice(
    title: 'ECLIPTA',
    text: '',
    channel: 'ECLIPTA',
  );

  final StreamController<PositionFix> _fixes =
      StreamController<PositionFix>.broadcast();
  StreamSubscription<PositionFix>? _sub;
  bool _subBackground = false;
  PositionReporter? _reporter;
  LocationAccess? _access;
  GeoPoint? _me;
  bool _travel;
  bool _inForeground = true;
  bool _wasTracking = false;
  bool _disposed = false;

  /// Cada posición válida, para quien quiera escucharla (el mapa).
  Stream<PositionFix> get fixes => _fixes.stream;
  LocationAccess? get access => _access;
  GeoPoint? get me => _me;
  bool get tracking => _sub != null;

  /// El modo viaje está pedido (y se mantiene entre aperturas de la app).
  bool get travelMode => _travel;

  /// Solo las cuentas pueden usarlo.
  bool get canTravel => _session.status == SessionStatus.signedIn;

  /// Comprueba el permiso SIN preguntar. Si ya estaba concedido, enciende
  /// el GPS. Se llama al abrir el mapa y al volver a la app.
  Future<void> resume() async {
    _inForeground = true;
    _access = await _location.check();
    if (_access == LocationAccess.granted) {
      _start();
    } else {
      await _stop();
    }
    _notify();
  }

  /// El usuario pulsó "Activar ubicación": ahora sí se pregunta.
  Future<LocationAccess> enable() async {
    LocationAccess access = await _location.check();
    if (access == LocationAccess.denied) access = await _location.request();
    _access = access;
    if (access == LocationAccess.granted) _start();
    _notify();
    return access;
  }

  Future<void> openSettings() => _location.openSettings();

  /// La app pasa a segundo plano. Sin modo viaje: se manda lo pendiente y
  /// se apaga el GPS. Con modo viaje: todo sigue (con su notificación fija).
  Future<void> paused() async {
    _inForeground = false;
    _wasTracking = _sub != null;
    if (_travel && canTravel && _subBackground) return;
    await _stop();
    await _reporter?.flush();
  }

  /// La app vuelve a la pantalla (o acaba de abrirse): el GPS se enciende
  /// otra vez solo si lo estaba antes, o si el modo viaje está pedido.
  /// Así abrir la app no enciende el GPS hasta que visitas el mapa.
  Future<void> appResumed() async {
    _inForeground = true;
    if (_wasTracking || (_travel && canTravel)) await resume();
  }

  /// Enciende o apaga el modo viaje. Para encenderlo hacen falta cuenta,
  /// ubicación y (en Android 13+) permiso de notificaciones: sin él, la
  /// notificación fija no se vería y no podríamos avisarte de nada.
  Future<TravelModeResult> setTravelMode(bool on) async {
    if (!on) {
      _travel = false;
      await _prefs.writeTravelMode(false);
      if (_sub != null) _restart();
      _notify();
      return TravelModeResult.on;
    }
    if (!canTravel) return TravelModeResult.needsAccount;
    if (await enable() != LocationAccess.granted) {
      return TravelModeResult.needsLocation;
    }
    if (!await _askNotifications()) return TravelModeResult.needsNotifications;
    _travel = true;
    await _prefs.writeTravelMode(true);
    _restart();
    _notify();
    return TravelModeResult.on;
  }

  @override
  void dispose() {
    _disposed = true;
    _session.removeListener(_onSession);
    unawaited(_sub?.cancel());
    _sub = null;
    final PositionReporter? reporter = _reporter;
    if (reporter != null) {
      unawaited(reporter.flush().whenComplete(reporter.dispose));
    }
    unawaited(_fixes.close());
    super.dispose();
  }

  // ---------------------------------------------------------------------------

  /// Entrar o salir de la cuenta cambia quién recibe las posiciones.
  void _onSession() {
    final bool signedIn = _session.status == SessionStatus.signedIn;
    if (signedIn && _reporter == null) {
      _reporter = _newReporter(
        (List<PositionFix> fixes) => _geo.sendPositions(language, fixes),
      );
    } else if (!signedIn && _reporter != null) {
      _reporter?.dispose();
      _reporter = null;
      // Sin cuenta no hay modo viaje: se vuelve al GPS normal (o se apaga,
      // si la app no está en pantalla).
      if (_sub != null && _subBackground) {
        if (_inForeground) {
          _restart();
        } else {
          unawaited(_stop());
        }
      }
    }
    _notify();
  }

  bool get _wantBackground => _travel && canTravel;

  void _start() {
    if (_sub != null && _subBackground == _wantBackground) return;
    _restart();
  }

  /// (Re)abre el GPS con la configuración que toca ahora.
  void _restart() {
    unawaited(_sub?.cancel());
    final bool background = _wantBackground;
    _subBackground = background;
    _sub = _location
        .watch(background: background ? notice : null)
        .listen(
          _onFix,
          onError: (Object _) {
            // El GPS falló (p. ej. lo apagaron): se para y se vuelve a
            // comprobar la próxima vez que se abra la app.
            _sub = null;
            _access = null;
            _notify();
          },
          cancelOnError: true,
        );
  }

  Future<void> _stop() async {
    final StreamSubscription<PositionFix>? sub = _sub;
    _sub = null;
    _subBackground = false;
    await sub?.cancel();
  }

  void _onFix(PositionFix fix) {
    if (!fix.point.isValid) return;
    _me = fix.point;
    _reporter?.add(fix);
    if (!_fixes.isClosed) _fixes.add(fix);
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static Future<bool> _alwaysAllowed() async => true;

  static PositionReporter _defaultReporter(SendPositions send) =>
      PositionReporter(send: send);
}
