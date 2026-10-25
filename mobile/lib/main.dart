// Punto de entrada: lo primero que se ejecuta al abrir la app.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'app.dart';
import 'auth/auth_api.dart';
import 'auth/session.dart';
import 'auth/token_store.dart';
import 'core/api_client.dart';
import 'core/config.dart';
import 'core/services.dart';
import 'features/vault/doc_source.dart';
import 'features/vault/vault.dart';
import 'features/vault/vault_store.dart';
import 'features/camera/camera_device.dart';
import 'features/assistant/interpreter.dart';
import 'features/camera/speaker.dart';
import 'core/settings.dart';
import 'features/audioguide/guide_player.dart';
import 'features/family/family.dart';
import 'features/widgets/home_widgets.dart';
import 'features/memories/memories.dart';
import 'features/memories/travel_camera.dart';
import 'features/map/location.dart';
import 'features/map/map_style.dart';
import 'features/map/map_surface.dart';
import 'features/offline/offline_platform.dart';
import 'features/offline/city_pack.dart';
import 'features/offline/saved_guides.dart';
import 'features/push/firebase_push.dart';
import 'features/money/receipt_scanner.dart';
import 'features/push/notices.dart';
import 'features/push/push_registrar.dart';
import 'features/push/push_state.dart';
import 'features/route/data_licenses.dart';
import 'features/route/web_scene.dart';

Future<void> main() async {
  // Necesario antes de usar plugins (como el almacenamiento) en main().
  WidgetsFlutterBinding.ensureInitialized();
  registerDataLicenses();
  // Audioguías con el móvil bloqueado (maqueta "Bloqueo"): play/pausa y
  // partes en la pantalla de bloqueo, la notificación, el reloj y el coche.
  // Android pide un "servicio en primer plano" de tipo multimedia mientras
  // suena; la notificación se puede quitar al pausar.
  if (defaultTargetPlatform == TargetPlatform.android) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.nomadiq.app.audioguide',
      androidNotificationChannelName: 'Audioguías · Audio guides',
      androidNotificationIcon: 'mipmap/ic_launcher',
      androidStopForegroundOnPause: true,
    );
  }
  final SettingsStore store = await PreferencesSettingsStore.open();
  final SessionController session = SessionController(
    api: AuthApi(baseUrl: AppConfig.apiBaseUrl),
    store: SecureTokenStore(),
  );
  // Si quedó una sesión abierta, se recupera ANTES de la primera pantalla:
  // así quien ya entró no ve la Bienvenida ni un instante.
  await session.restore();
  // Notificaciones en la barra del móvil (avisos push y modo viaje).
  final bool mobile =
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  final NoticeCenter notices = mobile
      ? DeviceNotices.instance
      : const SilentNotices();
  if (notices is DeviceNotices) await notices.init();
  // Avisos push: de momento solo Android (el notifier aún no habla con
  // Apple). Si esta compilación no trae los datos de Firebase, sin push.
  final bool push =
      defaultTargetPlatform == TargetPlatform.android &&
      await startFirebasePush();
  final AppOfflineFiles offlineFiles = AppOfflineFiles();
  final AppServices services = AppServices(
    api: ApiClient(baseUrl: AppConfig.apiBaseUrl, session: session),
    location: const DeviceLocationSource(),
    mapSurface: (MapSurfaceSpec spec) => MapLibreSurface(spec: spec),
    webScene: (String html, void Function(String) onMessage) =>
        WebScene(html: html, onMessage: onMessage),
    newPlayer: JustAudioGuidePlayer.new,
    newCamera: DeviceCamera.new,
    newTravelCamera: DeviceTravelCamera.new,
    memoryFiles: AppMemoryFiles(),
    homeWidgets: DeviceHomeWidgets(),
    liveFlight: DeviceLiveFlight(),
    syncWidgetsOnStart: true,
    speaker: DeviceSpeaker(),
    translator: MlKitTranslator(),
    speechInput: DeviceSpeechInput(),
    receipts: DeviceReceiptScanner(),
    docSource: DeviceDocSource(),
    docReader: const DeviceDocTextReader(),
    vault: Vault(
      keys: SecureVaultKeyStore(),
      files: DirVaultFiles(),
      unlocker: DeviceUnlocker(),
    ),
    tilesUrl: AppConfig.tilesUrl,
    glyphsUrl: AppConfig.glyphsUrl,
    // "Sin conexión": archivos en la carpeta privada, el mapa descargado con
    // MapLibre y saber si hay wifi antes de gastar datos.
    offlineFiles: offlineFiles,
    offlineMaps: MapLibreOfflineMaps(
      styleJson: () => jsonEncode(
        buildMapStyle(
          look: MapLook.day,
          language: store.readLocale()?.split('-').first ?? 'en',
          tilesUrl: AppConfig.tilesUrl,
          glyphsUrl: AppConfig.glyphsUrl,
        ),
      ),
    ),
    net: const SystemNetProbe(),
    help: AppConfig.help,
    family: SecureFamilyStore(),
    // Las audioguías ya descargadas: si no hay red, se oyen estas.
    saved: OfflineSavedGuides(
      library: OfflineLibrary(store),
      fileUri: offlineFiles.uriOf,
    ),
    notices: notices,
    prefs: store,
  );
  if (push) {
    final PushRegistrar registrar = PushRegistrar(
      devices: DevicesApi(services.api),
      store: SecurePushStateStore(),
      transport: const FirebasePushTransport(),
      session: session,
      prefs: services.prefs,
    )..start();
    services.push = registrar;
    // Cada vez que se vuelve a la app, se comprueba el registro (si falló
    // por falta de red, aquí se reintenta). Casi siempre no hace nada.
    AppLifecycleListener(onResume: () => unawaited(registrar.sync()));
  }
  runApp(
    NomadIqApp(
      settings: SettingsController(store),
      session: session,
      services: services,
    ),
  );
}
