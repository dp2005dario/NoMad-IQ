// La "caja de herramientas" de la app: las piezas que hablan con el mundo
// exterior (servidor, GPS, mapa, altavoz). Se crean UNA vez en main.dart y
// cualquier pantalla las coge con `ServicesScope.of(context)`.
//
// En los tests se monta la misma caja con piezas falsas: así las pantallas
// se prueban sin red, sin GPS y sin tarjeta gráfica.
import 'package:flutter/widgets.dart';

import '../features/audioguide/audioguide_api.dart';
import '../features/audioguide/guide_player.dart';
import '../features/flights/booking.dart';
import '../features/flights/fares_api.dart';
import '../features/map/geo_api.dart';
import '../features/map/location.dart';
import '../features/map/location_tracker.dart';
import '../features/map/map_surface.dart';
import '../features/map/street_photos_api.dart';
import '../features/push/notices.dart';
import '../features/route/places_api.dart';
import 'api_client.dart';
import 'settings.dart';

class AppServices {
  AppServices({
    required this.api,
    required this.location,
    required this.mapSurface,
    required this.newPlayer,
    required this.tilesUrl,
    required this.glyphsUrl,
    this.notices = const SilentNotices(),
    this.openBooking = openInBrowser,
    SettingsStore? prefs,
  }) : geo = GeoApi(api),
       audioguides = AudioguideApi(api),
       fares = FaresApi(api),
       places = PlacesApi(api),
       streetPhotos = StreetPhotosApi(api),
       prefs = prefs ?? MemorySettingsStore() {
    tracker = LocationTracker(
      location: location,
      geo: geo,
      session: api.session,
      prefs: this.prefs,
      askNotifications: notices.requestPermission,
    );
  }

  final ApiClient api;
  final GeoApi geo;
  final AudioguideApi audioguides;
  final FaresApi fares;

  /// Fichas de ciudad (Wikipedia) para la Ruta del vuelo.
  final PlacesApi places;

  /// Fotos reales de la calle (Mapillary) para el botón del mapa.
  final StreetPhotosApi streetPhotos;

  /// Ajustes guardados en el móvil (idioma, modo viaje, aeropuerto…).
  final SettingsStore prefs;

  /// Abre la web de reserva de un vuelo (el navegador; en los tests, nada).
  final OpenBooking openBooking;
  final LocationSource location;

  /// El único que enciende el GPS (y el "modo viaje"). Vive lo que la app.
  late final LocationTracker tracker;

  /// Notificaciones en la barra del móvil (permiso y toques).
  final NoticeCenter notices;

  /// Cómo se dibuja el mapa (MapLibre en la app, uno falso en los tests).
  final MapSurfaceBuilder mapSurface;

  /// Crea un reproductor nuevo para cada audioguía que se abre.
  final GuidePlayerFactory newPlayer;

  /// De dónde salen los mapas (ver AppConfig).
  final Uri tilesUrl;
  final String glyphsUrl;
}

class ServicesScope extends InheritedWidget {
  const ServicesScope({
    super.key,
    required this.services,
    required super.child,
  });

  final AppServices services;

  static AppServices of(BuildContext context) {
    final ServicesScope? scope = context
        .getInheritedWidgetOfExactType<ServicesScope>();
    assert(scope != null, 'Falta ServicesScope encima de este widget');
    return scope!.services;
  }

  // Las piezas no cambian mientras la app está abierta.
  @override
  bool updateShouldNotify(ServicesScope oldWidget) =>
      !identical(services, oldWidget.services);
}
