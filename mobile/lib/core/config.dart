// Configuración que cambia según dónde se ejecute la app (tu PC o producción).
//
// Se pasa al compilar, sin tocar el código:
//   flutter run --dart-define=NOMADIQ_API_URL=https://api.nomadiq.app
// Si no se pasa nada, se usa la dirección de desarrollo: 10.0.2.2 es "el PC"
// visto desde el emulador de Android (donde docker compose sirve la puerta de entrada "edge", puerto 8080).
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

abstract final class AppConfig {
  /// La versión que se enseña en Ajustes. Debe coincidir con "version" de
  /// pubspec.yaml (la parte antes del +).
  static const String version = '1.0.0';

  static const String _apiUrl = String.fromEnvironment(
    'NOMADIQ_API_URL',
    defaultValue: 'http://10.0.2.2:8080',
  );

  /// Dirección base del backend: la puerta de entrada (Traefik), que reparte
  /// cada petición al servicio que toca.
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

  // Mapas: OpenFreeMap sirve gratis los mapas de OpenStreetMap, sin clave ni
  // registro y sin rastrear a nadie. Con millones de usuarios lo correcto es
  // montar nuestro propio servidor de teselas (es software libre) y cambiar
  // solo estas dos direcciones al compilar.
  static const String _tilesUrl = String.fromEnvironment(
    'NOMADIQ_TILES_URL',
    defaultValue: 'https://tiles.openfreemap.org/planet',
  );
  static const String _glyphsUrl = String.fromEnvironment(
    'NOMADIQ_GLYPHS_URL',
    defaultValue: 'https://tiles.openfreemap.org/fonts/{fontstack}/{range}.pbf',
  );

  /// La "TileJSON" con los datos del mapa (calles, agua, edificios...).
  static Uri get tilesUrl {
    final Uri uri = Uri.parse(_tilesUrl);
    if (uri.scheme != 'https') {
      throw StateError('NOMADIQ_TILES_URL debe ser https://');
    }
    return uri;
  }

  /// Las letras con las que se rotulan los nombres del mapa.
  static String get glyphsUrl {
    if (!_glyphsUrl.startsWith('https://')) {
      throw StateError('NOMADIQ_GLYPHS_URL debe ser https://');
    }
    return _glyphsUrl;
  }

  // Avisos push (Firebase Cloud Messaging, gratis). Los 4 datos salen de la
  // consola de Firebase (ver docs/guia-app-movil.md). No son secretos (van
  // dentro de cualquier app publicada), pero se pasan al compilar para no
  // atar el código a un proyecto concreto:
  //   flutter run --dart-define-from-file=firebase.json
  // Si faltan, la app funciona igual, solo que sin avisos push.
  static const String _fbApiKey = String.fromEnvironment(
    'NOMADIQ_FIREBASE_API_KEY',
  );
  static const String _fbAppId = String.fromEnvironment(
    'NOMADIQ_FIREBASE_APP_ID',
  );
  static const String _fbSenderId = String.fromEnvironment(
    'NOMADIQ_FIREBASE_SENDER_ID',
  );
  static const String _fbProjectId = String.fromEnvironment(
    'NOMADIQ_FIREBASE_PROJECT_ID',
  );

  /// null = avisos push desactivados en esta compilación.
  static FirebaseOptions? get firebase {
    if (_fbApiKey.isEmpty ||
        _fbAppId.isEmpty ||
        _fbSenderId.isEmpty ||
        _fbProjectId.isEmpty) {
      return null;
    }
    return const FirebaseOptions(
      apiKey: _fbApiKey,
      appId: _fbAppId,
      messagingSenderId: _fbSenderId,
      projectId: _fbProjectId,
    );
  }
}
