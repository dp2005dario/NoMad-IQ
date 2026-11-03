// Los avisos de los eventos guardados (el corazón de "Qué pasa en tus
// fechas"): Flyra te avisa la víspera y 2 horas antes.
//
// Se programan EN EL MÓVIL con alarmas de Android (como el aviso del vuelo
// en directo): llegan aunque no haya Internet y sin servidor.
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../push/notices.dart';

/// Un aviso: cuándo (hora absoluta), el título y el texto.
class EventReminder {
  const EventReminder({
    required this.at,
    required this.title,
    required this.body,
  });

  final DateTime at;
  final String title;
  final String body;
}

abstract interface class EventReminders {
  /// Programa los avisos de un evento (y quita los que tuviera de antes).
  Future<void> schedule(String eventId, List<EventReminder> reminders);

  /// Quita los avisos de un evento (al quitarle el corazón).
  Future<void> cancel(String eventId);
}

/// El número de cada aviso: sale del id del evento, siempre el mismo (así
/// se puede quitar después). Dos por evento: víspera y 2 horas antes.
int reminderId(String eventId, int i) {
  int h = 0;
  for (final int c in eventId.codeUnits) {
    h = (h * 31 + c) & 0x3FFFFF;
  }
  // Entre 8 000 000 y ~16 000 000: lejos de los demás avisos de la app.
  return 8000000 + h * 2 + i;
}

class DeviceEventReminders implements EventReminders {
  static const String channel = 'events';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  @override
  Future<void> schedule(String eventId, List<EventReminder> reminders) async {
    await cancel(eventId);
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await DeviceNotices.instance.init();
    final DateTime now = DateTime.now();
    for (int i = 0; i < reminders.length && i < 2; i++) {
      final EventReminder r = reminders[i];
      if (!r.at.isAfter(now)) continue;
      try {
        await _plugin.zonedSchedule(
          id: reminderId(eventId, i),
          scheduledDate: tz.TZDateTime.from(r.at.toUtc(), tz.UTC),
          title: r.title,
          body: r.body,
          payload: '/events',
          // Sin alarmas exactas: unos minutos de margen y ningún permiso.
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(channel, 'Eventos'),
          ),
        );
      } on PlatformException {
        // Si Android no deja programar, el evento queda guardado igual.
      }
    }
  }

  @override
  Future<void> cancel(String eventId) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      for (int i = 0; i < 2; i++) {
        await _plugin.cancel(id: reminderId(eventId, i));
      }
    } on PlatformException {
      // Nada que quitar.
    }
  }
}

/// Para las pruebas: solo apunta lo que se programó.
class MemoryEventReminders implements EventReminders {
  final Map<String, List<EventReminder>> scheduled =
      <String, List<EventReminder>>{};

  @override
  Future<void> schedule(String eventId, List<EventReminder> reminders) async =>
      scheduled[eventId] = reminders;

  @override
  Future<void> cancel(String eventId) async => scheduled.remove(eventId);
}
