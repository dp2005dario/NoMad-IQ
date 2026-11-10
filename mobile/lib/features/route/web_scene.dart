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

/// Un trocito de JavaScript que va al principio de TODAS las páginas para
/// que la app vaya fluida (las maquetas tienen muchas animaciones):
///
///  1. Las animaciones que se repiten siempre y están FUERA de la pantalla
///     (más abajo, sin hacer scroll) se paran hasta que se ven. El móvil
///     solo dibuja lo que tienes delante.
///  2. Cuando la pantalla queda tapada por otra (abres Hoteles encima de
///     Inicio, o cambias de pestaña), la app llama a __eclVis(false) y la
///     página se congela entera: animaciones y dibujos (requestAnimationFrame).
///     Antes seguían moviéndose a escondidas y robaban fuerza a la pantalla
///     que sí estabas mirando. __eclVis(true) lo despierta todo.
///  3. Las fotos se descodifican aparte, sin frenar las animaciones.
///
/// No cambia nada de lo que se ve: solo deja de gastar en lo que no se ve.
const String webScenePrelude = r'''<script>(function(){
var shown=true,frozen=[],waiting=[],raf=window.requestAnimationFrame.bind(window);
window.requestAnimationFrame=function(cb){if(shown)return raf(cb);waiting.push(cb);return 0;};
var seen=new WeakMap(),io=('IntersectionObserver' in window)?new IntersectionObserver(function(es){
es.forEach(function(e){var l=seen.get(e.target)||[];l.forEach(function(a){
if(e.isIntersecting){if(shown&&a.playState==='paused'&&a.__ecl)a.play();a.__ecl=false;}
else if(a.playState==='running'){a.pause();a.__ecl=true;}});});},{rootMargin:'120px'}):null;
function scan(){if(!io||!document.getAnimations)return;document.getAnimations().forEach(function(a){
var ef=a.effect,t=ef&&ef.target;if(!t||!ef.getTiming||ef.getTiming().iterations!==Infinity)return;
var l=seen.get(t);if(!l){l=[];seen.set(t,l);io.observe(t);}if(l.indexOf(a)<0){l.push(a);io.unobserve(t);io.observe(t);}});}
window.__eclVis=function(v){if(v===shown)return;shown=v;
if(!v){frozen=document.getAnimations?document.getAnimations().filter(function(a){return a.playState==='running';}):[];
frozen.forEach(function(a){a.pause();});document.querySelectorAll('video').forEach(function(m){if(!m.paused){m.pause();m.__ecl=true;}});}
else{frozen.forEach(function(a){if(!a.__ecl)a.play();});frozen=[];
document.querySelectorAll('video').forEach(function(m){if(m.__ecl){m.__ecl=false;m.play();}});
var w=waiting;waiting=[];w.forEach(function(cb){raf(cb);});scan();}};
new MutationObserver(function(ms){ms.forEach(function(m){m.addedNodes.forEach(function(n){
if(n.tagName==='IMG'&&!n.hasAttribute('decoding'))n.decoding='async';});});})
.observe(document.documentElement,{childList:true,subtree:true});
var tick=0;function loop(){if(shown)scan();if(++tick<20)setTimeout(loop,tick<5?400:1500);else setInterval(function(){if(shown)scan();},4000);}
document.addEventListener('DOMContentLoaded',function(){scan();loop();});
})();</script>''';

/// La página con [webScenePrelude] puesto lo primero (justo tras `<head>`).
String withPrelude(String html) {
  final int head = html.indexOf(RegExp('<head[^>]*>', caseSensitive: false));
  if (head < 0) return '$webScenePrelude$html';
  final int end = html.indexOf('>', head) + 1;
  return '${html.substring(0, end)}$webScenePrelude${html.substring(end)}';
}

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
        onPageFinished: (_) => _loaded(),
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
    ..loadHtmlString(withPrelude(widget.html));

  /// ¿Se está viendo? (pestaña activa y sin otra pantalla encima).
  bool _visible = true;

  /// Lo que la app manda antes de que la página termine de cargar se
  /// guarda y se manda en cuanto carga (si no, se perdería).
  bool _ready = false;
  final List<String> _pending = <String>[];

  void _loaded() {
    if (_ready) return;
    _ready = true;
    final List<String> todo = List<String>.of(_pending);
    _pending.clear();
    for (final String js in todo) {
      _controller.runJavaScript(js).catchError((Object _) {});
    }
  }

  Future<void> _run(String js) async {
    if (!_ready) {
      _pending.add(js);
      return;
    }
    await _controller.runJavaScript(js);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // TickerMode se apaga en las pestañas que no estás mirando; isCurrent
    // es false cuando otra pantalla está encima de esta.
    final bool visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    if (visible == _visible) return;
    _visible = visible;
    _controller
        .runJavaScript('window.__eclVis&&window.__eclVis($visible)')
        .catchError((Object _) {});
  }

  @override
  void initState() {
    super.initState();
    widget.bridge?._run = _run;
  }

  @override
  void dispose() {
    if (widget.bridge?._run == _run) {
      widget.bridge?._run = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
