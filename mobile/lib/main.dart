// Punto de entrada: lo primero que se ejecuta al abrir la app.
import 'package:flutter/material.dart';

import 'app.dart';
import 'core/settings.dart';

Future<void> main() async {
  // Necesario antes de usar plugins (como el almacenamiento) en main().
  WidgetsFlutterBinding.ensureInitialized();
  final SettingsStore store = await PreferencesSettingsStore.open();
  runApp(NomadIqApp(settings: SettingsController(store)));
}
