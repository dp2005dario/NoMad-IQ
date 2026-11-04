// Las notificaciones que ve el usuario en la barra del móvil.
//
// El aviso push llega cifrado y SIN texto; aquí se escribe en el idioma del
// usuario y se enseña con flutter_local_notifications. Tocarlo abre la
// pantalla que toca (la audioguía de esa zona, el mapa...).
//
// Hay tres "canales" (Android deja al usuario silenciar cada uno aparte):
//   - zones:  audioguías y llegadas (importancia normal);
//   - safety: avisos de seguridad (importancia alta: suenan y asoman arriba);
//   - fares:  alertas de precio de vuelos que vigilas (importancia alta: un
//             chollo puede durar minutos).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:intl/date_symbol_data_local.dart' show initializeDateFormatting;
import 'package:intl/intl.dart' show DateFormat;

import '../../core/money.dart';
import '../../l10n/generated/app_localizations.dart';
import 'push_notice.dart';

/// Lo que la app necesita de las notificaciones (en los tests, una falsa).
abstract interface class NoticeCenter {
  /// Pide permiso para enseñar notificaciones (Android 13+). true = concedido.
  Future<bool> requestPermission();

  /// Rutas de las notificaciones que el usuario toca con la app abierta.
  Stream<String> get taps;

  /// Si la app se abrió tocando una notificación, su ruta.
  Future<String?> launchRoute();

  /// Una notificación de Flyra con datos para pegar en otra app (el importe
  /// y el concepto de un Bizum). Cada botón [copies] (texto del botón, lo que
  /// copia) los copia uno a uno.
  Future<void> showCopyData({
    required String title,
    required String body,
    required List<(String, String)> copies,
  });
}

/// Elige los textos para el idioma [language]; si no lo tenemos, el del
/// móvil; y si tampoco, inglés.
AppLocalizations localizationsFor(String language) {
  final Set<String> codes = AppLocalizations.supportedLocales
      .map((Locale l) => l.languageCode)
      .toSet();
  final String system = PlatformDispatcher.instance.locale.languageCode;
  final String code = codes.contains(language)
      ? language
      : codes.contains(system)
      ? system
      : 'en';
  return lookupAppLocalizations(Locale(code));
}

class DeviceNotices implements NoticeCenter {
  DeviceNotices._();

  /// Una sola por proceso (la usan la app y el aviso en segundo plano).
  static final DeviceNotices instance = DeviceNotices._();

  static const String zonesChannel = 'zones';
  static const String safetyChannel = 'safety';
  static const String faresChannel = 'fares';
  static const String groupChannel = 'group';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final StreamController<String> _taps = StreamController<String>.broadcast();
  bool _ready = false;

  @override
  Stream<String> get taps => _taps.stream;

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    await _plugin.initialize(
      settings: const InitializationSettings(
        // Icono pequeño de la barra (de momento, el de la app).
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          // El permiso lo pedimos nosotros cuando toca, no al arrancar.
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (NotificationResponse r) {
        // Botón "Copiar importe" / "Copiar concepto" de los datos de Bizum.
        final String? copy = copyFromResponse(r.payload, r.actionId);
        if (copy != null) {
          unawaited(Clipboard.setData(ClipboardData(text: copy)));
          return;
        }
        final String? route = _safeRoute(r.payload);
        if (route != null) _taps.add(route);
      },
    );
  }

  @override
  Future<bool> requestPermission() async {
    await init();
    if (defaultTargetPlatform == TargetPlatform.android) {
      final AndroidFlutterLocalNotificationsPlugin? android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      // En Android 12 o menos no hay pregunta: ya está concedido.
      return await android?.requestNotificationsPermission() ?? true;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final IOSFlutterLocalNotificationsPlugin? ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      return await ios?.requestPermissions(alert: true, sound: true) ?? false;
    }
    return true;
  }

  @override
  Future<String?> launchRoute() async {
    await init();
    final NotificationAppLaunchDetails? details = await _plugin
        .getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return _safeRoute(details.notificationResponse?.payload);
  }

