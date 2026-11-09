// Ajustes: la maqueta "Ajustes" tal cual (assets/settings/ajustes.html,
// dentro de un WebView). Tu foto o avatar (solo en este móvil), tu nombre,
// tu correo y tu ID, los 4 interruptores de "Lo más importante", "Tu app"
// (idioma, moneda, Modo fácil, privacidad, avisos y ayuda), ECLIPTA Premium
// "Próximamente", cerrar sesión y "Borrar mi cuenta y mis datos".
//
// Los interruptores:
//  - Avisos de chollos: apaga o enciende los avisos de bajadas de precio.
//  - Entrar con huella o cara: la app pide tu huella al abrirse
//    (app_lock.dart). La Bóveda la pide siempre.
//  - Audioguías por zona: los avisos "estás en un sitio nuevo".
//  - Tema oscuro: se guarda tu elección (por ahora la app solo es oscura).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../auth/auth_api.dart';
import '../../auth/session.dart';
import '../../core/config.dart';
import '../../core/languages.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/user_avatar.dart' show isTrustedPhotoUrl;
import '../flights/flights_page.dart' show unpackJson;
import '../home/home_screen.dart' show displayName;
import '../money/money_screen.dart' show MoneyTab;
import '../push/notice_prefs.dart';
import '../push/push_notice.dart';
import '../route/web_scene.dart';
import '../vault/vault_store.dart';
import 'account_data.dart';
import 'app_lock.dart';
import 'profile_photo.dart';
import 'settings_page.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.saver = const DeviceDataSaver()});

  /// Dónde se guarda "Descargar mis datos" (en los tests, uno falso).
  final DataSaver saver;

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = SettingsScreen.lastBridge = WebSceneBridge();
  final ProfilePhotoController _photo = ProfilePhotoController.instance;

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;
  String? _html;
  String? _sent;
  bool _started = false;
  bool _busy = false;

  /// Tu foto del móvil ya leída para la página (ruta → data:...).
  final Map<String, String> _files = <String, String>{};

  /// Lo que la página debe recibir una vez (cómo quedaron los
  /// interruptores, aunque no hayan cambiado).
  Map<String, Object?> _once = <String, Object?>{};
  int _round = 0;

  /// Las audioguías y el "bienvenido" del aeropuerto van juntos (como en
  /// Privacidad): los dos son avisos "estás en un sitio nuevo".
  static const Set<PushKind> _guides = <PushKind>{
    PushKind.zoneAudioguide,
    PushKind.airportArrival,
  };
  static const Set<PushKind> _deals = <PushKind>{PushKind.fareAlert};

  @override
  void initState() {
    super.initState();
    _photo.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _services.easyMode.addListener(_changed);
    unawaited(_start());
  }

  @override
  void dispose() {
    _photo.removeListener(_changed);
    _services.easyMode.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(settingsPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Lee tu foto del móvil para enseñarla en la página.
  Future<void> _readFile(String path) async {
    try {
      final List<int> bytes = await File(path).readAsBytes();
      _files[path] = 'data:image/jpeg;base64,${base64Encode(bytes)}';
    } on Object {
      _files[path] = ''; // ya no está: se ve tu inicial
    }
    if (mounted) setState(() {});
  }

  /// Cómo quedaron los interruptores (se manda aunque no cambien).
  void _resend() =>
      setState(() => _once = <String, Object?>{..._once, 'round': ++_round});

  Future<void> _toggle(String key, bool on) async {
    final SettingsStore prefs = _services.prefs;
    switch (key) {
      case 'ofertas':
        await setMuted(prefs, _deals, !on);
      case 'ubicacion':
        await setMuted(prefs, _guides, !on);
      case 'oscuro':
        await prefs.writeData(LocalData.darkTheme, on ? null : '0');
        if (!on && mounted) {
          _say(
            'Por ahora ECLIPTA solo tiene tema oscuro. Tu elección queda guardada.',
          );
        }
      case 'huella':
        if (!on) {
          await prefs.writeData(LocalData.appLock, null);
        } else {
          // Antes de encenderlo, se mira que tu huella funciona (si no, te
          // quedarías fuera de la app).
          final String reason = AppLocalizations.of(context).appLockReason;
          final UnlockResult r = await _services.vault.verify(reason);
          if (r == UnlockResult.ok) {
            await prefs.writeData(LocalData.appLock, '1');
          } else if (r == UnlockResult.unavailable && mounted) {
            _say(
              'Tu móvil no tiene huella, cara ni PIN. Ponlo en los ajustes del móvil y vuelve a probar.',
            );
          }
        }
    }
    if (mounted) _resend();
  }

  Future<void> _source(int n) async {
    final String? google = SessionScope.read(context).user?.photoUrl;
    switch (n) {
      case 0:
        await _photo.pick(ImageSource.camera);
      case 1:
        await _photo.pick(ImageSource.gallery);
      case 2:
        if (isTrustedPhotoUrl(google)) {
          await _photo.remove();
        } else if (mounted) {
          _say('Tu cuenta no tiene foto de Google.');
        }
      case 3:
        await _photo.chooseInitial();
    }
  }

  Future<void> _download() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final SessionController session = SessionScope.read(context);
    setState(() => _busy = true);
    try {
      final Map<String, Object?> data = await collectMyData(
        api: _services.api,
        session: session,
        prefs: _services.prefs,
      );
      final bool saved = await widget.saver.save(
        exportFileName(DateTime.now()),
        encodeExport(data),
      );
      if (saved && mounted) _say(t.downloadDone);
    } on Object {
      if (mounted) _say(t.exportFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// "Sí, borrar mi cuenta": se pide la contraseña y se borra todo.
  Future<void> _askPassword() async {
    final String? password = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _PasswordDialog(),
    );
    if (!mounted || password == null || password.isEmpty) return;
    await _erase(password);
  }

  Future<void> _erase(String password) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AccountEraser eraser = AccountEraser(
      session: SessionScope.read(context),
      api: _services.api,
      vault: _services.vault,
      prefs: _services.prefs,
      family: _services.family,
      memories: _services.memories,
      homeWidgets: _services.homeWidgets,
      liveFlight: _services.liveFlight,
    );
    setState(() => _busy = true);
    try {
      await eraser.erase(password);
      // La sesión ya está cerrada: el router lleva a la Bienvenida solo. El
      // aviso se pone en el ScaffoldMessenger de la app, que sobrevive.
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(t.deleteDone)));
    } on EraseFailed catch (e) {
      final Object cause = e.cause;
      final bool wrongPassword =
          e.step == EraseStep.password &&
          cause is AuthException &&
          cause.error == AuthError.invalidCredentials;
      if (mounted) {
        _say(wrongPassword ? t.deleteWrongPassword : t.deleteFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final Map<String, Object?>? data = p.length == 3 ? unpackJson(p[2]) : null;
    final Object? key = data?['k'];
    final SessionController session = SessionScope.read(context);
    switch (p.first) {
      case 'back':
        context.canPop() ? context.pop() : context.go(Routes.home);
      case 'copy':
        final String? id = session.user?.id;
        if (id != null) {
          unawaited(Clipboard.setData(ClipboardData(text: shortId(id))));
        }
      case 'src' when n != null:
        unawaited(_source(n));
      case 'av' when n != null && n >= 0 && n <= presetAvatars.length:
        unawaited(n == 0 ? _photo.chooseInitial() : _photo.choosePreset(n - 1));
      case 'tog' when n != null && key is String:
        unawaited(_toggle(key, n == 1));
      case 'lang':
        unawaited(context.push(Routes.language));
      case 'cur':
        unawaited(context.push(Routes.money(tab: MoneyTab.fx)));
      case 'easy':
        // "Letra grande y modo fácil": Inicio pasa al Modo fácil (y desde
        // allí, "Modo normal" lo quita).
        unawaited(_services.easyMode.set(true));
        context.go(Routes.home);
      case 'privacy':
        unawaited(context.push(Routes.privacy));
      case 'notices':
        unawaited(context.push(Routes.notices));
      case 'help':
        unawaited(context.push(Routes.help));
      case 'signout' when !_busy:
        unawaited(session.signOut());
      case 'signin':
        unawaited(context.push(Routes.signIn));
      case 'download' when !_busy:
        unawaited(_download());
      case 'erase' when !_busy:
        unawaited(_askPassword());
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final AppLocalizations t = AppLocalizations.of(context);
    final SessionController session = SessionScope.of(context);
    final Locale? locale = SettingsScope.of(context).locale;
    final UserProfile? user = session.user;
    final bool signedIn = session.status == SessionStatus.signedIn;
    final ProfilePhotoChoice choice = _photo.choice;
    final String? path = choice.filePath;
    if (path != null && !_files.containsKey(path)) unawaited(_readFile(path));
    final String file = path == null ? '' : _files[path] ?? '';
    final Set<PushKind> muted = mutedKinds(_services.prefs);
    final String device = Platform.localeName;
    final Map<String, Object?> data = settingsPageData(
      name: displayName(user?.email) ?? t.accountGuest,
      email: user?.email,
      id: user?.id,
      signedIn: signedIn,
      photo: photoJson(
        choice,
        file: file.isEmpty ? null : file,
        google: user?.photoUrl,
      ),
      deals: !muted.containsAll(_deals),
      lock: appLockOn(_services.prefs),
      guides: !muted.containsAll(_guides),
      dark: _services.prefs.readData(LocalData.darkTheme) != '0',
      lang: locale == null ? t.languageSystem : endonymFor(locale.languageCode),
      cur: currencyLabel(device),
      easy: _services.easyMode.value,
      version: AppConfig.version,
    );
    final Map<String, Object?> once = _once;
    final String push = settingsPushScript(<String, Object?>{...data, ...once});
    if (_html == null) {
      _html = settingsPageWith(page, data);
      _sent = push;
      _once = <String, Object?>{};
    } else if (push != _sent) {
      _sent = push;
      _once = <String, Object?>{};
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: <Widget>[
            _services.webScene?.call(html, _onMessage) ??
                WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
            if (_busy)
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }
}

/// Lo de antes (lo usan los tests): el ID corto de tu cuenta.
abstract final class SettingsScreenIds {
  static String short(String id) => shortId(id);
}

/// Pide la contraseña. Es un StatefulWidget porque es dueño del
/// TextEditingController (se libera cuando el diálogo termina de cerrarse).
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(t.deletePasswordTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.deletePasswordWhy),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            autofocus: true,
            autofillHints: const <String>[AutofillHints.password],
            decoration: InputDecoration(labelText: t.deletePasswordLabel),
            onSubmitted: (String v) => Navigator.pop(context, v),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(m.cancelButtonLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: NomadColors.safety,
            minimumSize: const Size(0, 48),
          ),
          onPressed: () => Navigator.pop(context, _password.text),
          child: Text(t.deleteNow),
        ),
      ],
    );
  }
}
