// Cliente HTTP para TODOS los servicios que hay detrás de la puerta de entrada
// (geo-engine, ai-orchestrator...). Se encarga de lo que es igual en todos:
// poner el pase (token), renovarlo si el servidor lo rechaza, el tiempo
// máximo de espera y traducir los códigos HTTP a errores con nombre.
//
// El auth-gateway tiene su propio cliente (auth/auth_api.dart) porque allí
// el pase se CONSIGUE; aquí solo se USA.
import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../auth/auth_api.dart';
import '../auth/session.dart';

/// Qué puede salir mal al llamar a un servicio, ya clasificado.
enum ApiError {
  signedOut, // no hay cuenta (invitado) o la sesión caducó
  notFound, // 404: no existe... o aún no está lista (una audioguía)
  gone, // 410: existió pero se retiró (un audio antiguo)
  conflict, // 409: choca con algo que ya existe (p. ej. un id de móvil ajeno)
  invalidInput, // 400/422: el servidor rechaza lo que mandamos
  rateLimited, // 429: demasiadas peticiones, esperar
  unavailable, // 5xx o una respuesta que no entendemos
  network, // sin conexión o el servidor no responde
}

class ApiException implements Exception {
  const ApiException(this.error, {this.retryAfter});

  final ApiError error;

  /// En un 429, cuánto pide el servidor que esperemos.
  final Duration? retryAfter;

  @override
  String toString() => 'ApiException($error)';
}

class ApiClient {
  ApiClient({
    required Uri baseUrl,
    required this._session,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
  }) : _base = baseUrl,
       _client = client ?? http.Client();

  final Uri _base;
  final SessionController _session;
  final http.Client _client;
  final Duration timeout;

  /// Convierte una ruta del servidor ("/v1/audio/...") en dirección completa.
  /// Si ya es completa (https://cdn...), se deja tal cual.
  Uri resolve(String pathOrUrl) => _base.resolve(pathOrUrl);

  Future<Object?> getJson(String path, {Map<String, String>? query}) {
    final Uri uri = _base
        .resolve(path)
        .replace(
          queryParameters: query == null || query.isEmpty ? null : query,
        );
    return _send('GET', uri, null);
  }

  Future<Object?> postJson(String path, Object body) =>
      _send('POST', _base.resolve(path), jsonEncode(body));

  /// PUT = "guarda esto con este nombre" (si ya existía, se sustituye).
  Future<Object?> putJson(String path, Object body) =>
      _send('PUT', _base.resolve(path), jsonEncode(body));

  Future<Object?> delete(String path) =>
      _send('DELETE', _base.resolve(path), null);

  /// La sesión con la que se firman las peticiones (para quien necesite
  /// enterarse de cuándo se entra o se sale).
  SessionController get session => _session;

  void close() => _client.close();

  // ---------------------------------------------------------------------------

  Future<Object?> _send(String method, Uri uri, String? body) async {
    // Sin cuenta no hay pase: ni lo intentamos (la puerta diría 401).
    if (_session.status != SessionStatus.signedIn) {
      throw const ApiException(ApiError.signedOut);
    }
    String token = await _token(() => _session.accessToken());
    http.Response response = await _once(method, uri, body, token);
    if (response.statusCode == 401) {
      // El pase no valía (p. ej. la sesión se cerró en otro sitio): se pide
      // uno nuevo UNA vez. Si tampoco vale, la sesión se da por terminada.
      final String rejected = token;
      token = await _token(() => _session.renewAccessToken(rejected));
      response = await _once(method, uri, body, token);
    }
    return _decode(response);
  }

  /// Pide el pase a la sesión y convierte sus errores en los nuestros.
  static Future<String> _token(Future<String> Function() get) async {
    try {
      return await get();
    } on AuthException catch (e) {
      throw ApiException(switch (e.error) {
        AuthError.network => ApiError.network,
        AuthError.rateLimited => ApiError.rateLimited,
        AuthError.unavailable => ApiError.unavailable,
        _ => ApiError.signedOut,
      });
    }
  }

  Future<http.Response> _once(
    String method,
    Uri uri,
    String? body,
    String token,
  ) async {
    final http.Request request = http.Request(method, uri)
      ..headers['Accept'] = 'application/json'
      ..headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body;
    }
    try {
      return await http.Response.fromStream(
        await _client.send(request).timeout(timeout),
      ).timeout(timeout);
    } on TimeoutException {
      throw const ApiException(ApiError.network);
    } on SocketException {
      throw const ApiException(ApiError.network);
    } on http.ClientException {
      throw const ApiException(ApiError.network);
    }
  }

  static Object? _decode(http.Response response) {
    final int status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (response.body.isEmpty) return null;
      try {
        // utf8 explícito: los nombres de zonas llevan tildes, árabe, chino...
        return jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw const ApiException(ApiError.unavailable);
      }
    }
    throw switch (status) {
      401 || 403 => const ApiException(ApiError.signedOut),
      404 => const ApiException(ApiError.notFound),
      409 => const ApiException(ApiError.conflict),
      410 => const ApiException(ApiError.gone),
      400 || 422 => const ApiException(ApiError.invalidInput),
      429 => ApiException(
        ApiError.rateLimited,
        retryAfter: _retryAfter(response.headers['retry-after']),
      ),
      _ => const ApiException(ApiError.unavailable),
    };
  }

  static Duration? _retryAfter(String? header) {
    final int? seconds = int.tryParse(header ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }
}
