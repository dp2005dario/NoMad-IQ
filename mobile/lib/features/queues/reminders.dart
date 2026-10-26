// "Recuérdamelo": un aviso del propio móvil a la hora que tú eliges (por
// ejemplo, 10 minutos antes de la hora con menos cola).
//
// OJO: NO es un turno de verdad en ninguna cola (la maqueta decía "coger
// turno virtual", pero eso solo existe si el sitio lo ofrece en su web).
// Es solo un despertador del móvil, sin servidor y sin Internet.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../push/notices.dart';

abstract interface class Reminders {
  /// Programa (o cambia) el aviso [id] para [at].
  Future<void> schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String channelName,
    String? route,
  });

  Future<void> cancel(int id);
}

class DeviceReminders implements Reminders {
  static const String channel = 'reminders';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  @override
  Future<void> schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String channelName,
    String? route,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await DeviceNotices.instance.init();
    try {
      await _plugin.zonedSchedule(
        id: id,
        scheduledDate: tz.TZDateTime.from(at, tz.UTC),
        title: title,
        body: body,
        payload: route,
        // Sin alarmas exactas: unos minutos de margen y ningún permiso extra.
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(channel, channelName),
        ),
      );
    } on PlatformException {
      // Si Android no deja programar, no pasa nada (sin aviso).
    }
  }

  @override
  Future<void> cancel(int id) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _plugin.cancel(id: id);
    } on PlatformException {
      // Nada que quitar.
    }
  }
}

/// Para las pruebas: apunta los avisos en una lista.
class MemoryReminders implements Reminders {
  final Map<int, (DateTime, String)> scheduled = <int, (DateTime, String)>{};

  @override
  Future<void> schedule({
    required int id,
    required DateTime at,
    required String title,
    required String body,
    required String channelName,
    String? route,
  }) async => scheduled[id] = (at, body);

  @override
  Future<void> cancel(int id) async => scheduled.remove(id);
}
