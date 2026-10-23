// Punto de entrada: lo primero que se ejecuta al abrir la app.
import 'package:flutter/material.dart';

import 'app.dart';
import 'auth/auth_api.dart';
import 'auth/session.dart';
import 'auth/token_store.dart';
import 'core/api_client.dart';
import 'core/config.dart';
import 'core/services.dart';
import 'core/settings.dart';
import 'features/audioguide/guide_player.dart';
import 'features/map/location.dart';
import 'features/map/map_surface.dart';

Future<void> main() async {
  // Necesario antes de usar plugins (como el almacenamiento) en main().
  WidgetsFlutterBinding.ensureInitialized();
  final SettingsStore store = await PreferencesSettingsStore.open();
  final SessionController session = SessionController(
    api: AuthApi(baseUrl: AppConfig.apiBaseUrl),
    store: SecureTokenStore(),
  );
  // Si quedó una sesión abierta, se recupera ANTES de la primera pantalla:
  // así quien ya entró no ve la Bienvenida ni un instante.
  await session.restore();
  final AppServices services = AppServices(
    api: ApiClient(baseUrl: AppConfig.apiBaseUrl, session: session),
    location: const DeviceLocationSource(),
    mapSurface: (MapSurfaceSpec spec) => MapLibreSurface(spec: spec),
    newPlayer: JustAudioGuidePlayer.new,
    tilesUrl: AppConfig.tilesUrl,
    glyphsUrl: AppConfig.glyphsUrl,
  );
  runApp(
    NomadIqApp(
      settings: SettingsController(store),
      session: session,
      services: services,
    ),
  );
}
