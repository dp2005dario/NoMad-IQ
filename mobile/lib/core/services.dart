// La "caja de herramientas" de la app: las piezas que hablan con el mundo
// exterior (servidor, GPS, mapa, altavoz). Se crean UNA vez en main.dart y
// cualquier pantalla las coge con `ServicesScope.of(context)`.
//
// En los tests se monta la misma caja con piezas falsas: así las pantallas
// se prueban sin red, sin GPS y sin tarjeta gráfica.
import 'package:flutter/widgets.dart';

import '../features/audioguide/audioguide_api.dart';
import '../features/audioguide/guide_player.dart';
import '../features/map/geo_api.dart';
import '../features/map/location.dart';
import '../features/map/map_surface.dart';
import 'api_client.dart';

class AppServices {
  AppServices({
    required this.api,
    required this.location,
    required this.mapSurface,
    required this.newPlayer,
    required this.tilesUrl,
    required this.glyphsUrl,
  }) : geo = GeoApi(api),
       audioguides = AudioguideApi(api);

  final ApiClient api;
  final GeoApi geo;
  final AudioguideApi audioguides;
  final LocationSource location;

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
