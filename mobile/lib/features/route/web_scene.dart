// El "navegador dentro de la pantalla" (WebView) donde se ve el Vuelo 3D.
//
// Seguridad: la página va dentro de la app y no necesita Internet. Por eso
// se bloquea CUALQUIER intento de ir a otra dirección (aunque la página no
// tiene enlaces, así un fallo no puede abrir webs dentro de la app). La
// página solo puede mandar a la app avisos cortos por el canal "ECLIPTA":
// una palabra y, como mucho, dos números ("landed", "done", "back",
// "route:105", "night:2:9000"...). Cualquier otra cosa se tira. Cada pantalla decide qué
// hace con los avisos que entiende.
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Los únicos avisos que pasan: una palabra en minúsculas y, si acaso, uno
/// o dos números separados por ":" ("night:2:9000"). Y uno más: "save" con
/// el número de la tarjeta y sus datos en base64url (la Bóveda), que solo
/// lleva letras, números, "-" y "_".
final RegExp webSceneMessage = RegExp(
  r'^([a-z]{1,12}(:[0-9]{1,8}){0,2}|save:[0-9]{1,2}:[A-Za-z0-9_-]{1,4000})$',
);

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
        if (webSceneMessage.hasMatch(m.message)) widget.onMessage(m.message);
      },
    )
    ..loadHtmlString(widget.html);

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
