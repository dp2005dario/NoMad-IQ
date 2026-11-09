// El "navegador dentro de la pantalla" (WebView) donde se ve el Vuelo 3D.
//
// Seguridad: la página va dentro de la app y no necesita Internet. Por eso
// se bloquea CUALQUIER intento de ir a otra dirección (aunque la página no
// tiene enlaces, así un fallo no puede abrir webs dentro de la app). La
// página solo puede mandar a la app avisos cortos por el canal "ECLIPTA":
// una palabra y, como mucho, dos números ("landed", "done", "back",
// "route:105", "night:2:9000"...) o una palabra, un número y unos datos en
// base64url ("save:5:WyJ...", "go:0:eyJ..."). Cualquier otra cosa se tira.
// Cada pantalla decide qué hace con los avisos que entiende.
//
// Al revés, la app le puede mandar datos a la página ya abierta (sin
// recargarla) con un WebSceneBridge.
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Los únicos avisos que pasan: una palabra en minúsculas y, si acaso, uno
/// o dos números separados por ":" ("night:2:9000"). O una palabra, un
/// número y datos en base64url ("save:5:WyJ..." de la Bóveda), que solo
/// llevan letras, números, "-" y "_".
final RegExp webSceneMessage = RegExp(
  r'^([a-z]{1,12}(:[0-9]{1,8}){0,2}|[a-z]{1,12}:[0-9]{1,8}:[A-Za-z0-9_-]{1,4000})$',
);

/// Para mandarle a la página JavaScript cuando ya está abierta. Sin página
/// (o en los tests), lo mandado se queda apuntado en [sent].
class WebSceneBridge {
  Future<void> Function(String js)? _run;

  /// Lo mandado cuando no había página (lo miran los tests).
  final List<String> sent = <String>[];

  Future<void> run(String js) async {
    final Future<void> Function(String js)? run = _run;
    if (run == null) {
      sent.add(js);
      return;
    }
    try {
      await run(js);
    } on Object {
      // La página se cerró o se está recargando: no pasa nada.
    }
  }
}

class WebScene extends StatefulWidget {
  const WebScene({
    super.key,
    required this.html,
    required this.onMessage,
    this.bridge,
  });

  final String html;
  final void Function(String message) onMessage;
  final WebSceneBridge? bridge;

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
  void initState() {
    super.initState();
    widget.bridge?._run = _controller.runJavaScript;
  }

  @override
  void dispose() {
    if (widget.bridge?._run == _controller.runJavaScript) {
      widget.bridge?._run = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
