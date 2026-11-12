// De dónde sale tu posición. La pantalla del mapa habla con esta "interfaz"
// y no directamente con el GPS: así en los tests se usa un GPS falso.
import 'dart:async';

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

  /// Muestra la pregunta del sistema ("¿Permitir que ECLIPTA acceda a tu
  /// ubicación?"). Solo se llama cuando el usuario pulsa "Activar ubicación",
  /// nunca nada más abrir la app: así entiende por qué se le pregunta.
  Future<LocationAccess> request();

  /// Posiciones según te mueves. Con [background] siguen llegando aunque
  /// cierres la app: Android lo permite solo si se ve una notificación fija
  /// ("servicio en primer plano") con ese texto, para que sepas que la app
  /// sigue usando tu ubicación.
  Stream<PositionFix> watch({TrackingNotice? background});

  /// Una posición ya, sin quedarse escuchando. Primero mira la última que
  /// el móvil recuerda (rápido y funciona en interior) y, si no hay,
  /// pregunta al GPS con paciencia. Devuelve null si no hay señal todavía.
  /// Puede lanzar una excepción: quien la llame debe capturarla.
  Future<PositionFix?> current();

  /// Abre los Ajustes del móvil (para quien eligió "no volver a preguntar").
  Future<void> openSettings();
}

/// El texto de la notificación fija del "modo viaje" (ya traducido).
class TrackingNotice {
  const TrackingNotice({
    required this.title,
    required this.text,
    required this.channel,
  });

  final String title;
  final String text;

  /// Nombre del "canal" en los ajustes de notificaciones de Android.
  final String channel;
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
  Stream<PositionFix> watch({TrackingNotice? background}) =>
      Geolocator.getPositionStream(locationSettings: _settings(background)).map(
        (Position p) => PositionFix(
          point: GeoPoint(p.latitude, p.longitude),
          accuracyM: p.accuracy,
          recordedAt: p.timestamp,
        ),
      );

  @override
  Future<PositionFix?> current() async {
    Position? p;
    // La última posición conocida no existe en todas las plataformas (p. ej.
    // la web): si falla, seguimos con la petición normal.
    try {
      p = await Geolocator.getLastKnownPosition();
    } on Object {
      p = null;
    }
    // Sin posición guardada: se pide una nueva con precisión media (la
    // "alta" en interior casi nunca llega) y hasta 30 s de espera.
    p ??= await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 30),
      ),
    );
    return PositionFix(
      point: GeoPoint(p.latitude, p.longitude),
      accuracyM: p.accuracy,
      recordedAt: p.timestamp,
    );
  }

  // Con la app en pantalla avisa cada 5 m (unos 3-4 s andando): así tu
  // punto del mapa se mueve contigo en directo, como en Google Maps.
  //
  // En modo viaje (app cerrada) se pide algo menos de precisión y se espera
  // 50 m: basta para saber en qué barrio estás y la batería dura el día.
  static LocationSettings _settings(TrackingNotice? background) =>
      switch (defaultTargetPlatform) {
        TargetPlatform.android => AndroidSettings(
          accuracy: background == null
              ? LocationAccuracy.high
              : LocationAccuracy.medium,
          distanceFilter: background == null ? 5 : 50,
          intervalDuration: Duration(seconds: background == null ? 2 : 30),
          foregroundNotificationConfig: background == null
              ? null
              : ForegroundNotificationConfig(
                  notificationTitle: background.title,
                  notificationText: background.text,
                  notificationChannelName: background.channel,
                  // La notificación no se puede quitar deslizando: si
                  // desapareciera, el usuario no sabría que seguimos activos.
                  setOngoing: true,
                ),
        ),
        TargetPlatform.iOS => AppleSettings(
          accuracy: background == null
              ? LocationAccuracy.high
              : LocationAccuracy.medium,
          distanceFilter: background == null ? 5 : 50,
          // "Andando": iOS ajusta el GPS a ese ritmo y ahorra batería.
          activityType: ActivityType.fitness,
          pauseLocationUpdatesAutomatically: true,
          // En segundo plano iOS enseña la "píldora" azul de ubicación.
          allowBackgroundLocationUpdates: background != null,
          showBackgroundLocationIndicator: background != null,
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

/// Tu posición ya, para pantallas que solo necesitan saber dónde estás una
/// vez (cajeros, radar, SOS...). Primero la que el móvil recuerda (al
/// momento y funciona dentro de casa); si no hay, el primer aviso del GPS.
///
/// Antes se esperaba solo al GPS de alta precisión: dentro de un edificio
/// casi nunca llega a tiempo y la pantalla decía "sin ubicación".
///
/// Lanza [TimeoutException] si en [wait] no hay nada.
Future<PositionFix> positionNow(
  LocationSource gps, {
  Duration wait = const Duration(seconds: 15),
}) async {
  try {
    final PositionFix? known = await gps.current().timeout(wait);
    if (known != null) return known;
  } on Object {
    // Sin posición recordada: se espera al GPS.
  }
  return gps.watch().first.timeout(wait);
}
