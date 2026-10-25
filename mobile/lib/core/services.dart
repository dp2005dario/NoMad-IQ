// La "caja de herramientas" de la app: las piezas que hablan con el mundo
// exterior (servidor, GPS, mapa, altavoz). Se crean UNA vez en main.dart y
// cualquier pantalla las coge con `ServicesScope.of(context)`.
//
// En los tests se monta la misma caja con piezas falsas: así las pantallas
// se prueban sin red, sin GPS y sin tarjeta gráfica.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../features/audioguide/audioguide_api.dart';
import '../features/audioguide/guide_player.dart';
import '../features/camera/camera_device.dart';
import '../features/camera/landmarks_api.dart';
import '../features/camera/speaker.dart';
import '../features/flights/booking.dart';
import '../features/flights/climate_api.dart';
import '../features/flights/fares_api.dart';
import '../features/easy/easy_mode.dart';
import '../features/family/family.dart';
import '../features/airport/airport_guide.dart';
import '../features/airport/compass.dart';
import '../features/route/world_data.dart';
import '../features/widgets/home_widgets.dart';
import '../features/memories/memories.dart';
import '../features/memories/travel_camera.dart';
import '../features/flyra/flyra_api.dart';
import '../features/group/group_api.dart';
import '../features/help/help_contacts.dart';
import '../features/map/geo_api.dart';
import '../features/map/location.dart';
import '../features/map/location_tracker.dart';
import '../features/map/map_surface.dart';
import '../features/map/street_photos_api.dart';
import '../features/money/atms_api.dart';
import '../features/money/expenses_api.dart';
import '../features/money/fx_api.dart';
import '../features/cards/league_api.dart';
import '../features/copy_trip/shared_trip_api.dart';
import '../features/menu/menu_api.dart';
import '../features/money/receipt_scanner.dart';
import '../features/offline/city_downloader.dart';
import '../features/offline/city_pack.dart';
import '../features/offline/saved_guides.dart';
import '../features/push/notices.dart';
import '../features/push/push_registrar.dart';
import '../features/route/flight3d.dart';
import '../features/route/places_api.dart';
import '../features/vault/doc_source.dart';
import '../features/vault/vault.dart';
import '../features/vault/vault_store.dart';
import 'api_client.dart';
import 'launch.dart';
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
    this.openLink = openExternal,
    this.webScene,
    this.newCamera,
    this.speaker = const SilentSpeaker(),
    this.receipts = const NoReceiptScanner(),
    this.docSource = const NoDocSource(),
    this.docReader = const NoDocTextReader(),
    this.saved = const NoSavedGuides(),
    this.help = const HelpContacts(),
    this.newTravelCamera,
    this.share = shareFiles,
    this.sticker = stickerPhoto,
    MemoryFiles? memoryFiles,
    HomeWidgets? homeWidgets,
    LiveFlight? liveFlight,
    this.loadAirports = worldAirports,
    this.syncWidgetsOnStart = false,
    this.compass = deviceCompass,
    FamilyStore? family,
    OfflineFiles? offlineFiles,
    OfflineMaps? offlineMaps,
    NetProbe? net,
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
       offlineFiles = offlineFiles ?? MemoryOfflineFiles(),
       offlineMaps = offlineMaps ?? const NoOfflineMaps(),
       net = net ?? const AlwaysWifi(),
       family = family ?? MemoryFamilyStore(),
       memoryFiles = memoryFiles ?? MemoryMemoryFiles(),
       homeWidgets = homeWidgets ?? MemoryHomeWidgets(),
       liveFlight = liveFlight ?? MemoryLiveFlight(),
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

  /// Clima medio de cada mes (Explorar): medias de la NASA desde el servidor.
  late final ClimateApi climate = ClimateApi(api);

  /// Traductor de cartas de restaurante (pantalla Menú).
  late final MenuApi menu = MenuApi(api);

  /// "Copia este viaje": compartir con código y que Flyra lo adapte.
  late final SharedTripApi sharedTrips = SharedTripApi(api);

  /// Cromos con amigos: ligas, cambios y la ciudad de cada uno.
  late final LeagueApi leagues = LeagueApi(api);

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

  /// Abre una web, el marcador (tel:) o un SMS ya escrito (sms:).
  final OpenExternal openLink;
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

  /// Los perfiles de familia (cifrados en el Keystore del móvil).
  final FamilyStore family;

  /// La cámara de viaje (fotos con pegatina y vídeos); null = no hay.
  final TravelCameraFactory? newTravelCamera;

  /// Abre el menú "Compartir" del móvil.
  final ShareFiles share;

  /// Pinta la pegatina del viaje sobre una foto (en los tests, una falsa).
  final Future<Uint8List> Function(Uint8List jpeg, List<String> lines) sticker;

  /// Dónde se guardan las fotos y vídeos de Recuerdos (solo en el móvil).
  final MemoryFiles memoryFiles;

  /// Los widgets del escritorio de Android.
  final HomeWidgets homeWidgets;

  /// El aviso "en directo" del día del vuelo (programado en el móvil).
  final LiveFlight liveFlight;

  /// La brújula (hacia dónde miras). En los tests, una de mentira.
  final Stream<double?> Function() compass;

  /// Guía del aeropuerto (puertas, baños, cafés de OpenStreetMap).
  late final AirportGuideApi airportGuide = AirportGuideApi(api);

  /// ¿Poner al día los widgets al abrir la app? (en los tests, no).
  final bool syncWidgetsOnStart;

  /// Los aeropuertos (van dentro de la app). En los tests, unos pocos.
  final Future<Airports> Function() loadAirports;

  /// Tus recuerdos del viaje.
  late final MemoryBook memories = MemoryBook(prefs, memoryFiles);

  /// ¿Inicio en Modo fácil? (letras grandes y solo lo importante)
  late final EasyMode easyMode = EasyMode(prefs);

  /// Con quién te pone en contacto la pantalla "Ayuda".
  final HelpContacts help;

  /// Las audioguías que ya están guardadas en este móvil ("Sin conexión").
  final SavedGuides saved;

  /// Dónde se guardan los audios descargados.
  final OfflineFiles offlineFiles;

  /// El mapa descargado para usarlo sin red.
  final OfflineMaps offlineMaps;

  /// ¿Wifi, datos o nada? Decide si se puede descargar ahora.
  final NetProbe net;

  /// Las ciudades descargadas (la lista vive solo en el móvil).
  late final OfflineLibrary offlineCities = OfflineLibrary(prefs);

  /// Quien descarga una ciudad entera (mapa, guiones y audios).
  late final CityDownloader downloads = CityDownloader(
    api: api,
    geo: geo,
    guides: audioguides,
    files: offlineFiles,
    maps: offlineMaps,
    net: net,
    cities: offlineCities,
  );

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
