package com.eclipta.app

import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceFragmentActivity = FlutterFragmentActivity (la ventana de la
// huella de local_auth necesita "fragments") + lo que necesita el audio con
// el móvil bloqueado (just_audio_background) para hablar con la app.
class MainActivity : AudioServiceFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // La Bóveda pide "ventana segura" mientras se ve: Android no deja
        // hacer capturas ni la enseña en la lista de apps recientes.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nomadiq/secure_window")
            .setMethodCallHandler { call, result ->
                if (call.method == "setSecure") {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
        // "Abrir Bizum en tu banco": abre la app oficial del banco si está
        // instalada. Recibe una lista de nombres de paquete (cada banco puede
        // tener varios) y abre el primero que encuentre. true = se abrió.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "nomadiq/apps")
            .setMethodCallHandler { call, result ->
                if (call.method == "open") {
                    val packages = call.arguments as? List<*> ?: emptyList<Any>()
                    var opened = false
                    for (p in packages) {
                        val intent = packageManager.getLaunchIntentForPackage(p.toString())
                        if (intent != null) {
                            startActivity(intent)
                            opened = true
                            break
                        }
                    }
                    result.success(opened)
                } else {
                    result.notImplemented()
                }
            }
    }
}
