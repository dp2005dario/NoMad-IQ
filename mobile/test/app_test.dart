// Tests de pantallas: comprueban lo que VE el usuario, como si tocara el móvil.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';

import 'helpers.dart';

void main() {
  testWidgets('la bienvenida sigue el idioma del móvil', (
    WidgetTester tester,
  ) async {
    setDeviceLocale(tester, 'es');
    await pumpApp(tester);
    expect(find.text('Entrar como invitado'), findsOneWidget);
    expect(find.textContaining('soy Flyra'), findsOneWidget);
  });

  testWidgets('un idioma que no tenemos cae en inglés', (
    WidgetTester tester,
  ) async {
    setDeviceLocale(tester, 'tlh'); // klingon :)
    await pumpApp(tester);
    expect(find.text('Continue as guest'), findsOneWidget);
  });

  testWidgets('en árabe la app se dibuja de derecha a izquierda', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, locale: 'ar');
    final BuildContext context = tester.element(find.byType(Scaffold).first);
    expect(Directionality.of(context), TextDirection.rtl);
  });

  testWidgets('Google y correo avisan de que llegan pronto', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, locale: 'es');
    await tester.tap(find.text('Continuar con Google'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('invitado -> Inicio -> pestañas', (WidgetTester tester) async {
    await pumpApp(tester, locale: 'es');
    await tester.tap(find.text('Entrar como invitado'));
    await tester.pumpAndSettle();
    expect(find.text('Hola, viajero'), findsOneWidget);

    await tester.tap(find.text('Vuelos'));
    await tester.pumpAndSettle();
    expect(find.text('Muy pronto'), findsOneWidget);
    expect(find.textContaining('Vuelos está en camino'), findsOneWidget);

    await tester.tap(find.byTooltip('Cámara'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cámara está en camino'), findsOneWidget);

    await tester.tap(find.text('Inicio'));
    await tester.pumpAndSettle();
    expect(find.text('Hola, viajero'), findsOneWidget);
  });

  testWidgets('los atajos abren su pantalla con flecha atrás', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, locale: 'es', initialLocation: Routes.home);
    await tester.tap(find.text('Bóveda'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Bóveda está en camino'), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Hola, viajero'), findsOneWidget);
  });

  testWidgets('una dirección inventada no rompe la app', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, locale: 'es', initialLocation: '/soon/nada');
    expect(find.text('Hola, viajero'), findsOneWidget);
  });

  testWidgets('cambiar de idioma cambia toda la app y se recuerda', (
    WidgetTester tester,
  ) async {
    setDeviceLocale(tester, 'es');
    final SettingsController settings = await pumpApp(
      tester,
      initialLocation: Routes.language,
    );
    await tester.enterText(find.byType(TextField), 'deut');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Deutsch'));
    await tester.pumpAndSettle();
    expect(settings.locale, const Locale('de'));
    expect(find.text('Sprache'), findsOneWidget); // el título ya está en alemán

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.textContaining('zzz'), findsWidgets);
    expect(find.byType(RadioListTile<String?>), findsNothing);
  });

  test('un idioma guardado se recupera al abrir la app', () async {
    final MemorySettingsStore store = MemorySettingsStore('pt-BR');
    final SettingsController settings = SettingsController(store);
    expect(settings.locale, const Locale('pt', 'BR'));
    await settings.setLocale(null);
    expect(store.readLocale(), isNull);
  });
}
