// La conexión con Firebase Cloud Messaging (FCM): el "cartero" de Google que
// despierta al móvil cuando el notifier tiene un aviso para él.
//
// Firebase solo ve un sobre cerrado ({"v":"1","p":"<cifrado>"}); el texto
// lo escribe el propio móvil (ver notices.dart).
//
// Ojo: con la app CERRADA, Android arranca un "mini motor" de Flutter aparte
// solo para [pushBackgroundHandler]. Ahí no hay pantallas ni sesión: solo se
// abre el aviso con la clave guardada y se enseña. A propósito NO se renueva
// ningún pase desde ahí: el pase largo es de un solo uso y dos motores
// renovando a la vez cerrarían la sesión.
import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';

import '../../core/config.dart';
import 'notices.dart';
import 'push_notice.dart';
import 'push_registrar.dart';
import 'push_state.dart';

class FirebasePushTransport implements PushTransport {
  const FirebasePushTransport();

  @override
  Future<String?> token() => FirebaseMessaging.instance.getToken();

  @override
  Stream<String> get tokenRefresh => FirebaseMessaging.instance.onTokenRefresh;

  @override
  Future<void> deleteToken() => FirebaseMessaging.instance.deleteToken();
}

/// Arranca Firebase y los avisos. Devuelve false si esta compilación no
/// trae los datos de Firebase o si falla (la app sigue sin avisos push).
Future<bool> startFirebasePush() async {
  final FirebaseOptions? options = AppConfig.firebase;
  if (options == null) return false;
  try {
    await Firebase.initializeApp(options: options);
    FirebaseMessaging.onBackgroundMessage(pushBackgroundHandler);
    // Con la app abierta, el aviso llega aquí (y se enseña igual).
    FirebaseMessaging.onMessage.listen(
      (RemoteMessage m) => unawaited(showPush(m.data, SecurePushStateStore())),
    );
    return true;
  } on Object catch (e) {
    debugPrint('Avisos push desactivados: $e');
    return false;
  }
}

/// Lo que se ejecuta cuando llega un aviso con la app cerrada o en segundo
/// plano. "vm:entry-point" evita que el compilador lo borre por no verlo usado.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  final FirebaseOptions? options = AppConfig.firebase;
  if (options == null) return;
  await Firebase.initializeApp(options: options);
  await showPush(message.data, SecurePushStateStore());
}

/// Abre el aviso con las claves guardadas y, si es para nosotros, lo enseña.
Future<void> showPush(Map<String, dynamic> data, PushStateStore store) async {
  final PushState? state = await store.read();
  if (state == null) return; // sin sesión: no hay claves, no se abre nada
  final PushNotice? notice = await PushNotice.open(
    Map<String, Object?>.from(data),
    state,
  );
  if (notice == null) return;
  await DeviceNotices.instance.show(notice, localizationsFor(notice.language));
}
