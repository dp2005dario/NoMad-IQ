// Utilidades compartidas por los tests: montan la app sin tocar el disco
// ni la red (el "servidor" es un MockClient que responde lo que le digamos).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nomadiq/app.dart';
import 'package:nomadiq/auth/auth_api.dart';
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/auth/token_store.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/core/settings.dart';

/// Un auth-gateway falso, en memoria, que se comporta como el de verdad:
/// una cuenta, pases largos de un solo uso y errores con sus códigos HTTP.
class FakeGateway {
  final Map<String, String> accounts = <String, String>{};
  final Set<String> liveRefresh = <String>{};
  final List<String> calls = <String>[];
  int _n = 0;

  /// Si se pone, TODAS las llamadas responden este código (simula averías).
  int? failWith;

  late final http.Client client = MockClient((http.Request req) async {
    calls.add('${req.method} ${req.url.path}');
    if (failWith != null) return http.Response('', failWith!);
    final Map<String, Object?> body = req.body.isEmpty
        ? <String, Object?>{}
        : jsonDecode(req.body) as Map<String, Object?>;
    switch (req.url.path) {
      case '/v1/auth/register':
        final String email = body['email']! as String;
        if (accounts.containsKey(email)) return http.Response('{}', 409);
        accounts[email] = body['password']! as String;
        return _json(<String, Object?>{'id': 'u1', 'email': email}, 201);
      case '/v1/auth/login':
        if (accounts[body['email']] != body['password']) {
          return http.Response('{}', 401);
        }
        return _tokens();
      case '/v1/auth/refresh':
        if (!liveRefresh.remove(body['refresh_token'])) {
          return http.Response('{}', 401);
        }
        return _tokens();
      case '/v1/auth/logout':
        liveRefresh.remove(body['refresh_token']);
        return http.Response('', 204);
      case '/v1/me':
        return _json(<String, Object?>{
          'id': 'u1',
          'email': accounts.keys.isEmpty ? 'x@y.z' : accounts.keys.first,
        });
    }
    return http.Response('', 404);
  });

  http.Response _tokens() {
    final String refresh = 'r${_n++}';
    liveRefresh.add(refresh);
    return _json(<String, Object?>{
      'access_token': 'a$_n',
      'token_type': 'Bearer',
      'expires_in': 900,
      'refresh_token': refresh,
      'refresh_token_expires_in': 2592000,
    });
  }

  static http.Response _json(Map<String, Object?> body, [int status = 200]) =>
      http.Response(
        jsonEncode(body),
        status,
        headers: <String, String>{'content-type': 'application/json'},
      );

  AuthApi api() =>
      AuthApi(baseUrl: Uri.parse('http://gateway.test'), client: client);
}

SessionController newSession([FakeGateway? gateway, TokenStore? store]) =>
    SessionController(
      api: (gateway ?? FakeGateway()).api(),
      store: store ?? MemoryTokenStore(),
    );

/// Monta la app con un idioma fijo y espera a que termine de dibujarse.
Future<SettingsController> pumpApp(
  WidgetTester tester, {
  String? locale,
  String initialLocation = Routes.welcome,
  SessionController? session,
}) async {
  final SettingsController settings = SettingsController(
    MemorySettingsStore(locale),
  );
  final SessionController s = session ?? (newSession()..continueAsGuest());
  await tester.pumpWidget(
    NomadIqApp(
      settings: settings,
      session: s,
      router: buildRouter(session: s, initialLocation: initialLocation),
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
