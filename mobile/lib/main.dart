// Punto de entrada: lo primero que se ejecuta al abrir la app.
import 'package:flutter/material.dart';

import 'app.dart';
import 'auth/auth_api.dart';
import 'auth/session.dart';
import 'auth/token_store.dart';
import 'core/config.dart';
import 'core/settings.dart';

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
  runApp(NomadIqApp(settings: SettingsController(store), session: session));
}
