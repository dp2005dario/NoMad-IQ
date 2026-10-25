// Privacidad (maqueta "Privacidad"): qué avisos quieres, la ubicación en
// segundo plano, qué sabemos de ti y "Olvidar este teléfono".
import 'package:flutter/material.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../map/location_tracker.dart';
import '../push/notice_prefs.dart';
import '../push/push_notice.dart';
import '../push/push_registrar.dart';

class PrivacyScreen extends StatefulWidget {
  const PrivacyScreen({super.key});

  @override
  State<PrivacyScreen> createState() => _PrivacyScreenState();
}

class _PrivacyScreenState extends State<PrivacyScreen> {
  bool _busy = false;

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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final AppServices services = ServicesScope.of(context);
    final SettingsStore prefs = services.prefs;
    final Set<PushKind> muted = mutedKinds(prefs);
    final PushRegistrar? push = services.push;

    return Scaffold(
      appBar: AppBar(title: Text(t.privacyTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: <Widget>[
          // El escudo verde: lo que protege a este móvil ahora mismo.
          Card(
            color: NomadColors.mint.withValues(alpha: 0.12),
            child: ListTile(
              leading: const Icon(
                Icons.verified_user_rounded,
                color: NomadColors.mint,
                size: 36,
              ),
              title: Text(t.privacyProtected, style: text.titleMedium),
              subtitle: Text(t.privacyProtectedSub),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: <Widget>[
                ListenableBuilder(
                  listenable: services.tracker,
                  builder: (BuildContext context, _) => SwitchListTile(
                    secondary: const Icon(
                      Icons.my_location_rounded,
                      color: NomadColors.safety,
                    ),
                    title: Text(t.privacyBackground),
                    subtitle: Text(t.privacyBackgroundSub),
                    value: services.tracker.travelMode,
                    onChanged: _travel,
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(
                    Icons.headphones_rounded,
                    color: NomadColors.mint,
                  ),
                  title: Text(t.privacyGuides),
                  subtitle: Text(t.privacyGuidesSub),
                  value: !muted.containsAll(_guides),
                  onChanged: (bool on) => _mute(_guides, on),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(
                    Icons.flight_rounded,
                    color: NomadColors.flights,
                  ),
                  title: Text(t.privacyDeals),
                  subtitle: Text(t.privacyDealsSub),
                  value: !muted.containsAll(_deals),
                  onChanged: (bool on) => _mute(_deals, on),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  secondary: const Icon(
                    Icons.forum_rounded,
                    color: NomadColors.group,
                  ),
                  title: Text(t.privacyGroup),
                  subtitle: Text(t.privacyGroupSub),
                  value: !muted.containsAll(_group),
                  onChanged: (bool on) => _mute(_group, on),
                ),
                const Divider(height: 1),
                // Siempre encendido: se ve, pero no se puede tocar.
                SwitchListTile(
                  secondary: const Icon(
                    Icons.shield_rounded,
                    color: NomadColors.safety,
                  ),
                  title: Text(t.privacySafety),
                  subtitle: Text(t.privacySafetySub),
                  value: true,
                  onChanged: null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
            child: Text(t.privacyWhatWeKnow, style: text.titleMedium),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                children: <Widget>[
                  for (final String line in <String>[
                    t.privacyKnow1,
                    t.privacyKnow2,
                    t.privacyKnow3,
                    t.privacyKnow4,
                  ])
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.check_circle_rounded,
                        color: NomadColors.mint,
                      ),
                      title: Text(line),
                    ),
                ],
              ),
            ),
          ),
          if (push != null) ...<Widget>[
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      push.paused ? t.privacyForgotten : t.privacyForgetSub,
                      style: text.bodyMedium,
                    ),
                    const SizedBox(height: 12),
                    if (push.paused)
                      FilledButton.icon(
                        icon: const Icon(Icons.notifications_active_rounded),
                        label: Text(t.privacyTurnBackOn),
                        onPressed: _busy ? null : () => _forget(push, false),
                      )
                    else
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: NomadColors.safety,
                        ),
                        icon: const Icon(Icons.phonelink_erase_rounded),
                        label: Text(t.privacyForget),
                        onPressed: _busy ? null : () => _forget(push, true),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
