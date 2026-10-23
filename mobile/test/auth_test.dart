// Tests del inicio de sesión: el cliente HTTP, la sesión y las pantallas.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nomadiq/auth/auth_api.dart';
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/auth/token_store.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/home/home_screen.dart';

import 'helpers.dart';

const String email = 'dario@example.com';
const String password = 'una-contraseña-larga';

void main() {
  group('AuthApi', () {
    Future<AuthError> errorFor(
      int status, {
      Map<String, String>? headers,
    }) async {
      final AuthApi api = AuthApi(
        baseUrl: Uri.parse('http://x'),
        client: MockClient(
          (_) async =>
              http.Response('', status, headers: headers ?? <String, String>{}),
        ),
      );
      try {
        await api.login(email, password);
      } on AuthException catch (e) {
        return e.error;
      }
      fail('debía fallar');
    }

    test('cada código HTTP se convierte en su error', () async {
      expect(await errorFor(400), AuthError.invalidInput);
      expect(await errorFor(401), AuthError.invalidCredentials);
      expect(await errorFor(409), AuthError.emailTaken);
      expect(await errorFor(429), AuthError.rateLimited);
      expect(await errorFor(503), AuthError.unavailable);
    });

    test('429 lee Retry-After', () async {
      final AuthApi api = AuthApi(
        baseUrl: Uri.parse('http://x'),
        client: MockClient(
          (_) async => http.Response(
            '',
            429,
            headers: <String, String>{'retry-after': '60'},
          ),
        ),
      );
      await expectLater(
        api.login(email, password),
        throwsA(
          isA<AuthException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 60),
          ),
        ),
      );
    });

    test('sin red o respuesta rara no rompe la app', () async {
      final AuthApi offline = AuthApi(
        baseUrl: Uri.parse('http://x'),
        client: MockClient((_) async => throw http.ClientException('sin red')),
      );
      await expectLater(
        offline.login(email, password),
        throwsA(
          isA<AuthException>().having(
            (e) => e.error,
            'error',
            AuthError.network,
          ),
        ),
      );
      final AuthApi weird = AuthApi(
        baseUrl: Uri.parse('http://x'),
        client: MockClient((_) async => http.Response('[1,2]', 200)),
      );
      await expectLater(
        weird.login(email, password),
        throwsA(
          isA<AuthException>().having(
            (e) => e.error,
            'error',
            AuthError.unavailable,
          ),
        ),
      );
    });

    test('un 401 al renovar significa sesión caducada', () async {
      final FakeGateway gw = FakeGateway();
      await expectLater(
        gw.api().refresh('no-existe'),
        throwsA(
          isA<AuthException>().having(
            (e) => e.error,
            'error',
            AuthError.sessionExpired,
          ),
        ),
      );
    });

    test('los tokens nunca salen en los logs', () {
      final TokenPair p = TokenPair(
        accessToken: 'secreto',
        accessExpiresAt: DateTime(2030),
        refreshToken: 'secreto2',
      );
      expect(p.toString(), isNot(contains('secreto')));
    });
  });

  group('SessionController', () {
    test('registro -> dentro, pase largo guardado y perfil cargado', () async {
      final FakeGateway gw = FakeGateway();
      final MemoryTokenStore store = MemoryTokenStore();
      final SessionController s = newSession(gw, store);
      await s.register(' $email ', password);
      expect(s.status, SessionStatus.signedIn);
      expect(s.user?.email, email);
      expect(store.token, isNotNull);
    });

    test('al reabrir la app se recupera la sesión', () async {
      final FakeGateway gw = FakeGateway();
      final MemoryTokenStore store = MemoryTokenStore();
      await newSession(gw, store).register(email, password);

      final SessionController reopened = newSession(gw, store);
      await reopened.restore();
      expect(reopened.status, SessionStatus.signedIn);
      await pumpEventQueue(); // el perfil se carga en segundo plano
      expect(reopened.user?.email, email);
    });

    test('dos peticiones a la vez hacen UNA sola renovación', () async {
      final FakeGateway gw = FakeGateway();
      final MemoryTokenStore store = MemoryTokenStore();
      await newSession(gw, store).register(email, password);
      final SessionController s = newSession(gw, store);
      await s.restore();
      await pumpEventQueue();
      gw.calls.clear();

      // Fuerza la caducidad del pase corto con un reloj adelantado.
      final SessionController late = SessionController(
        api: gw.api(),
        store: store,
        clock: () => DateTime.now().add(const Duration(hours: 1)),
      );
      await late.restore();
      await pumpEventQueue();
      gw.calls.clear();
      final List<String> tokens = await Future.wait(<Future<String>>[
        late.accessToken(),
        late.accessToken(),
      ]);
      expect(tokens.toSet(), hasLength(1));
      expect(gw.calls.where((c) => c.endsWith('/refresh')), hasLength(1));
    });

    test('sesión caducada -> fuera y almacén vacío', () async {
      final MemoryTokenStore store = MemoryTokenStore('robado-o-caducado');
      final SessionController s = newSession(FakeGateway(), store);
      await s.restore();
      await pumpEventQueue();
      expect(s.status, SessionStatus.signedOut);
      expect(store.token, isNull);
    });

    test('sin conexión al abrir se sigue dentro (modo sin conexión)', () async {
      final FakeGateway gw = FakeGateway()..failWith = 503;
      final SessionController s = newSession(gw, MemoryTokenStore('r0'));
      await s.restore();
      await pumpEventQueue();
      expect(s.status, SessionStatus.signedIn);
    });

    test(
      'cerrar sesión borra el móvil y anula el pase en el servidor',
      () async {
        final FakeGateway gw = FakeGateway();
        final MemoryTokenStore store = MemoryTokenStore();
        final SessionController s = newSession(gw, store);
        await s.register(email, password);
        await s.signOut();
        expect(s.status, SessionStatus.signedOut);
        expect(store.token, isNull);
        expect(gw.liveRefresh, isEmpty);
      },
    );

    test('si el servidor no responde al salir, se sale igualmente', () async {
      final FakeGateway gw = FakeGateway();
      final SessionController s = newSession(gw);
      await s.register(email, password);
      gw.failWith = 503;
      await s.signOut();
      expect(s.status, SessionStatus.signedOut);
    });
  });

  test('el portero manda a cada uno a su sitio', () {
    expect(
      sessionRedirect(SessionStatus.signedOut, Routes.home),
      Routes.welcome,
    );
    expect(sessionRedirect(SessionStatus.signedOut, Routes.signIn), isNull);
    expect(sessionRedirect(SessionStatus.guest, Routes.welcome), Routes.home);
    expect(sessionRedirect(SessionStatus.guest, Routes.signIn), isNull);
    expect(sessionRedirect(SessionStatus.signedIn, Routes.signIn), Routes.home);
    expect(sessionRedirect(SessionStatus.signedIn, Routes.flights), isNull);
  });

  test('el saludo usa la primera parte del correo', () {
    expect(displayName('dario.perez@gmail.com'), 'Dario');
    expect(displayName(null), isNull);
    expect(displayName('@raro'), isNull);
  });

  group('pantallas', () {
    testWidgets('crear cuenta desde la Bienvenida y cerrar sesión', (
      WidgetTester tester,
    ) async {
      final FakeGateway gw = FakeGateway();
      await pumpApp(tester, locale: 'es', session: newSession(gw));
      await tester.tap(find.text('Continuar con correo'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('¿Eres nuevo? Crea una cuenta'));
      await tester.pumpAndSettle();

      // Validación en el móvil: contraseña corta y correo raro.
      await tester.enterText(find.byType(TextFormField).at(0), 'no-es-correo');
      await tester.enterText(find.byType(TextFormField).at(1), 'corta');
      await tester.tap(find.widgetWithText(FilledButton, 'Crear cuenta'));
      await tester.pumpAndSettle();
      expect(find.text('Escribe un correo válido'), findsOneWidget);
      expect(find.text('Usa al menos 12 caracteres'), findsOneWidget);
      expect(gw.calls, isEmpty); // no se molesta al servidor

      await tester.enterText(find.byType(TextFormField).at(0), email);
      await tester.enterText(find.byType(TextFormField).at(1), password);
      await tester.tap(find.widgetWithText(FilledButton, 'Crear cuenta'));
      await tester.pumpAndSettle();
      expect(find.text('Hola, Dario'), findsOneWidget);

      await tester.tap(find.byTooltip('Cuenta'));
      await tester.pumpAndSettle();
      expect(find.text(email), findsOneWidget);
      await tester.tap(find.text('Cerrar sesión'));
      await tester.pumpAndSettle();
      expect(
        find.text('Continuar con correo'),
        findsOneWidget,
      ); // de vuelta a la Bienvenida
    });

    testWidgets('contraseña incorrecta se explica en el idioma del usuario', (
      WidgetTester tester,
    ) async {
      final FakeGateway gw = FakeGateway()..accounts[email] = password;
      await pumpApp(
        tester,
        locale: 'fr',
        session: newSession(gw),
        initialLocation: Routes.signIn,
      );
      await tester.enterText(find.byType(TextFormField).at(0), email);
      await tester.enterText(find.byType(TextFormField).at(1), 'mala');
      await tester.tap(find.widgetWithText(FilledButton, 'Se connecter'));
      await tester.pumpAndSettle();
      expect(find.text('E-mail ou mot de passe incorrect'), findsOneWidget);
    });

    testWidgets(
      'sin sesión no se puede entrar a Inicio por la puerta de atrás',
      (WidgetTester tester) async {
        await pumpApp(
          tester,
          locale: 'es',
          session: newSession(),
          initialLocation: Routes.flights,
        );
        expect(find.text('Continuar con correo'), findsOneWidget);
      },
    );

    testWidgets('el invitado puede pasar a crear su cuenta', (
      WidgetTester tester,
    ) async {
      await pumpApp(tester, locale: 'es', initialLocation: Routes.home);
      expect(find.text('Hola, viajero'), findsOneWidget);
      await tester.tap(find.byTooltip('Cuenta'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inicia sesión o crea una cuenta'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, 'Entrar'), findsOneWidget);
    });
  });
}
