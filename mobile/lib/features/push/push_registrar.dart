// El "recepcionista" de los avisos: da de alta este móvil en el notifier
// (con su token de Firebase y su clave pública) y lo da de baja al salir.
//
// Reglas, pensadas para millones de móviles:
//   - Solo se vuelve a registrar si algo cambió (token nuevo, clave nueva) o
//     hace más de 7 días: así el servidor no recibe una petición por cada
//     vez que alguien abre la app.
//   - La clave se cambia cada 30 días. La anterior se guarda: un aviso que
//     ya venía de camino con ella se sigue pudiendo abrir.
//   - Si el device_id ya es de otra cuenta (409), se inventa uno nuevo.
//   - Al cerrar sesión: baja en el servidor, se borran las claves y Firebase
//     olvida el token. Un aviso que llegue después ya no se puede abrir.
import 'dart:async';
import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../auth/session.dart';
import '../../core/settings.dart';
import '../../core/api_client.dart';
import 'hpke.dart';
import 'push_state.dart';

/// Lo que hace falta de Firebase (así los tests no necesitan Firebase).
abstract interface class PushTransport {
  /// El token de este móvil, o null si no hay (sin Google Play, sin red...).
  Future<String?> token();

  /// Firebase avisa cuando cambia el token (hay que registrarse otra vez).
  Stream<String> get tokenRefresh;

  /// Olvida el token: los avisos que se manden a él ya no llegarán.
  Future<void> deleteToken();
}

/// Las dos llamadas al notifier (a través de la puerta de entrada).
class DevicesApi {
  const DevicesApi(this._api);

  final ApiClient _api;

  Future<void> register({
    required String deviceId,
    required String fcmToken,
    required List<int> publicKey,
  }) async {
    await _api.putJson('/v1/devices/$deviceId', <String, Object?>{
      'platform': 'android',
      'fcm_token': fcmToken,
      // base64url sin "=" al final, como espera el notifier.
      'public_key': base64Url.encode(publicKey).replaceAll('=', ''),
    });
  }

  Future<void> unregister(String deviceId) async {
    await _api.delete('/v1/devices/$deviceId');
  }
}

class PushRegistrar {
  PushRegistrar({
    required this._devices,
    required this._store,
    required this._transport,
    required this._session,
    this._prefs,
    DateTime Function()? clock,
    String Function()? newDeviceId,
  }) : _now = clock ?? DateTime.now,
       _newDeviceId = newDeviceId ?? const Uuid().v4;

  final DevicesApi _devices;
  final PushStateStore _store;
  final PushTransport _transport;
  final SessionController _session;
  final SettingsStore? _prefs;
  final DateTime Function() _now;
  final String Function() _newDeviceId;

  static const Duration keyLifetime = Duration(days: 30);
  static const Duration refreshEvery = Duration(days: 7);

  StreamSubscription<String>? _tokenSub;
  SessionStatus? _lastStatus;
  Future<void>? _syncing;

  /// Empieza a escuchar: entrar en la cuenta, cambios de token y "Cerrar sesión".
  void start() {
    _session.addSignOutHook(unregister);
    _session.addListener(_onSession);
    _tokenSub = _transport.tokenRefresh.listen((_) => unawaited(sync()));
    _onSession();
  }

  void dispose() {
    _session.removeListener(_onSession);
    unawaited(_tokenSub?.cancel());
  }

  /// Se asegura de que el servidor conoce este móvil. Si ya se está haciendo,
  /// espera a esa misma vez (nunca dos registros a la vez).
  Future<void> sync() =>
      _syncing ??= _sync().whenComplete(() => _syncing = null);

  /// Baja en el servidor (se llama ANTES de olvidar los pases).
  Future<void> unregister() async {
    // Si había un registro a medias, se espera: si no, podría guardar las
    // claves DESPUÉS de haberlas borrado.
    try {
      await _syncing;
    } on Object {
      // Da igual cómo acabó: ahora toca borrar.
    }
    final PushState? state = await _store.read();
    try {
      if (state != null) await _devices.unregister(state.deviceId);
    } on ApiException {
      // Sin red: el token se borra igualmente abajo, y el notifier quita
      // los móviles cuyo token Firebase da por muerto.
    }
    await _forget();
  }

  /// true = "Olvidar este teléfono": sin registro ni claves hasta que lo
  /// vuelvas a activar.
  bool get paused => _prefs?.readData(LocalData.pushOff) == '1';

  /// Privacidad → "Olvidar este teléfono" (true) o "Volver a activar" (false).
  Future<void> setPaused(bool off) async {
    await _prefs?.writeData(LocalData.pushOff, off ? '1' : null);
    if (off) {
      await unregister();
    } else {
      await sync();
    }
  }

  // ---------------------------------------------------------------------------

  void _onSession() {
    final SessionStatus status = _session.status;
    if (status == _lastStatus) return;
    final SessionStatus? before = _lastStatus;
    _lastStatus = status;
    if (status == SessionStatus.signedIn) {
      unawaited(sync());
    } else if (before == SessionStatus.signedIn) {
      // La sesión terminó (también si caducó sola): fuera claves.
      unawaited(_forget());
    }
  }

  Future<void> _sync() async {
    if (_session.status != SessionStatus.signedIn || paused) return;
    final String? token;
    try {
      token = await _transport.token();
    } on Object {
      return; // sin Google Play o sin red: se reintentará al volver a la app
    }
    if (token == null || token.isEmpty) return;

    final DateTime now = _now();
    PushState state = await _store.read() ?? await _fresh(now);
    // Cambio de clave periódico, solo si el servidor ya tiene la actual (si
    // no, la "anterior" sería una que el servidor nunca conoció).
    if (state.confirmed && now.difference(state.keyCreatedAt) > keyLifetime) {
      final PushKeyPair next = await PushKeyPair.generate();
      state = PushState(
        deviceId: state.deviceId,
        currentKey: next.privateKey,
        keyCreatedAt: now,
        previousKey: state.currentKey,
        token: state.token,
        registeredAt: state.registeredAt,
      );
    }
    await _store.write(state);

    final DateTime? registeredAt = state.registeredAt;
    final bool upToDate =
        state.confirmed &&
        state.token == token &&
        registeredAt != null &&
        now.difference(registeredAt) < refreshEvery;
    if (upToDate) return;

    for (int attempt = 0; attempt < 2; attempt++) {
      final PushKeyPair pair = await PushKeyPair.fromPrivate(state.currentKey);
      try {
        await _devices.register(
          deviceId: state.deviceId,
          fcmToken: token,
          publicKey: pair.publicKey,
        );
      } on ApiException catch (e) {
        if (e.error != ApiError.conflict) return; // se reintentará más tarde
        // Ese número ya es de otra cuenta: uno nuevo y otra vez.
        state = state.copyWith(deviceId: _newDeviceId(), confirmed: false);
        await _store.write(state);
        continue;
      }
      // Si mientras tanto se cerró la sesión, no se guarda nada.
      if (_session.status != SessionStatus.signedIn) return;
      await _store.write(
        state.copyWith(confirmed: true, token: token, registeredAt: now),
      );
      return;
    }
  }

  Future<PushState> _fresh(DateTime now) async {
    final PushKeyPair pair = await PushKeyPair.generate();
    return PushState(
      deviceId: _newDeviceId(),
      currentKey: pair.privateKey,
      keyCreatedAt: now,
    );
  }

  Future<void> _forget() async {
    await _store.clear();
    try {
      await _transport.deleteToken();
    } on Object {
      // Mejor esfuerzo.
    }
  }
}
