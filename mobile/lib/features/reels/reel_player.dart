// Ver los reels a pantalla completa, deslizando hacia arriba para pasar al
// siguiente (como en TikTok o Instagram). Cada vídeo es el reproductor
// oficial de su red (YouTube, TikTok o Instagram) dentro de un WebView, que
// solo puede abrir esas tres webs.
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'reels.dart';

class ReelPlayerScreen extends StatefulWidget {
  const ReelPlayerScreen({super.key, required this.reels, this.start = 0});

  final List<PlanReel> reels;
  final int start;

  @override
  State<ReelPlayerScreen> createState() => _ReelPlayerScreenState();
}

class _ReelPlayerScreenState extends State<ReelPlayerScreen> {
  late final PageController _pages = PageController(initialPage: widget.start);
  late int _current = widget.start;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(
      children: <Widget>[
        PageView.builder(
          controller: _pages,
          scrollDirection: Axis.vertical,
          itemCount: widget.reels.length,
          onPageChanged: (int i) => setState(() => _current = i),
          // Solo suena el que estás viendo: los demás no se cargan.
          itemBuilder: (BuildContext context, int i) => i == _current
              ? _Reel(
                  key: ValueKey<String>(widget.reels[i].id),
                  reel: widget.reels[i],
                )
              : const ColoredBox(color: Colors.black),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: <Widget>[
                IconButton.filledTonal(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x99000000),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${_current + 1} / ${widget.reels.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// Las únicas webs que puede abrir el reproductor.
bool _allowed(String host) => <String>[
  'youtube.com',
  'tiktok.com',
  'instagram.com',
].any((String d) => host == d || host.endsWith('.$d'));

class _Reel extends StatefulWidget {
  const _Reel({super.key, required this.reel});

  final PlanReel reel;

  @override
  State<_Reel> createState() => _ReelState();
}

class _ReelState extends State<_Reel> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(Colors.black)
    ..setNavigationDelegate(
      NavigationDelegate(
        // Solo los reproductores oficiales: nada de salir a otras webs.
        onNavigationRequest: (NavigationRequest r) =>
            _allowed(Uri.tryParse(r.url)?.host ?? '')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ),
    )
    ..loadRequest(
      widget.reel.player,
      // YouTube pide saber desde qué app se ve (si no, "error 153").
      headers: const <String, String>{'Referer': 'https://com.eclipta.app'},
    );

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