  /// Enseña el aviso con el texto en el idioma [t].
  Future<void> show(PushNotice notice, AppLocalizations t) async {
    await init();
    final (String title, String body) = await noticeTexts(notice, t);
    final bool fare = notice.kind == PushKind.fareAlert;
    final bool urgent = notice.urgent || fare;
    final (String channel, String channelName) = fare
        ? (faresChannel, t.pushChannelFares)
        : notice.isGroup
        ? (groupChannel, t.pushChannelGroup)
        : urgent
        ? (safetyChannel, t.pushChannelSafety)
        : (zonesChannel, t.pushChannelZones);
    await _plugin.show(
      id: notice.notificationId,
      title: title,
      body: body,
      payload: notice.route,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel,
          // El nombre del canal se ve en Ajustes > Notificaciones: traducido.
          channelName,
          importance: urgent ? Importance.high : Importance.defaultImportance,
          priority: urgent ? Priority.high : Priority.defaultPriority,
          category: fare
              ? AndroidNotificationCategory.promo
              : urgent
              ? AndroidNotificationCategory.status
              : AndroidNotificationCategory.recommendation,
          // En la pantalla de bloqueo no se enseña el texto, solo "ECLIPTA".
          visibility: NotificationVisibility.private,
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  static const String payChannel = 'pay';
  static const int _payId = 7301;

  @override
  Future<void> showCopyData({
    required String title,
    required String body,
    required List<(String, String)> copies,
  }) async {
    await init();
    await _plugin.show(
      id: _payId,
      title: title,
      body: body,
      // Lo que copia cada botón va en el "payload" (nunca sale del móvil).
      payload:
          '$copyPrefix${jsonEncode(<String>[for (final (_, String v) in copies) v])}',
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          payChannel,
          title,
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
          actions: <AndroidNotificationAction>[
            for (int i = 0; i < copies.length; i++)
              AndroidNotificationAction(
                'copy_$i',
                copies[i].$1,
                // Hay que abrir la app un momento para poder copiar.
                showsUserInterface: true,
                cancelNotification: false,
              ),
          ],
        ),
        iOS: const DarwinNotificationDetails(),
      ),
    );
  }

  /// Solo rutas internas de la app ("/..."): nada de direcciones externas.
  static String? _safeRoute(String? payload) =>
      payload != null && payload.startsWith('/') && !payload.startsWith('//')
      ? payload
      : null;
}

/// Así empieza el "payload" de la notificación con datos para copiar.
const String copyPrefix = 'copy:';

/// Qué copiar al tocar la notificación de datos: el botón `copy_N` copia el
/// dato N; tocar la notificación entera, el primero. null = no es de datos.
String? copyFromResponse(String? payload, String? actionId) {
  if (payload == null || !payload.startsWith(copyPrefix)) return null;
  try {
    final Object? decoded = jsonDecode(payload.substring(copyPrefix.length));
    if (decoded is! List<dynamic>) return null;
    final List<dynamic> values = decoded;
    final int i = actionId != null && actionId.startsWith('copy_')
        ? int.tryParse(actionId.substring(5)) ?? 0
        : 0;
    return i >= 0 && i < values.length ? '${values[i]}' : null;
  } on FormatException {
    return null;
  }
}

/// Título y texto de un aviso en el idioma [t].
Future<(String, String)> noticeTexts(
  PushNotice notice,
  AppLocalizations t,
) async {
  final FareNotice? fare = notice.fare;
  if (notice.kind != PushKind.fareAlert || fare == null) {
    return switch (notice.kind) {
      PushKind.zoneAudioguide => (t.pushGuideTitle, t.pushGuideBody),
      PushKind.airportArrival => (t.pushAirportTitle, t.pushAirportBody),
      PushKind.groupChat => (t.pushGroupChatTitle, t.pushGroupChatBody),
      PushKind.groupResult => (t.pushGroupResultTitle, t.pushGroupResultBody),
      PushKind.zoneSafety ||
      PushKind.fareAlert => (t.pushSafetyTitle, t.pushSafetyBody),
    };
  }
  final String locale = t.localeName;
  // Los nombres de los meses de cada idioma (en segundo plano no están
  // cargados todavía).
  await initializeDateFormatting(locale);
  final String date = DateFormat.MMMd(locale).format(fare.departure);
  final String price = formatMoney(
    fare.amountMinor,
    fare.currency,
    locale,
    compact: true,
  );
  final String title = switch (fare.kind) {
    FareAlertKind.priceDrop => t.pushFareDropTitle,
    FareAlertKind.errorFare => t.pushFareErrorTitle,
    FareAlertKind.targetReached => t.pushFareTargetTitle,
  };
  // Bajadas de menos de un 1 % no se anuncian como "−0 %".
  final int percent = fare.dropBasisPoints ~/ 100;
  final String body = percent >= 1
      ? t.pushFareBodyDrop(
          fare.origin,
          fare.destination,
          date,
          price,
          '$percent',
        )
      : t.pushFareBody(fare.origin, fare.destination, date, price);
  return (title, body);
}

/// Sin notificaciones (los tests, o plataformas sin ellas): todo "permitido"
/// y nunca se toca nada.
class SilentNotices implements NoticeCenter {
  const SilentNotices();

  @override
  Future<bool> requestPermission() async => true;

  @override
  Stream<String> get taps => const Stream<String>.empty();

  @override
  Future<String?> launchRoute() async => null;

  @override
  Future<void> showCopyData({
    required String title,
    required String body,
    required List<(String, String)> copies,
  }) async {}
}
