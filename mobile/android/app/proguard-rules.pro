# Reglas para R8, el "encogedor" que limpia la APK final (release).
# Sin ellas, R8 puede borrar piezas del inicio de sesión con Google
# (Credential Manager) que se cargan por nombre, y "Continuar con Google"
# falla solo en la APK final, nunca al probar en modo debug.
-if class androidx.credentials.CredentialManager
-keep class androidx.credentials.playservices.** {
  *;
}
-keep class com.google.android.libraries.identity.googleid.** { *; }
