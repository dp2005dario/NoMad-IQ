// De dónde sale tu posición. La pantalla del mapa habla con esta "interfaz"
// y no directamente con el GPS: así en los tests se usa un GPS falso.
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'geo.dart';

/// En qué punto está el permiso de ubicación.
enum LocationAccess {
  granted, // concedido
  denied, // no concedido todavía (se puede preguntar)
  deniedForever, // el usuario dijo "no volver a preguntar": solo desde Ajustes
  serviceOff, // el GPS del móvil está apagado
}

abstract interface class LocationSource {
  Future<LocationAccess> check();

  /// Muestra la pregunta del sistema ("¿Permitir que NomadIQ acceda a tu
  /// ubicación?"). Solo se llama cuando el usuario pulsa "Activar ubicación",
  /// nunca nada más abrir la app: así entiende por qué se le pregunta.
  Future<LocationAccess> request();

  /// Posiciones según te mueves.
  Stream<PositionFix> watch();

  /// Abre los Ajustes del móvil (para quien eligió "no volver a preguntar").
  Future<void> openSettings();
}

/// El GPS de verdad, con el paquete geolocator.
class DeviceLocationSource implements LocationSource {
  const DeviceLocationSource();

  @override
  Future<LocationAccess> check() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceOff;
    }
    return _map(await Geolocator.checkPermission());
  }

  @override
  Future<LocationAccess> request() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceOff;
    }
    return _map(await Geolocator.requestPermission());
  }

  @override
  Stream<PositionFix> watch() =>
      Geolocator.getPositionStream(locationSettings: _settings()).map(
        (Position p) => PositionFix(
          point: GeoPoint(p.latitude, p.longitude),
          accuracyM: p.accuracy,
          recordedAt: p.timestamp,
        ),
      );

  // Solo avisa cuando te has movido 20 m: andando, una posición cada 15 s
  // más o menos. Más a menudo gastaría batería sin aportar nada.
  static LocationSettings _settings() => switch (defaultTargetPlatform) {
    TargetPlatform.android => AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 20,
      intervalDuration: const Duration(seconds: 10),
    ),
    TargetPlatform.iOS => AppleSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 20,
      // "Andando": iOS ajusta el GPS a ese ritmo y ahorra batería.
      activityType: ActivityType.fitness,
      pauseLocationUpdatesAutomatically: true,
    ),
    _ => const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 20,
    ),
  };

  @override
  Future<void> openSettings() async {
    await Geolocator.openAppSettings();
  }

  static LocationAccess _map(LocationPermission p) => switch (p) {
    LocationPermission.always ||
    LocationPermission.whileInUse => LocationAccess.granted,
    LocationPermission.deniedForever => LocationAccess.deniedForever,
    LocationPermission.denied ||
    LocationPermission.unableToDetermine => LocationAccess.denied,
  };
}
