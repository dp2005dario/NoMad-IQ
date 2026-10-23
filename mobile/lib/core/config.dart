// Configuración que cambia según dónde se ejecute la app (tu PC o producción).
//
// Se pasa al compilar, sin tocar el código:
//   flutter run --dart-define=NOMADIQ_API_URL=https://api.nomadiq.app
// Si no se pasa nada, se usa la dirección de desarrollo: 10.0.2.2 es "el PC"
// visto desde el emulador de Android (donde docker compose sirve la puerta de entrada "edge", puerto 8080).
import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  static const String _apiUrl = String.fromEnvironment(
    'NOMADIQ_API_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );

  /// Dirección base del backend (el auth-gateway, y más adelante el proxy de borde).
  static Uri get apiBaseUrl {
    final Uri uri = Uri.parse(_apiUrl);
    // En la versión publicada SOLO se permite HTTPS: las contraseñas y los
    // tokens nunca deben viajar sin cifrar. Mejor que la app no arranque a
    // que lo haga de forma insegura.
    if (kReleaseMode && uri.scheme != 'https') {
      throw StateError('NOMADIQ_API_URL debe ser https:// en producción');
    }
    return uri;
  }
}
