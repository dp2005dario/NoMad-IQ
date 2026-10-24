// "No se pueden hacer capturas de pantalla aquí": mientras la Bóveda está a
// la vista, Android marca la ventana como segura (FLAG_SECURE). Así sus
// documentos no salen en capturas, grabaciones de pantalla ni en la vista
// de apps recientes. El código nativo está en MainActivity.kt.
import 'package:flutter/services.dart';

class SecureWindow {
  const SecureWindow._();

  static const MethodChannel _channel = MethodChannel('nomadiq/secure_window');

  static Future<void> set({required bool secure}) async {
    try {
      await _channel.invokeMethod<void>('setSecure', secure);
    } on MissingPluginException {
      // En los tests (y en otras plataformas) no hay código nativo.
    } on PlatformException {
      // Si falla, la Bóveda sigue funcionando; solo se pierde esta capa extra.
    }
  }
}
