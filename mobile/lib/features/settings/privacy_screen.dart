// Privacidad (maqueta "Privacidad"): la maqueta tal cual
// (assets/settings/privacidad.html) con tus ajustes de verdad: qué avisos
// quieres, la ubicación en segundo plano, las ciudades sin conexión, qué
// sabemos de ti, cambiar la contraseña (con cuenta) y "Olvidar este
// teléfono".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../offline/city_pack.dart';
import '../route/web_scene.dart';
import 'privacy_page.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/location_tracker.dart';
import '../push/notice_prefs.dart';
import '../push/push_notice.dart';
import '../push/push_registrar.dart';
import 'password_change.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  final WebSceneBridge _bridge = PrivacyScreen.lastBridge = WebSceneBridge();
  bool _busy = false;

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(privacyPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
  }

  /// Las audioguías y el "bienvenido" del aeropuerto van juntos: los dos
  /// son avisos "estás en un sitio nuevo".
  static const Set<PushKind> _guides = <PushKind>{
    PushKind.zoneAudioguide,
    PushKind.airportArrival,
  };
  static const Set<PushKind> _deals = <PushKind>{PushKind.fareAlert};
  static const Set<PushKind> _group = <PushKind>{
    PushKind.groupChat,
    PushKind.groupResult,
  };

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _mute(Set<PushKind> kinds, bool on) async {
    await setMuted(ServicesScope.of(context).prefs, kinds, !on);
    if (mounted) setState(() {});
  }

  Future<void> _travel(bool on) async {
    final LocationTracker tracker = ServicesScope.of(context).tracker;
    final AppLocalizations t = AppLocalizations.of(context);
    final TravelModeResult result = await tracker.setTravelMode(on);
    if (!mounted) return;
    switch (result) {
      case TravelModeResult.on:
        break;
      case TravelModeResult.needsAccount:
        _say(t.travelNeedsAccount);
      case TravelModeResult.needsLocation:
        _say(t.mapLocationDenied);
      case TravelModeResult.needsNotifications:
        _say(t.travelNeedsNotifications);
    }
  }

  Future<void> _forget(PushRegistrar push, bool off) async {
    setState(() => _busy = true);
    try {
      await push.setPaused(off);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final AppServices services = ServicesScope.of(context);
    final PushRegistrar? push = services.push;
    final List<String> p = m.split(':');
    final bool on = p.length > 2 && p[2] == '1';
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 't' when p.length > 2:
        switch (p[1]) {
          case 'location':
            unawaited(_travel(on));
          case 'zones':
            unawaited(_mute(_guides, on));
          case 'flights':
            unawaited(_mute(_deals, on));
          case 'group':
            unawaited(_mute(_group, on));
        }
      case 'offline':
        unawaited(context.push(Routes.offline));
      case 'password':
        unawaited(changePasswordFlow(context));
      case 'forget' when push != null && !_busy:
        unawaited(_forget(push, true));
      case 'resume' when push != null && !_busy:
        unawaited(_forget(push, false));
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final AppServices services = ServicesScope.of(context);
    final Set<PushKind> muted = mutedKinds(services.prefs);
    final PushRegistrar? push = services.push;
    final bool signedIn =
        SessionScope.of(context).status == SessionStatus.signedIn;
    Map<String, Object?> row(
      String key,
      String title,
      String hint,
      bool on, {
      bool locked = false,
    }) => <String, Object?>{
      'key': key,
      'title': title,
      'hint': hint,
      'on': on,
      'locked': locked,
    };
    return <String, Object?>{
      'title': t.privacyTitle,
      'prot': t.privacyProtected,
      'protSub': t.privacyProtectedSub,
      'toggles': <Object?>[
        row(
          'location',
          t.privacyBackground,
          t.privacyBackgroundSub,
          services.tracker.travelMode,
        ),
        row(
          'zones',
          t.privacyGuides,
          t.privacyGuidesSub,
          !muted.containsAll(_guides),
        ),
        row(
          'flights',
          t.privacyDeals,
          t.privacyDealsSub,
          !muted.containsAll(_deals),
        ),
        row(
          'group',
          t.privacyGroup,
          t.privacyGroupSub,
          !muted.containsAll(_group),
        ),
        // Siempre encendido: se ve, pero no se puede tocar.
        row('safety', t.privacySafety, t.privacySafetySub, true, locked: true),
      ],
      'offTxt': 'Ciudades sin conexión',
      'offCount': offlineCount(OfflineLibrary(services.prefs).all().length),
      'pwdTxt': signedIn ? t.passwordChangeTitle : '',
      'knowH': t.privacyWhatWeKnow,
      'know': <String>[
        t.privacyKnow1,
        t.privacyKnow2,
        t.privacyKnow3,
        t.privacyKnow4,
      ],
      'push': push != null,
      'paused': push?.paused ?? false,
      'busy': _busy,
      'forgetTxt': push?.paused ?? false
          ? t.privacyTurnBackOn
          : t.privacyForget,
      'forgetSub': push?.paused ?? false
          ? t.privacyForgotten
          : t.privacyForgetSub,
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final AppServices services = ServicesScope.of(context);
    // El interruptor de la ubicación cambia también desde el Mapa.
    return ListenableBuilder(
      listenable: services.tracker,
      builder: (BuildContext context, _) {
        final Map<String, Object?> data = _data(AppLocalizations.of(context));
        final String push = privacyPushScript(data);
        if (_html == null) {
          _html = privacyPageWith(page, data);
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
                services.webScene?.call(html, _onMessage) ??
                WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
          ),
        );
      },
    );
  }
}
