// "Continuar con Google": pide a Google un id_token (un justificante firmado
// de que esta persona es dueña de su cuenta de Google). Lo comprueba el
// auth-gateway; la app nunca ve la contraseña de Google.
//
// Es una "interfaz" (un enchufe): en la app se conecta el paquete
// google_sign_in y en los tests una falsa.
import 'package:google_sign_in/google_sign_in.dart';

abstract interface class GoogleIdTokenSource {
  /// El id_token, o null si la persona cerró la ventana de Google.
  /// Lanza una excepción si Google falla de verdad.
  Future<String?> idToken();
}

class PluginGoogleIdTokenSource implements GoogleIdTokenSource {
  PluginGoogleIdTokenSource(this.serverClientId);

  /// El Client ID de tipo "Web" (el mismo que lleva el servidor).
  final String serverClientId;
  bool _ready = false;

  @override
  Future<String?> idToken() async {
    final GoogleSignIn google = GoogleSignIn.instance;
    if (!_ready) {
      await google.initialize(serverClientId: serverClientId);
      _ready = true;
    }
    try {
      final GoogleSignInAccount account = await google.authenticate();
      return account.authentication.idToken;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }
}
