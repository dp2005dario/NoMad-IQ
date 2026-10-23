// Traduce cada tipo de error de la sesión a un texto para el usuario, en su
// idioma. El servidor manda sus propios mensajes, pero en español: aquí se
// ignoran y se usa el texto del .arb que toque.
import '../l10n/generated/app_localizations.dart';
import 'auth_api.dart';

String authErrorText(AppLocalizations t, AuthError error) => switch (error) {
  AuthError.invalidCredentials => t.errorInvalidCredentials,
  AuthError.sessionExpired => t.errorSessionExpired,
  AuthError.emailTaken => t.errorEmailTaken,
  AuthError.invalidInput => t.errorInvalidInput,
  AuthError.rateLimited => t.errorRateLimited,
  AuthError.unavailable => t.errorUnavailable,
  AuthError.network => t.errorNetwork,
};
