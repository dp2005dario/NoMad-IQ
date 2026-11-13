// Tests de pantallas: comprueban lo que VE el usuario, como si tocara el móvil.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/home/home_screen.dart';
import 'package:eclipta/features/vault/vault_screen.dart';
import 'package:eclipta/features/flights/flights_screen.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/auth/google_id_token.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/settings/language_screen.dart';
import 'package:eclipta/l10n/generated/app_localizations.dart';

import 'money_test.dart' as m;

import 'package:eclipta/features/memories/travel_camera_screen.dart';

import 'helpers.dart';

/// La Bienvenida solo se ve sin sesión.
Future<SettingsController> pumpWelcome(WidgetTester tester, {String? locale}) =>
    pumpApp(tester, locale: locale, session: newSession());

void main() {
  googleTests();
  testWidgets('la bienvenida sigue el idioma del móvil', (
    WidgetTester tester,
  ) async {
    setDeviceLocale(tester, 'es');
    await pumpWelcome(tester);
    expect(find.text('Entrar como invitado'), findsOneWidget);
    expect(find.text('Tu próximo viaje ya está despegando.'), findsOneWidget);
  });

  testWidgets('un idioma que no tenemos cae en inglés', (
    WidgetTester tester,
  ) async {
    setDeviceLocale(tester, 'tlh'); // klingon :)
    await pumpWelcome(tester);
    expect(find.text('Continue as guest'), findsOneWidget);
  });

  testWidgets('en árabe la app se dibuja de derecha a izquierda', (
    WidgetTester tester,
  ) async {
    await pumpWelcome(tester, locale: 'ar');
    final BuildContext context = tester.element(find.byType(Scaffold).first);
    expect(Directionality.of(context), TextDirection.rtl);
  });

  testWidgets('la bienvenida tiene vídeo y se puede silenciar', (
    WidgetTester tester,
  ) async {
    final List<FakeWelcomeVideo> videos = <FakeWelcomeVideo>[];
    final SessionController s = newSession();
    await pumpApp(
      tester,
      locale: 'es',
      session: s,
      services: fakeServices(
        s,
        welcomeVideo: () {
          final FakeWelcomeVideo v = FakeWelcomeVideo();
          videos.add(v);
          return v;
        },
      ),
    );
    expect(find.byKey(const Key('fake-welcome-video')), findsOneWidget);
    await tester.tap(find.byTooltip('Silenciar música'));
    await tester.pump();
    expect(videos.single.muted, isTrue);
    expect(find.byTooltip('Activar música'), findsOneWidget);
  });

  testWidgets('si el vídeo falla, fondo oscuro y todo sigue funcionando', (
    WidgetTester tester,
  ) async {
    final SessionController s = newSession();
    await pumpApp(
      tester,
      locale: 'es',
      session: s,
      services: fakeServices(
        s,
        welcomeVideo: () => FakeWelcomeVideo(works: false),
      ),
    );
    expect(find.byKey(const Key('fake-welcome-video')), findsNothing);
    expect(find.byTooltip('Silenciar música'), findsNothing);
    expect(find.text('Entrar como invitado'), findsOneWidget);
  });

  testWidgets('Google avisa de que llega pronto', (WidgetTester tester) async {
    await pumpWelcome(tester, locale: 'es');
    await tester.ensureVisible(find.text('Continuar con Google'));
    await tester.tap(find.text('Continuar con Google'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('invitado -> Inicio -> pestañas', (WidgetTester tester) async {
    await pumpWelcome(tester, locale: 'es');
    await tester.ensureVisible(find.text('Entrar como invitado'));
    await tester.tap(find.text('Entrar como invitado'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.tap(find.text('Vuelos'));
    await tester.pumpAndSettle();
    // Vuelos ya existe y un invitado también entra (ve los precios reales;
    // ver flights_test.dart).
    expect(find.byType(FlightsScreen), findsOneWidget);

    await tester.tap(find.byTooltip('Cámara'));
    await tester.pumpAndSettle();
    // Primero la cámara normal (fotos y vídeos a Recuerdos); deslizando a
    // la derecha, el escáner de monumentos.
    expect(find.byType(TravelCameraScreen), findsOneWidget);
    await tester.fling(
      find.byType(TravelCameraScreen),
      const Offset(300, 0),
      1000,
    );
    await tester.pumpAndSettle();
    // El modo cámara necesita cuenta (cada una tiene sus escaneos diarios).
    expect(
      find.textContaining('Inicia sesión para usar el modo cámara'),
      findsOneWidget,
    );

    // La cámara va a pantalla completa: la X vuelve a donde estabas.
    await tester.tap(find.byTooltip('Cerrar la cámara'));
    await tester.pumpAndSettle();
    expect(find.byType(FlightsScreen), findsOneWidget);
    await tester.tap(find.text('Inicio'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('los atajos abren su pantalla con flecha atrás', (
    WidgetTester tester,
  ) async {
    final SessionController guest = newSession()..continueAsGuest();
    final m.PageSpy spy = m.PageSpy();
    await pumpApp(
      tester,
      locale: 'es',
      session: guest,
      initialLocation: Routes.home,
      services: fakeServices(guest, webScene: spy.build),
    );
    // La Bóveda es el cuadrado 8 del carrusel de Inicio (una página web).
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    spy.send!('tile:7');
    await tester.pumpAndSettle();
    // La Bóveda es la maqueta (sin barra de arriba): se vuelve con el
    // botón "atrás" del móvil.
    expect(find.byType(VaultScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    // De vuelta en Inicio.
    expect(find.byType(VaultScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('una dirección inventada no rompe la app', (
    WidgetTester tester,
  ) async {
    await pumpApp(tester, locale: 'es', initialLocation: '/soon/nada');
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('cambiar de idioma cambia toda la app y se recuerda', (
    WidgetTester tester,
  ) async {
    setDeviceLocale(tester, 'es');
    final m.PageSpy spy = m.PageSpy();
    final SessionController session = newSession()..continueAsGuest();
    final MemorySettingsStore prefs = MemorySettingsStore();
    final SettingsController settings = await pumpApp(
      tester,
      initialLocation: Routes.language,
      session: session,
      services: fakeServices(session, prefs: prefs, webScene: spy.build),
    );
    await spy.wait(tester, () => spy.pages.isNotEmpty);
    Map<String, Object?> data() =>
        spy.data(LanguageScreen.lastBridge!, title: 'ECLIPTA · Idioma');
    final List<Object?> langs = data()['langs']! as List<Object?>;
    // "El del móvil" primero y luego los 25 idiomas de la app.
    expect(langs, hasLength(AppLocalizations.supportedLocales.length + 1));
    final Map<String, Object?> de =
        langs.firstWhere(
              (Object? l) => (l! as Map<String, Object?>)['code'] == 'de',
            )!
            as Map<String, Object?>;
    expect(de['native'], 'Deutsch');
    expect(de['sub'], 'Alemán');
    expect((de['pv']! as Map<String, Object?>)['btn'], 'Flüge');
    expect(data()['sel'], 'system');

    spy.send!('lang:de');
    await tester.pumpAndSettle();
    expect(settings.locale, const Locale('de'));
    expect(data()['title'], 'Sprache'); // el título ya está en alemán
    expect(data()['sel'], 'de');

    // Apagar "Flyra y las audioguías también en este idioma": se quedan en
    // alemán aunque la app cambie.
    spy.send!('ai:0');
    await tester.pumpAndSettle();
    expect(prefs.readData(LocalData.contentLang), 'de');
    expect(data()['ai'], isFalse);
    spy.send!('ai:1');
    await tester.pumpAndSettle();
    expect(prefs.readData(LocalData.contentLang), isNull);

    spy.send!('lang:system');
    await tester.pumpAndSettle();
    expect(settings.locale, isNull);
  });

  test('un idioma guardado se recupera al abrir la app', () async {
    final MemorySettingsStore store = MemorySettingsStore('pt-BR');
    final SettingsController settings = SettingsController(store);
    expect(settings.locale, const Locale('pt', 'BR'));
    await settings.setLocale(null);
    expect(store.readLocale(), isNull);
  });
}

class _FakeGoogle implements GoogleIdTokenSource {
  _FakeGoogle(this.token);
  final String? token;

  @override
  Future<String?> idToken() async => token;
}

void googleTests() {
  group('Continuar con Google', () {
    testWidgets('con token bueno entra y va a Inicio', (
      WidgetTester tester,
    ) async {
      final FakeGateway g = FakeGateway();
      final SessionController s = newSession(g);
      await pumpApp(
        tester,
        locale: 'es',
        session: s,
        services: fakeServices(
          s,
          gateway: g,
          googleSignIn: _FakeGoogle('token-bueno'),
        ),
      );
      await tester.tap(find.text('Continuar con Google'));
      await tester.pumpAndSettle();
      expect(s.status, SessionStatus.signedIn);
      expect(g.calls, contains('POST /v1/auth/google'));
    });

    testWidgets('sin Client ID en la app: avisa y no llama al servidor', (
      WidgetTester tester,
    ) async {
      final FakeGateway g = FakeGateway();
      final SessionController s = newSession(g);
      await pumpApp(
        tester,
        locale: 'es',
        session: s,
        services: fakeServices(s, gateway: g),
      );
      await tester.tap(find.text('Continuar con Google'));
      await tester.pumpAndSettle();
      expect(find.textContaining('no está disponible'), findsOneWidget);
      expect(g.calls, isNot(contains('POST /v1/auth/google')));
    });

    testWidgets('servidor sin Google (503): avisa', (
      WidgetTester tester,
    ) async {
      final FakeGateway g = FakeGateway()..googleOff = true;
      final SessionController s = newSession(g);
      await pumpApp(
        tester,
        locale: 'es',
        session: s,
        services: fakeServices(
          s,
          gateway: g,
          googleSignIn: _FakeGoogle('token-bueno'),
        ),
      );
      await tester.tap(find.text('Continuar con Google'));
      await tester.pumpAndSettle();
      expect(s.status, SessionStatus.signedOut);
      expect(find.textContaining('no está disponible'), findsOneWidget);
    });

    testWidgets('si cierras la ventana de Google no pasa nada', (
      WidgetTester tester,
    ) async {
      final FakeGateway g = FakeGateway();
      final SessionController s = newSession(g);
      await pumpApp(
        tester,
        locale: 'es',
        session: s,
        services: fakeServices(s, gateway: g, googleSignIn: _FakeGoogle(null)),
      );
      await tester.tap(find.text('Continuar con Google'));
      await tester.pumpAndSettle();
      expect(s.status, SessionStatus.signedOut);
      expect(g.calls, isNot(contains('POST /v1/auth/google')));
    });
  });
}
