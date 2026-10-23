// Qué dice un aviso push, una vez abierto (descifrado).
//
// Al móvil llega por Firebase algo así: {"v": "1", "p": "<aviso cifrado>"}.
// Dentro, cifrado SOLO para este teléfono, va un JSON pequeño:
//   {"v":1, "type":"zone_audioguide", "zone_id":"...", "zone_kind":"...",
//    "lang":"es", "at":"2026-10-23T10:00:00Z"}
// o, para una alerta de precio de un vuelo que vigilas:
//   {"v":1, "type":"fare_alert", "alert_id":"...", "alert_type":"error_fare",
//    "origin":"MAD", "destination":"NRT", "departure":"2027-03-15",
//    "cabin":"ECONOMY", "price":{"amount_minor":31500,"currency":"EUR"},
//    "drop_bp":6500, "at":"..."}
// El servidor NO manda textos: el móvil escribe el aviso en tu idioma. Así
// Google (que transporta el aviso) no sabe ni siquiera de qué trata.
import 'dart:convert';
import 'dart:typed_data';

import '../../core/router.dart';
import '../coming_soon/coming_soon_screen.dart' show Feature;
import 'hpke.dart';
import 'push_state.dart';

/// Los tipos de aviso que conoce esta versión de la app.
enum PushKind {
  zoneAudioguide, // "Estás en X: ¿escuchas la audioguía?"
  airportArrival, // "Bienvenido": transporte, eSIM...
  zoneSafety, // aviso de seguridad (urgente)
  fareAlert, // un vuelo que vigilas ha bajado de precio
}

/// Por qué salta una alerta de precio.
enum FareAlertKind {
  priceDrop, // ha bajado bastante respecto a lo habitual
  errorFare, // tan barato que parece un error de la aerolínea
  targetReached, // ha llegado al precio que pusiste
}

/// Los datos de una alerta de precio (solo en los avisos [PushKind.fareAlert]).
class FareNotice {
  const FareNotice({
    required this.alertId,
    required this.kind,
    required this.origin,
    required this.destination,
    required this.departure,
    required this.amountMinor,
    required this.currency,
    required this.dropBasisPoints,
  });

  final String alertId;
  final FareAlertKind kind;

  /// Códigos IATA de aeropuerto, como "MAD" o "NRT".
  final String origin;
  final String destination;

  /// Día del vuelo (sin hora).
  final DateTime departure;

  /// Precio en céntimos (o la unidad mínima de la divisa): 31500 EUR = 315 €.
  final int amountMinor;
  final String currency;

  /// Cuánto ha bajado, en puntos básicos: 6500 = 65 %.
  final int dropBasisPoints;

  static final RegExp _iata = RegExp(r'^[A-Z]{3}$');

  static FareNotice? fromJson(Map<String, Object?> json) {
    final FareAlertKind? kind = switch (json['alert_type']) {
      'price_drop' => FareAlertKind.priceDrop,
      'error_fare' => FareAlertKind.errorFare,
      'target_reached' => FareAlertKind.targetReached,
      _ => null,
    };
    final Object? id = json['alert_id'];
    final Object? origin = json['origin'];
    final Object? destination = json['destination'];
    final Object? departure = json['departure'];
    final Object? price = json['price'];
    final Object? drop = json['drop_bp'];
    if (kind == null ||
        id is! String ||
        !PushNotice._uuid.hasMatch(id) ||
        origin is! String ||
        !_iata.hasMatch(origin) ||
        destination is! String ||
        !_iata.hasMatch(destination) ||
        departure is! String ||
        price is! Map<String, Object?> ||
        drop is! int ||
        drop < 0 ||
        drop > 10000) {
      return null;
    }
    // Solo "AAAA-MM-DD": nada de horas ni zonas horarias.
    final DateTime? day = departure.length == 10
        ? DateTime.tryParse(departure)
        : null;
    final Object? amount = price['amount_minor'];
    final Object? currency = price['currency'];
    if (day == null ||
        amount is! int ||
        amount <= 0 ||
        currency is! String ||
        // ISO 4217 ("EUR"): también son 3 mayúsculas.
        !_iata.hasMatch(currency)) {
      return null;
    }
    return FareNotice(
      alertId: id,
      kind: kind,
      origin: origin,
      destination: destination,
      departure: day,
      amountMinor: amount,
      currency: currency,
      dropBasisPoints: drop,
    );
  }
}

