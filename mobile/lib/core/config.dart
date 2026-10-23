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
}
