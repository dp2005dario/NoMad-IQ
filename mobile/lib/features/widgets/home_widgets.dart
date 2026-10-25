// Hablar con los widgets del escritorio (paquete home_widget) y con el aviso
// "en directo" del día del vuelo. Detrás de interfaces para poder probar la
// app sin un Android de verdad.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:home_widget/home_widget.dart';
import 'package:timezone/timezone.dart' as tz;

import '../push/notices.dart';
import 'widget_snapshots.dart';

/// Los tres widgets y su clase en Android (NomadWidgets.kt).
enum HomeWidgetKind {
  flight('com.nomadiq.app.FlightWidget'),
  deal('com.nomadiq.app.DealWidget'),
  budget('com.nomadiq.app.BudgetWidget');

  const HomeWidgetKind(this.androidClass);

  final String androidClass;
}

abstract interface class HomeWidgets {
  /// Deja preparadas las fotos fijas de un widget y lo redibuja.
  /// [empty] = la frase cuando no hay nada ("Añade tu vuelo en NomadIQ").
  Future<void> publish(
    HomeWidgetKind kind,
    List<WidgetSnapshot> snapshots, {
    required String empty,
  });

  /// "Borrar mi cuenta": los widgets se quedan vacíos.
  Future<void> clear();

  /// ¿El escritorio deja añadir un widget desde la app (Android 8+)?
  Future<bool> canPin();

  /// Abre la ventanita de Android "¿Añadir este widget al escritorio?".
  Future<void> pin(HomeWidgetKind kind);
}

class DeviceHomeWidgets implements HomeWidgets {
  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> publish(
    HomeWidgetKind kind,
    List<WidgetSnapshot> snapshots, {
    required String empty,
  }) async {
    if (!_android) return;
    try {
      await HomeWidget.saveWidgetData<String>(
        kind.name,
        jsonEncode(<Object?>[
          for (final WidgetSnapshot s in snapshots) s.toJson(),
        ]),
      );
      await HomeWidget.saveWidgetData<String>('${kind.name}_empty', empty);
      await HomeWidget.updateWidget(qualifiedAndroidName: kind.androidClass);
      // Android despierta al widget cuando cambia la foto fija. Una sola
      // alarma armada cada vez (la siguiente), así que no gasta batería.
      final DateTime now = DateTime.now();
      await HomeWidget.scheduleWidgetUpdates(<DateTime>[
        for (final WidgetSnapshot s in snapshots)
          if (s.at.isAfter(now)) s.at,
      ], qualifiedAndroidName: kind.androidClass);
    } on PlatformException {
      // Sin widgets en este móvil: no pasa nada.
    } on MissingPluginException {
      // Igual.
    }
  }

  @override
  Future<void> clear() async {
    for (final HomeWidgetKind k in HomeWidgetKind.values) {
      await publish(k, const <WidgetSnapshot>[], empty: '');
    }
  }

  @override
  Future<bool> canPin() async {
    if (!_android) return false;
    try {
      return await HomeWidget.isRequestPinWidgetSupported() ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> pin(HomeWidgetKind kind) async {
    try {
      await HomeWidget.requestPinWidget(
        qualifiedAndroidName: kind.androidClass,
      );
    } on PlatformException {
      // El escritorio dijo que no: la pantalla explica cómo hacerlo a mano.
    }
  }
}

/// En las pruebas: guarda lo publicado.
class MemoryHomeWidgets implements HomeWidgets {
  final Map<HomeWidgetKind, List<WidgetSnapshot>> data =
      <HomeWidgetKind, List<WidgetSnapshot>>{};
  final List<HomeWidgetKind> pinned = <HomeWidgetKind>[];
  bool pinSupported = true;

  @override
  Future<void> publish(
    HomeWidgetKind kind,
    List<WidgetSnapshot> snapshots, {
    required String empty,
  }) async => data[kind] = snapshots;

  @override
  Future<void> clear() async => data.clear();

  @override
  Future<bool> canPin() async => pinSupported;

  @override
  Future<void> pin(HomeWidgetKind kind) async => pinned.add(kind);
}

/// Un paso del aviso "en directo": a [at] aparece con este texto y se va solo
/// a los [lasts] (cuando le toca al siguiente).
class LiveStep {
  const LiveStep({
    required this.at,
    required this.title,
    required this.body,
    required this.lasts,
    this.quiet = false,
  });

  final DateTime at;
  final String title;
  final String body;
  final Duration lasts;

  /// true = sin sonido ni vibración (el paso "en vuelo").
  final bool quiet;
}

abstract interface class LiveFlight {
  /// Programa los pasos (y quita los que hubiera de antes).
  Future<void> schedule(List<LiveStep> steps, {required String channelName});

  Future<void> cancel();
}

/// El aviso se programa EN EL MÓVIL con alarmas de Android: llega aunque no
/// haya Internet (modo avión) y sin servidor. Un reloj Wear OS emparejado lo
/// enseña también, porque Android pasa los avisos al reloj solo.
class DeviceLiveFlight implements LiveFlight {
  static const String channel = 'live_flight';
  static const int firstId = 7300;
  static const int maxSteps = 6;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  @override
  Future<void> schedule(
    List<LiveStep> steps, {
    required String channelName,
  }) async {
    await cancel();
    if (defaultTargetPlatform != TargetPlatform.android) return;
    await DeviceNotices.instance.init();
    final DateTime now = DateTime.now();
    int id = firstId;
    for (final LiveStep s in steps.take(maxSteps)) {
      final int myId = id++;
      if (!s.at.isAfter(now)) continue;
      try {
        await _plugin.zonedSchedule(
          id: myId,
          scheduledDate: tz.TZDateTime.from(s.at, tz.UTC),
          title: s.title,
          body: s.body,
          payload: '/widgets',
          // Sin alarmas exactas: unos minutos de margen y ningún permiso extra.
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          notificationDetails: NotificationDetails(
            android: AndroidNotificationDetails(
              channel,
              channelName,
              // No se puede quitar deslizando, pero se va sola al siguiente.
              ongoing: true,
              onlyAlertOnce: true,
              silent: s.quiet,
              timeoutAfter: s.lasts.inMilliseconds,
              category: AndroidNotificationCategory.status,
            ),
          ),
        );
      } on PlatformException {
        // Si Android no deja programar, la app sigue igual (sin aviso).
      }
    }
  }

  @override
  Future<void> cancel() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      for (int i = 0; i < maxSteps; i++) {
        await _plugin.cancel(id: firstId + i);
      }
    } on PlatformException {
      // Nada que quitar.
    }
  }
}

class MemoryLiveFlight implements LiveFlight {
  List<LiveStep> steps = <LiveStep>[];

  @override
  Future<void> schedule(
    List<LiveStep> steps, {
    required String channelName,
  }) async => this.steps = steps;

  @override
  Future<void> cancel() async => steps = <LiveStep>[];
}
