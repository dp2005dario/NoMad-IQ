// El "navegador dentro de la pantalla" (WebView) donde se ve el Vuelo 3D.
//
// Seguridad: la página va dentro de la app y no necesita Internet. Por eso
// se bloquea CUALQUIER intento de ir a otra dirección (aunque la página no
// tiene enlaces, así un fallo no puede abrir webs dentro de la app). La
// página solo puede mandar a la app dos palabras por el canal "ECLIPTA":
// "landed" (ha aterrizado) y "done" (pulsó Continuar).
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebScene extends StatefulWidget {
  const WebScene({super.key, required this.html, required this.onMessage});

  final String html;
  final void Function(String message) onMessage;

  @override
  State<WebScene> createState() => _WebSceneState();
}

class _WebSceneState extends State<WebScene> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(const Color(0xFF050A14))
    ..setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (NavigationRequest r) =>
            r.url == 'about:blank' || r.url.startsWith('data:')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ),
    )
    ..addJavaScriptChannel(
      'ECLIPTA',
      onMessageReceived: (JavaScriptMessage m) {
        if (m.message == 'landed' || m.message == 'done') {
          widget.onMessage(m.message);
        }
      },
    )
    ..loadHtmlString(widget.html);

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
