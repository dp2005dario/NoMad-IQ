// Tests de pantallas: comprueban lo que VE el usuario, como si tocara el móvil.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/auth/google_id_token.dart';
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/settings.dart';

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
    expect(find.text('Hola, viajero'), findsOneWidget);

    await tester.tap(find.text('Vuelos'));
    await tester.pumpAndSettle();
    // Vuelos ya existe y un invitado también entra (ve los precios reales;
    // ver flights_test.dart).
    expect(find.text('Cazador de vuelos'), findsOneWidget);

    await tester.tap(find.byTooltip('Cámara'));
    await tester.pumpAndSettle();
    // El modo cámara necesita cuenta (cada una tiene sus escaneos diarios).
    expect(
      find.textContaining('Inicia sesión para usar el modo cámara'),
      findsOneWidget,
    );

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
    expect(find.text('Toca para abrir con tu huella'), findsOneWidget);
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
