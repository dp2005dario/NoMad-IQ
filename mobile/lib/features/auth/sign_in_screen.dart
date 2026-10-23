// Iniciar sesión o crear cuenta con correo y contraseña (auth-gateway).
import 'package:flutter/material.dart';

import '../../auth/auth_api.dart';
import '../../auth/auth_messages.dart';
import '../../auth/session.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';

/// Mismas reglas que el servidor (ApiModels.java). Se comprueban también aquí
/// para avisar al momento, sin esperar a la red; el servidor SIEMPRE vuelve a
/// comprobarlas (nunca se fía solo del móvil).
const int minPasswordLength = 12;
const int maxPasswordLength = 128;
final RegExp _emailShape = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, this.startWithRegister = false});

  final bool startWithRegister;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final GlobalKey<FormState> _form = GlobalKey<FormState>();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  late bool _register = widget.startWithRegister;
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    // Los controladores guardan lo escrito: se liberan al cerrar la pantalla.
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final SessionController session = SessionScope.read(context);
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      if (_register) {
        await session.register(_email.text, _password.text);
      } else {
        await session.signIn(_email.text, _password.text);
      }
      // No hace falta navegar: el router ve "signedIn" y lleva a Inicio solo.
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = authErrorText(t, e.error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(_register ? t.registerTitle : t.signInTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          // AutofillGroup: el gestor de contraseñas del móvil puede rellenar
          // y guardar los datos (más seguro que contraseñas cortas de memoria).
          child: AutofillGroup(
            child: Form(
              key: _form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Center(child: FlyraAvatar(size: 64)),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    autofillHints: const <String>[AutofillHints.email],
                    autocorrect: false,
                    maxLength: 254,
                    decoration: InputDecoration(
                      labelText: t.emailLabel,
                      prefixIcon: const Icon(Icons.mail_rounded),
                      counterText: '',
                    ),
                    validator: (String? v) =>
                        _emailShape.hasMatch(v?.trim() ?? '')
                        ? null
                        : t.errorEmailInvalid,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    obscureText: _obscure,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    autofillHints: <String>[
                      if (_register)
                        AutofillHints.newPassword
                      else
                        AutofillHints.password,
                    ],
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: maxPasswordLength,
                    decoration: InputDecoration(
                      labelText: t.passwordLabel,
                      helperText: _register ? t.passwordHintRegister : null,
                      prefixIcon: const Icon(Icons.lock_rounded),
                      counterText: '',
                      suffixIcon: IconButton(
                        tooltip: _obscure ? t.showPassword : t.hidePassword,
                        onPressed: () => setState(() => _obscure = !_obscure),
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_rounded,
                        ),
                      ),
                    ),
                    validator: (String? v) {
                      final String value = v ?? '';
                      if (value.isEmpty) return t.errorPasswordRequired;
                      if (_register && value.length < minPasswordLength) {
                        return t.errorPasswordShort;
                      }
                      return null;
                    },
                  ),
                  if (_error != null) ...<Widget>[
                    const SizedBox(height: 16),
                    // liveRegion: el lector de pantalla lee el error en cuanto aparece.
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: text.bodyMedium?.copyWith(
                          color: NomadColors.safety,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5),
                          )
                        : Text(_register ? t.registerButton : t.signInButton),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _register = !_register;
                            _error = null;
                          }),
                    child: Text(
                      _register ? t.switchToSignIn : t.switchToRegister,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
