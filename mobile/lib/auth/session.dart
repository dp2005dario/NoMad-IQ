// La "sesión": quién está usando la app y sus pases para hablar con el backend.
//
// Es un ChangeNotifier (un "altavoz"): cuando alguien entra o sale, avisa al
// router, que lleva solo a la pantalla correcta (Bienvenida o Inicio).
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'auth_api.dart';
import 'token_store.dart';

enum SessionStatus {
  signedOut, // nadie: se enseña la Bienvenida
  guest, // invitado: puede mirar, pero nada se guarda en su cuenta
  signedIn, // con cuenta
}

class SessionController extends ChangeNotifier {
  SessionController({
    required this._api,
    required this._store,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final AuthApi _api;
  final TokenStore _store;
  final DateTime Function() _now;

  SessionStatus _status = SessionStatus.signedOut;
  TokenPair? _tokens;
  String? _refreshToken; // copia en memoria del que está en el almacén seguro
  UserProfile? _user;
  Future<String>? _refreshing;

  SessionStatus get status => _status;
  UserProfile? get user => _user;

  /// Al abrir la app: si quedó un pase largo guardado, se entra directamente
  /// y el perfil se carga en segundo plano. Así la app abre al instante aunque
  /// no haya cobertura (funciona sin conexión y renovará cuando haga falta).
  Future<void> restore() async {
    _refreshToken = await _store.readRefreshToken();
    if (_refreshToken == null) return;
    _status = SessionStatus.signedIn;
    unawaited(_loadProfileQuietly());
  }

  Future<void> signIn(String email, String password) async {
    final TokenPair tokens = await _api.login(email.trim(), password);
    await _accept(tokens);
    _status = SessionStatus.signedIn;
    try {
      await _loadProfile();
    } on AuthException {
      // El perfil es un extra (para el saludo): sin él también se puede entrar.
    }
    notifyListeners();
  }

  /// Crear cuenta y entrar en un solo paso.
  Future<void> register(String email, String password) async {
    await _api.register(email.trim(), password);
    await signIn(email, password);
  }

  void continueAsGuest() {
    _status = SessionStatus.guest;
    notifyListeners();
  }

  /// Cerrar sesión. Primero se olvida todo en el móvil (eso no puede fallar)
  /// y después se avisa al servidor para que anule los pases; si no hay
  /// conexión, el servidor los dará por caducados igualmente al expirar.
  Future<void> signOut() async {
    final String? access = _tokens?.accessToken;
    final String? refresh = _refreshToken;
    await _forget();
    notifyListeners();
    if (access != null && refresh != null) {
      try {
        await _api.logout(access, refresh);
      } on AuthException {
        // Mejor esfuerzo: el usuario ya está fuera en el móvil.
      }
    }
  }

  /// Pase corto válido para llamar a cualquier servicio. Si le quedan menos
  /// de 30 s, se renueva antes. Si dos pantallas lo piden a la vez, se hace
  /// UNA sola renovación (el pase largo es de un solo uso: dos renovaciones
  /// a la vez harían que el servidor cerrase la sesión por "reutilización").
  Future<String> accessToken() async {
    final TokenPair? tokens = _tokens;
    if (tokens != null &&
        tokens.accessExpiresAt.isAfter(
          _now().add(const Duration(seconds: 30)),
        )) {
      return tokens.accessToken;
    }
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  /// Un servicio rechazó el pase [rejected] (401) aunque no había caducado
  /// (por ejemplo, se cerró la sesión en otro móvil). Se tira y se pide uno
  /// nuevo. Si otra pantalla ya lo renovó, se usa ese sin renovar otra vez.
  Future<String> renewAccessToken(String rejected) {
    if (_tokens?.accessToken == rejected) _tokens = null;
    return accessToken();
  }

  // ---------------------------------------------------------------------------

  Future<String> _refresh() async {
    final String? refresh = _refreshToken;
    if (refresh == null) throw const AuthException(AuthError.sessionExpired);
    try {
      final TokenPair tokens = await _api.refresh(refresh);
      await _accept(tokens);
      return tokens.accessToken;
    } on AuthException catch (e) {
      if (e.error == AuthError.sessionExpired) {
        await _forget();
        notifyListeners(); // el router lleva a la Bienvenida
      }
      rethrow;
    }
  }

  /// Si la sesión caducó, _refresh ya la cierra (y el router lleva a la
  /// Bienvenida). Cualquier otro fallo (sin red) se ignora: no es grave.
  Future<void> _loadProfileQuietly() async {
    try {
      await _loadProfile();
      notifyListeners();
    } on AuthException {
      return;
    }
  }

  Future<void> _loadProfile() async {
    _user = await _api.me(await accessToken());
  }

  Future<void> _accept(TokenPair tokens) async {
    _tokens = tokens;
    _refreshToken = tokens.refreshToken;
    await _store.writeRefreshToken(tokens.refreshToken);
  }

  Future<void> _forget() async {
    _tokens = null;
    _refreshToken = null;
    _user = null;
    _status = SessionStatus.signedOut;
    await _store.clear();
  }
}

/// Hace llegar la sesión a cualquier pantalla: `SessionScope.of(context)`.
class SessionScope extends InheritedNotifier<SessionController> {
  const SessionScope({
    super.key,
    required SessionController controller,
    required super.child,
  }) : super(notifier: controller);

  static SessionController of(BuildContext context) {
    final SessionScope? scope = context
        .dependOnInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'Falta SessionScope encima de este widget');
    return scope!.notifier!;
  }

  /// Igual, pero sin redibujar el widget cuando cambia la sesión (para botones).
  static SessionController read(BuildContext context) {
    final SessionScope? scope = context
        .getInheritedWidgetOfExactType<SessionScope>();
    assert(scope != null, 'Falta SessionScope encima de este widget');
    return scope!.notifier!;
  }
}
