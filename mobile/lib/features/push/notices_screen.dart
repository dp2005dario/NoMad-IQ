// Avisos (maqueta "Avisos"): el historial de lo que te ha llegado, con
// pestañas por tipo. Es la maqueta tal cual (assets/push/avisos.html) con tu
// historial de verdad, que se lee del móvil. Tocar un aviso abre su pantalla.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../route/web_scene.dart';
import 'notice_log.dart';
import 'notices_page.dart';

class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = NoticesScreen.lastBridge = WebSceneBridge();

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;
  List<NoticeEntry> _all = <NoticeEntry>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(noticesPage, cache: false);
    } on Object {
      return;
    }
    // Los avisos que llegan con la app cerrada se apuntan desde "otro
    // proceso": se vuelve a leer del disco para verlos.
    await _services.prefs.reload();
    if (mounted) setState(() => _all = NoticeLog(_services.prefs).all());
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? i = p.length > 1 ? int.tryParse(p[1]) : null;
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'open' when i != null && i < _all.length:
        final String? route = _all[i].route;
        if (route != null) unawaited(context.push(route));
    }
  }

  Map<String, Object?> _data(AppLocalizations t) => <String, Object?>{
    'title': t.noticesTitle,
    'tabs': <String>[
      t.noticesAll,
      t.noticesZones,
      t.noticesFlights,
      t.navGroup,
    ],
    'empty': t.noticesEmpty,
    'footer': t.noticesFooter,
    'items': noticeItems(_all, DateTime.now(), t.noticesYesterday),
  };

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = _data(AppLocalizations.of(context));
    final String push = noticesPushScript(data);
    if (_html == null) {
      _html = noticesPageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            _services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }
}
