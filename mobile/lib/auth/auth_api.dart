// Cliente del auth-gateway: las llamadas HTTP de registro, login, renovar
// sesión, cerrar sesión y "quién soy". Solo habla con el servidor; QUÉ hacer
// con las respuestas lo decide SessionController (session.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

/// Qué puede salir mal, ya clasificado. La pantalla elige el texto traducido
/// según el tipo (nunca enseña el mensaje en español que manda el servidor).
enum AuthError {
  invalidCredentials, // 401 en login: email o contraseña incorrectos
  sessionExpired, // 401 al renovar: hay que volver a entrar
  emailTaken, // 409: ya existe una cuenta con ese email
  invalidInput, // 400: datos rechazados (p. ej. contraseña débil)
  rateLimited, // 429: demasiados intentos, esperar
  unavailable, // 5xx: el servidor tiene problemas
  network, // sin conexión o el servidor no responde
}

class AuthException implements Exception {
  const AuthException(this.error, {this.retryAfter});

  final AuthError error;

  /// En un 429, cuánto pide el servidor que esperemos antes de reintentar.
  final Duration? retryAfter;

  @override
  String toString() => 'AuthException($error)';
}

/// Los tokens que devuelve el login o la renovación.
class TokenPair {
  const TokenPair({
    required this.accessToken,
    required this.accessExpiresAt,
    required this.refreshToken,
  });

  /// Pase corto (15 min) que se envía en cada petición.
  final String accessToken;
  final DateTime accessExpiresAt;

  /// Pase largo, de UN solo uso: cada renovación devuelve uno nuevo.
  final String refreshToken;

  @override
  String toString() => 'TokenPair(***)'; // nunca imprimir tokens en logs
}

class UserProfile {
  const UserProfile({required this.id, required this.email});

  final String id;
  final String email;
}

class AuthApi {
  AuthApi({
    required Uri baseUrl,
    http.Client? client,
    DateTime Function()? clock,
    this.timeout = const Duration(seconds: 10),
  }) : _base = baseUrl,
       _client = client ?? http.Client(),
       _now = clock ?? DateTime.now;

  final Uri _base;
  final http.Client _client;
  final DateTime Function() _now;

  /// Tiempo máximo por llamada: con mala cobertura es mejor fallar y avisar
  /// que dejar al usuario mirando una rueda girando para siempre.
  final Duration timeout;

  Future<void> register(String email, String password) async {
    await _send('POST', '/v1/auth/register', <String, Object?>{
      'email': email,
      'password': password,
    });
  }

  Future<TokenPair> login(String email, String password) async => _tokens(
    await _send('POST', '/v1/auth/login', <String, Object?>{
      'email': email,
      'password': password,
    }),
  );

  /// Cambia el pase largo por un par nuevo. Un 401 aquí significa que la
  /// sesión ya no vale (caducó, se cerró en otro sitio o se reutilizó).
  Future<TokenPair> refresh(String refreshToken) async {
    try {
      return _tokens(
        await _send('POST', '/v1/auth/refresh', <String, Object?>{
          'refresh_token': refreshToken,
        }),
      );
    } on AuthException catch (e) {
      if (e.error == AuthError.invalidCredentials) {
        throw const AuthException(AuthError.sessionExpired);
      }
      rethrow;
    }
  }

  Future<void> logout(String accessToken, String refreshToken) async {
    await _send('POST', '/v1/auth/logout', <String, Object?>{
      'refresh_token': refreshToken,
    }, accessToken: accessToken);
  }

  Future<UserProfile> me(String accessToken) async {
    final Map<String, Object?> json = await _send(
      'GET',
      '/v1/me',
      null,
      accessToken: accessToken,
    );
    return UserProfile(id: _string(json, 'id'), email: _string(json, 'email'));
  }

  void close() => _client.close();

  // ---------------------------------------------------------------------------

  Future<Map<String, Object?>> _send(
    String method,
    String path,
    Map<String, Object?>? body, {
    String? accessToken,
  }) async {
    final http.Request request = http.Request(method, _base.resolve(path))
      ..headers['Accept'] = 'application/json';
    if (accessToken != null) {
      request.headers['Authorization'] = 'Bearer $accessToken';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw const AuthException(AuthError.network);
    } on SocketException {
      throw const AuthException(AuthError.network);
    } on http.ClientException {
      throw const AuthException(AuthError.network);
    }

    final int status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (response.body.isEmpty) return const <String, Object?>{};
      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        throw const AuthException(AuthError.unavailable);
      }
      return decoded;
    }
    throw switch (status) {
      400 || 422 => const AuthException(AuthError.invalidInput),
      401 => const AuthException(AuthError.invalidCredentials),
      409 => const AuthException(AuthError.emailTaken),
      429 => AuthException(
        AuthError.rateLimited,
        retryAfter: _retryAfter(response.headers['retry-after']),
      ),
      _ => const AuthException(AuthError.unavailable),
    };
  }

  TokenPair _tokens(Map<String, Object?> json) {
    final Object? expiresIn = json['expires_in'];
    if (expiresIn is! int) throw const AuthException(AuthError.unavailable);
    return TokenPair(
      accessToken: _string(json, 'access_token'),
      accessExpiresAt: _now().add(Duration(seconds: expiresIn)),
      refreshToken: _string(json, 'refresh_token'),
    );
  }

  /// Lee un texto obligatorio del JSON. Si el servidor manda algo raro, se trata
  /// como un fallo del servidor (no se deja pasar un null escondido).
  static String _string(Map<String, Object?> json, String key) {
    final Object? value = json[key];
    if (value is! String || value.isEmpty) {
      throw const AuthException(AuthError.unavailable);
    }
    return value;
  }

  static Duration? _retryAfter(String? header) {
    final int? seconds = int.tryParse(header ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }
}
