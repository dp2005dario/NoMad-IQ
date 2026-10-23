// Dónde se guarda el pase largo (refresh token) entre aperturas de la app.
//
// En el móvil se usa flutter_secure_storage: cifra con una clave que vive en
// el chip de seguridad del teléfono (Android Keystore / Llavero de iOS). Ni
// otra app ni alguien que copie los archivos del móvil puede leerlo.
// El pase corto (access token) NUNCA se guarda: vive solo en memoria.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class TokenStore {
  Future<String?> readRefreshToken();
  Future<void> writeRefreshToken(String token);
  Future<void> clear();
}

final class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Si el móvil se restaura desde una copia de seguridad, la clave
            // del chip no viaja con ella: mejor borrar y pedir login otra vez.
            aOptions: AndroidOptions(resetOnError: true),
            // iOS: solo legible con el móvil desbloqueado al menos una vez y
            // nunca se copia a otro iPhone.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const String _key = 'refresh_token';
  final FlutterSecureStorage _storage;

  @override
  Future<String?> readRefreshToken() => _storage.read(key: _key);

  @override
  Future<void> writeRefreshToken(String token) =>
      _storage.write(key: _key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Para los tests: guarda en memoria.
final class MemoryTokenStore implements TokenStore {
  MemoryTokenStore([this.token]);

  String? token;

  @override
  Future<String?> readRefreshToken() async => token;

  @override
  Future<void> writeRefreshToken(String value) async => token = value;

  @override
  Future<void> clear() async => token = null;
}
