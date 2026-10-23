// Utilidades compartidas por los tests: montan la app sin tocar el disco.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/app.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';

/// Monta la app con un idioma fijo y espera a que termine de dibujarse.
Future<SettingsController> pumpApp(
  WidgetTester tester, {
  String? locale,
  String initialLocation = Routes.welcome,
}) async {
  final SettingsController settings = SettingsController(
    MemorySettingsStore(locale),
  );
  await tester.pumpWidget(
    NomadIqApp(
      settings: settings,
      router: buildRouter(initialLocation: initialLocation),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

/// Simula un móvil configurado en el idioma [tag] (lo que llega del sistema).
void setDeviceLocale(WidgetTester tester, String tag) {
  tester.platformDispatcher.localesTestValue = <Locale>[Locale(tag)];
  addTearDown(tester.platformDispatcher.clearLocalesTestValue);
}