class PushNotice {
  const PushNotice({
    required this.kind,
    required this.zoneId,
    required this.language,
    required this.at,
    this.fare,
  });

  final PushKind kind;

  /// La zona del aviso ('' en las alertas de precio).
  final String zoneId;

  /// Solo en las alertas de precio.
  final FareNotice? fare;

  /// Idioma con el que el móvil mandó las posiciones (puede venir vacío).
  final String language;
  final DateTime at;

  /// Los avisos de seguridad van por su propio canal (más llamativo).
  bool get urgent => kind == PushKind.zoneSafety;

  /// Mismo número para el mismo aviso: si llega dos veces, se sustituye en
  /// lugar de salir repetido.
  int get notificationId =>
      Object.hash(kind, fare?.alertId ?? zoneId) & 0x7fffffff;

  /// A qué pantalla lleva tocar el aviso.
  String get route => switch (kind) {
    // El nombre de la zona no viaja en el aviso: la audioguía lo pide luego.
    PushKind.zoneAudioguide => Routes.audioguide(zoneId, ''),
    PushKind.airportArrival => Routes.soon(Feature.transport),
    PushKind.zoneSafety => Routes.map,
    // La lista de tus alertas de precio (con el botón de reservar).
    PushKind.fareAlert => Routes.fareAlerts,
  };

  /// Un aviso antiguo (el móvil estuvo apagado) ya no sirve de nada.
  static const Duration maxAge = Duration(hours: 1);

  /// Las alertas de precio aguantan más: una tarifa error sigue valiendo la
  /// pena unas horas después (el servidor también las guarda 6 h).
  static const Duration fareMaxAge = Duration(hours: 6);

  Duration get _maxAge => kind == PushKind.fareAlert ? fareMaxAge : maxAge;

  static final RegExp _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  /// Lee el JSON ya descifrado. Devuelve null si no lo entendemos (un tipo
  /// nuevo que esta versión aún no conoce, o datos raros): mejor no avisar
  /// que avisar mal.
  static PushNotice? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    if (json['v'] != 1) return null;
    final PushKind? kind = switch (json['type']) {
      'zone_audioguide' => PushKind.zoneAudioguide,
      'airport_arrival' => PushKind.airportArrival,
      'zone_safety' => PushKind.zoneSafety,
      'fare_alert' => PushKind.fareAlert,
      _ => null,
    };
    final Object? at = json['at'];
    final DateTime? when = at is String ? DateTime.tryParse(at) : null;
    if (kind == null || when == null) return null;
    if (kind == PushKind.fareAlert) {
      final FareNotice? fare = FareNotice.fromJson(json);
      if (fare == null) return null;
      return PushNotice(
        kind: kind,
        zoneId: '',
        language: '',
        at: when,
        fare: fare,
      );
    }
    final Object? zoneId = json['zone_id'];
    final Object? lang = json['lang'];
    if (zoneId is! String || !_uuid.hasMatch(zoneId)) return null;
    return PushNotice(
      kind: kind,
      zoneId: zoneId,
      language: lang is String && lang.length <= 12 ? lang : '',
      at: when,
    );
  }

  /// Abre los datos que llegan de Firebase con las claves del móvil. Prueba
  /// la clave actual y la anterior (un aviso cifrado justo antes de cambiar
  /// de clave aún debe abrirse). null = no es para nosotros o no se entiende.
  static Future<PushNotice?> open(
    Map<String, Object?> data,
    PushState state, {
    DateTime? now,
  }) async {
    if (data['v'] != '1') return null;
    final Object? p = data['p'];
    if (p is! String || p.length > 4096) return null;
    final Uint8List envelope;
    try {
      envelope = base64Url.decode(base64Url.normalize(p));
    } on FormatException {
      return null;
    }
    final Uint8List aad = ascii.encode(state.deviceId);
    for (final Uint8List key in <Uint8List>[
      state.currentKey,
      ?state.previousKey,
    ]) {
      try {
        final Uint8List clear = await hpkeOpen(
          privateKey: key,
          envelope: envelope,
          aad: aad,
        );
        final PushNotice? notice = fromJson(jsonDecode(utf8.decode(clear)));
        if (notice == null) return null;
        final DateTime current = now ?? DateTime.now();
        if (current.difference(notice.at) > notice._maxAge) return null;
        return notice;
      } on HpkeOpenError {
        continue; // probamos la otra clave
      } on FormatException {
        return null;
      }
    }
    return null;
  }
}
