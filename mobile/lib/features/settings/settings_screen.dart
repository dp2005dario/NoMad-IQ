// Ajustes (maqueta "Ajustes"): tu perfil, el idioma, la Bóveda, cerrar
// sesión y "Borrar mi cuenta y mis datos" (con "Descargar mis datos" antes).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../auth/auth_api.dart';
import '../../auth/session.dart';
import '../../core/config.dart';
import '../../core/languages.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../home/home_screen.dart' show displayName;
import 'account_data.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.saver = const DeviceDataSaver()});

  /// Dónde se guarda "Descargar mis datos" (en los tests, uno falso).
  final DataSaver saver;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _copied = false;
  bool _busy = false;

  void _say(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> _copyId(String id) async {
    await Clipboard.setData(ClipboardData(text: SettingsScreenIds.short(id)));
    if (!mounted) return;
    setState(() => _copied = true);
    Future<void>.delayed(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  Future<void> _download() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final AppServices services = ServicesScope.of(context);
    final SessionController session = SessionScope.read(context);
    setState(() => _busy = true);
    try {
      final Map<String, Object?> data = await collectMyData(
        api: services.api,
        session: session,
        prefs: services.prefs,
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

  Future<void> _askDelete() async {
    final _DeleteChoice? choice = await showDialog<_DeleteChoice>(
      context: context,
      builder: (BuildContext context) => const _DeleteDialog(),
    );
    if (!mounted || choice == null) return;
    if (choice == _DeleteChoice.download) {
      await _download();
      return;
    }
    final String? password = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => const _PasswordDialog(),
    );
    if (!mounted || password == null || password.isEmpty) return;
    await _erase(password);
  }

  Future<void> _erase(String password) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final AppServices services = ServicesScope.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AccountEraser eraser = AccountEraser(
      session: SessionScope.read(context),
      api: services.api,
      vault: services.vault,
      prefs: services.prefs,
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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SessionController session = SessionScope.of(context);
    final SettingsController settings = SettingsScope.of(context);
    final bool signedIn = session.status == SessionStatus.signedIn;
    final UserProfile? user = session.user;
    final String name = displayName(user?.email) ?? t.accountGuest;
    final Locale? locale = settings.locale;

    return Scaffold(
      appBar: AppBar(title: Text(t.settingsTitle)),
      body: Stack(
        children: <Widget>[
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: <Widget>[
              Text(
                t.settingsSubtitle,
                style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
              ),
              const SizedBox(height: 16),
              // Tarjeta de perfil: inicial, nombre, email e ID.
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: NomadColors.group,
                        foregroundColor: NomadColors.background,
                        child: Text(
                          name.characters.first.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(name, style: text.titleLarge),
                            if (user != null) ...<Widget>[
                              Text(
                                user.email,
                                style: text.bodySmall?.copyWith(
                                  color: NomadColors.textMuted,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 6),
                              InkWell(
                                onTap: () => _copyId(user.id),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  child: Text(
                                    _copied
                                        ? t.settingsIdCopied
                                        : t.settingsCopyId(
                                            SettingsScreenIds.short(user.id),
                                          ),
                                    style: text.labelMedium?.copyWith(
                                      color: NomadColors.mint,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _Header(t.settingsSectionApp),
              Card(
                child: Column(
                  children: <Widget>[
                    ListTile(
                      leading: const Icon(
                        Icons.translate_rounded,
                        color: NomadColors.flights,
                      ),
                      title: Text(t.languageTitle),
                      subtitle: Text(
                        locale == null
                            ? t.languageSystem
                            : endonymFor(locale.languageCode),
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push(Routes.language),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(
                        Icons.lock_rounded,
                        color: NomadColors.safety,
                      ),
                      title: Text(t.settingsVault),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push(Routes.vault),
                    ),
                  ],
                ),
              ),
              _Header(t.settingsSectionAccount),
              Card(
                child: Column(
                  children: <Widget>[
                    if (signedIn) ...<Widget>[
                      ListTile(
                        leading: const Icon(Icons.download_rounded),
                        title: Text(t.downloadMyData),
                        onTap: _busy ? null : _download,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.logout_rounded),
                        title: Text(t.signOut),
                        onTap: _busy ? null : session.signOut,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(
                          Icons.delete_forever_rounded,
                          color: NomadColors.safety,
                        ),
                        title: Text(
                          t.settingsDeleteAccount,
                          style: const TextStyle(color: NomadColors.safety),
                        ),
                        onTap: _busy ? null : _askDelete,
                      ),
                    ] else
                      ListTile(
                        leading: const Icon(
                          Icons.login_rounded,
                          color: NomadColors.mint,
                        ),
                        title: Text(t.signInFromGuest),
                        onTap: () => context.push(Routes.signIn),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                t.settingsFooter(AppConfig.version),
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
              ),
            ],
          ),
          if (_busy)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(),
            ),
        ],
      ),
    );
  }
}

abstract final class SettingsScreenIds {
  /// El ID corto que se enseña: los 8 primeros caracteres del id de la
  /// cuenta. Sirve para que soporte te encuentre sin pedirte el email.
  static String short(String id) {
    final String clean = id.replaceAll('-', '').toUpperCase();
    return clean.length <= 8 ? clean : clean.substring(0, 8);
  }
}

class _Header extends StatelessWidget {
  const _Header(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelMedium
          ?.copyWith(color: NomadColors.textMuted, letterSpacing: 1.2),
    ),
  );
}

enum _DeleteChoice { download, delete }

/// "¿Borrar tu cuenta?" con sus tres salidas (como en la maqueta).
class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    return AlertDialog(
      icon: const Icon(
        Icons.delete_forever_rounded,
        color: NomadColors.safety,
        size: 40,
      ),
      title: Text(t.deleteTitle),
      content: SingleChildScrollView(child: Text(t.deleteBody)),
      actions: <Widget>[
        // En columna: con textos largos (alemán, hindi) no caben en fila.
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            OutlinedButton.icon(
              icon: const Icon(Icons.download_rounded),
              label: Text(t.downloadMyData),
              onPressed: () => Navigator.pop(context, _DeleteChoice.download),
            ),
            const SizedBox(height: 8),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: NomadColors.safety,
              ),
              onPressed: () => Navigator.pop(context, _DeleteChoice.delete),
              child: Text(t.deleteConfirm),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(m.cancelButtonLabel),
            ),
          ],
        ),
      ],
    );
  }
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
