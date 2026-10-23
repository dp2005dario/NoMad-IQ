// Lo que el móvil recuerda para recibir avisos push:
//   - su "número de móvil" para el notifier (device_id, un UUID al azar);
//   - su clave privada actual y la anterior (para abrir avisos cifrados);
//   - el token de Firebase con el que se registró y cuándo.
//
// Se guarda en el almacén cifrado del teléfono (flutter_secure_storage, con
// la clave en el chip de seguridad). La clave privada NUNCA sale del móvil.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class PushState {
  const PushState({
    required this.deviceId,
    required this.currentKey,
    required this.keyCreatedAt,
    this.previousKey,
    this.confirmed = false,
    this.token,
    this.registeredAt,
  });

  final String deviceId;
  final Uint8List currentKey;
  final DateTime keyCreatedAt;

  /// La clave de antes del último cambio: un aviso que ya venía de camino
  /// cifrado con ella se puede seguir abriendo.
  final Uint8List? previousKey;

  /// El servidor ya conoce la clave actual (respondió "guardado").
  final bool confirmed;

  /// Token de Firebase con el que se registró (si cambia, hay que repetir).
  final String? token;
  final DateTime? registeredAt;

  PushState copyWith({
    String? deviceId,
    Uint8List? currentKey,
    DateTime? keyCreatedAt,
    Uint8List? previousKey,
    bool? confirmed,
    String? token,
    DateTime? registeredAt,
  }) => PushState(
    deviceId: deviceId ?? this.deviceId,
    currentKey: currentKey ?? this.currentKey,
    keyCreatedAt: keyCreatedAt ?? this.keyCreatedAt,
    previousKey: previousKey ?? this.previousKey,
    confirmed: confirmed ?? this.confirmed,
    token: token ?? this.token,
    registeredAt: registeredAt ?? this.registeredAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'device_id': deviceId,
    'key': base64Url.encode(currentKey),
    'key_at': keyCreatedAt.toUtc().toIso8601String(),
    if (previousKey != null) 'prev': base64Url.encode(previousKey!),
    'confirmed': confirmed,
    if (token != null) 'token': token,
    if (registeredAt != null)
      'registered_at': registeredAt!.toUtc().toIso8601String(),
  };

  /// Si lo guardado está roto (otra versión, almacén dañado...), null: se
  /// empieza de cero y se registra otra vez. Nunca rompe la app.
  static PushState? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    try {
      final String deviceId = json['device_id']! as String;
      final Uint8List key = base64Url.decode(json['key']! as String);
      if (key.length != 32) return null;
      final String? prev = json['prev'] as String?;
      final Uint8List? previous = prev == null ? null : base64Url.decode(prev);
      final String? registered = json['registered_at'] as String?;
      return PushState(
        deviceId: deviceId,
        currentKey: key,
        keyCreatedAt: DateTime.parse(json['key_at']! as String),
        previousKey: previous != null && previous.length == 32
            ? previous
            : null,
        confirmed: json['confirmed'] == true,
        token: json['token'] as String?,
        registeredAt: registered == null ? null : DateTime.parse(registered),
      );
    } on Object {
      return null;
    }
  }
}

abstract interface class PushStateStore {
  Future<PushState?> read();
  Future<void> write(PushState state);
  Future<void> clear();
}

final class SecurePushStateStore implements PushStateStore {
  SecurePushStateStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Igual que el pase largo (ver auth/token_store.dart): si la clave
            // del chip falla, se borra y se registra de nuevo.
            aOptions: AndroidOptions(resetOnError: true),
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const String _key = 'push_state';
  final FlutterSecureStorage _storage;

  @override
  Future<PushState?> read() async {
    final String? raw = await _storage.read(key: _key);
    if (raw == null) return null;
    try {
      return PushState.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(PushState state) =>
      _storage.write(key: _key, value: jsonEncode(state.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Para los tests: en memoria.
final class MemoryPushStateStore implements PushStateStore {
  PushState? state;

  @override
  Future<PushState?> read() async => state;

  @override
  Future<void> write(PushState value) async => state = value;

  @override
  Future<void> clear() async => state = null;
}
