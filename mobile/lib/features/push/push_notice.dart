// Qué dice un aviso push, una vez abierto (descifrado).
//
// Al móvil llega por Firebase algo así: {"v": "1", "p": "<aviso cifrado>"}.
// Dentro, cifrado SOLO para este teléfono, va un JSON pequeño:
//   {"v":1, "type":"zone_audioguide", "zone_id":"...", "zone_kind":"...",
//    "lang":"es", "at":"2026-10-23T10:00:00Z"}
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
}

class PushNotice {
  const PushNotice({
    required this.kind,
    required this.zoneId,
    required this.language,
    required this.at,
  });

  final PushKind kind;
  final String zoneId;

  /// Idioma con el que el móvil mandó las posiciones (puede venir vacío).
  final String language;
  final DateTime at;

  /// Los avisos de seguridad van por su propio canal (más llamativo).
  bool get urgent => kind == PushKind.zoneSafety;

  /// Mismo número para el mismo aviso: si llega dos veces, se sustituye en
  /// lugar de salir repetido.
  int get notificationId => Object.hash(kind, zoneId) & 0x7fffffff;

  /// A qué pantalla lleva tocar el aviso.
  String get route => switch (kind) {
    // El nombre de la zona no viaja en el aviso: la audioguía lo pide luego.
    PushKind.zoneAudioguide => Routes.audioguide(zoneId, ''),
    PushKind.airportArrival => Routes.soon(Feature.transport),
    PushKind.zoneSafety => Routes.map,
  };

  /// Un aviso antiguo (el móvil estuvo apagado) ya no sirve de nada.
  static const Duration maxAge = Duration(hours: 1);

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
      _ => null,
    };
    final Object? zoneId = json['zone_id'];
    final Object? at = json['at'];
    final Object? lang = json['lang'];
    if (kind == null || zoneId is! String || !_uuid.hasMatch(zoneId)) {
      return null;
    }
    final DateTime? when = at is String ? DateTime.tryParse(at) : null;
    if (when == null) return null;
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
        if (current.difference(notice.at) > maxAge) return null;
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
