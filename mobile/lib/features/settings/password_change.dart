// "Cambiar contraseña" (en Privacidad): pide la actual y la nueva y avisa
// de cómo fue.
import 'package:flutter/material.dart';

import '../../auth/auth_api.dart';
import '../../auth/session.dart';
import '../../l10n/generated/app_localizations.dart';

/// Todo el paso: el diálogo, el cambio en el servidor y el aviso.
Future<void> changePasswordFlow(BuildContext context) async {
  final AppLocalizations t = AppLocalizations.of(context);
  final SessionController session = SessionScope.read(context);
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  void say(String text) => messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
  final (String, String)? pair = await showDialog<(String, String)>(
    context: context,
    builder: (BuildContext context) => const ChangePasswordDialog(),
  );
  if (pair == null) return;
  try {
    await session.changePassword(pair.$1, pair.$2);
    say(t.passwordChanged);
  } on AuthException catch (e) {
    say(switch (e.error) {
      AuthError.invalidCredentials => t.deleteWrongPassword,
      AuthError.invalidInput => t.passwordWeak,
      AuthError.network => t.errorNetwork,
      _ => t.errorUnavailable,
    });
  }
}

/// Pide la contraseña actual y la nueva. Es StatefulWidget porque es dueño de
/// los controladores de texto (se liberan al cerrarse).
class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key});

  @override
  State<ChangePasswordDialog> createState() => ChangePasswordDialogState();
}

class ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final TextEditingController _current = TextEditingController();
  final TextEditingController _next = TextEditingController();

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  void _submit() {
    if (_current.text.isEmpty || _next.text.length < 12) return;
    Navigator.pop(context, (_current.text, _next.text));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final MaterialLocalizations m = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(t.passwordChangeTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _current,
            obscureText: true,
            autofocus: true,
            autofillHints: const <String>[AutofillHints.password],
            decoration: InputDecoration(labelText: t.passwordCurrent),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _next,
            obscureText: true,
            autofillHints: const <String>[AutofillHints.newPassword],
            decoration: InputDecoration(labelText: t.passwordNew),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(m.cancelButtonLabel),
        ),
        FilledButton(onPressed: _submit, child: Text(t.passwordChangeTitle)),
      ],
    );
  }
}
