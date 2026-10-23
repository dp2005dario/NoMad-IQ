// La "caja de herramientas" de la app: las piezas que hablan con el mundo
// exterior (servidor, GPS, mapa, altavoz). Se crean UNA vez en main.dart y
// cualquier pantalla las coge con `ServicesScope.of(context)`.
//
// En los tests se monta la misma caja con piezas falsas: así las pantallas
// se prueban sin red, sin GPS y sin tarjeta gráfica.
import 'package:flutter/widgets.dart';

import '../features/audioguide/audioguide_api.dart';
import '../features/audioguide/guide_player.dart';
import '../features/camera/camera_device.dart';
import '../features/camera/landmarks_api.dart';
import '../features/camera/speaker.dart';
import '../features/flights/booking.dart';
import '../features/flights/fares_api.dart';
import '../features/flyra/flyra_api.dart';
import '../features/group/group_api.dart';
import '../features/map/geo_api.dart';
import '../features/map/location.dart';
import '../features/map/location_tracker.dart';
import '../features/map/map_surface.dart';
import '../features/map/street_photos_api.dart';
import '../features/money/atms_api.dart';
import '../features/money/expenses_api.dart';
import '../features/money/fx_api.dart';
import '../features/money/receipt_scanner.dart';
import '../features/push/notices.dart';
import '../features/push/push_registrar.dart';
import '../features/route/flight3d.dart';
import '../features/route/places_api.dart';
import '../features/vault/doc_source.dart';
import '../features/vault/vault.dart';
import '../features/vault/vault_store.dart';
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
    this.webScene,
    this.newCamera,
    this.speaker = const SilentSpeaker(),
    this.receipts = const NoReceiptScanner(),
    this.docSource = const NoDocSource(),
    this.docReader = const NoDocTextReader(),
    Vault? vault,
    SettingsStore? prefs,
  }) : geo = GeoApi(api),
       audioguides = AudioguideApi(api),
       fares = FaresApi(api),
       flyra = FlyraApi(api),
       landmarks = LandmarksApi(api),
       group = GroupApi(api),
       expenses = ExpensesApi(api),
       atms = AtmsApi(api),
       places = PlacesApi(api),
       streetPhotos = StreetPhotosApi(api),
       prefs = prefs ?? MemorySettingsStore(),
       vault =
           vault ??
           Vault(
             keys: MemoryVaultKeyStore(),
             files: MemoryVaultFiles(),
             unlocker: const _NoUnlocker(),
           ) {
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

  /// El chat libre con Flyra (la IA de la app).
  final FlyraApi flyra;

  /// Modo cámara: ¿qué monumento tengo delante?
  final LandmarksApi landmarks;

  /// Enciende la cámara (null = este aparato no tiene: la pestaña lo dice).
  final CameraFactory? newCamera;

  /// La voz del móvil para "Escuchar" la ficha de un monumento.
  final Speaker speaker;

  /// Viajes en grupo: invitar, preferencias y la negociación de los agentes.
  final GroupApi group;

  /// Gastos compartidos: botes, tickets y "¿cuánto le debo a Álex?".
  final ExpensesApi expenses;

  /// Cajeros cercanos (OpenStreetMap, por zonas de ~1 km).
  final AtmsApi atms;

  /// Tipos de cambio del BCE (con copia en el móvil para usarlos sin red).
  late final FxApi fx = FxApi(api, prefs);

  /// Lee el ticket de una foto dentro del móvil (en los tests, uno falso).
  final ReceiptScanner receipts;

  /// La Bóveda: documentos cifrados en el móvil, abiertos con huella.
  final Vault vault;

  /// De dónde entran los documentos (cámara, galería o PDF).
  final DocSource docSource;

  /// Lee el texto de los documentos dentro del móvil (y dibuja los PDF).
  final DocTextReader docReader;

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

  /// El registro de avisos push de este móvil (null = esta compilación no
  /// tiene Firebase, o en los tests). Lo pone main.dart al arrancar.
  PushRegistrar? push;

  /// Dónde se ve el Vuelo 3D (un WebView en la app). Sin él (tests), el
  /// botón "Despegar" hace la animación del mapa plano de siempre.
  final WebSceneBuilder? webScene;

  /// Cómo se dibuja el mapa (MapLibre en la app, uno falso en los tests).
  final MapSurfaceBuilder mapSurface;

  /// Crea un reproductor nuevo para cada audioguía que se abre.
  final GuidePlayerFactory newPlayer;

  /// De dónde salen los mapas (ver AppConfig).
  final Uri tilesUrl;
  final String glyphsUrl;
}

/// Sin huella configurada (solo en pruebas): la Bóveda no se abre.
class _NoUnlocker implements Unlocker {
  const _NoUnlocker();

  @override
  Future<UnlockResult> unlock(String reason) async => UnlockResult.unavailable;
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
