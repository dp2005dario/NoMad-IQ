// Avisos (maqueta "Avisos"): el historial de lo que te ha llegado, con
// pestañas por tipo. Se lee del móvil; tocar un aviso abre su pantalla.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'notice_log.dart';
import 'push_notice.dart';

/// Las pestañas: qué tipos enseña cada una (null = todos).
enum _Tab { all, zones, flights, safety }

Set<PushKind>? _kindsOf(_Tab tab) => switch (tab) {
  _Tab.all => null,
  _Tab.zones => <PushKind>{PushKind.zoneAudioguide, PushKind.airportArrival},
  _Tab.flights => <PushKind>{PushKind.fareAlert},
  _Tab.safety => <PushKind>{PushKind.zoneSafety},
};

(IconData, Color) glyphOf(PushKind kind) => switch (kind) {
  PushKind.zoneAudioguide => (Icons.headphones_rounded, NomadColors.mint),
  PushKind.airportArrival => (Icons.flight_land_rounded, NomadColors.flights),
  PushKind.zoneSafety => (Icons.warning_amber_rounded, NomadColors.safety),
  PushKind.fareAlert => (Icons.local_offer_rounded, NomadColors.money),
};

class NoticesScreen extends StatefulWidget {
  const NoticesScreen({super.key});

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  late final AppServices _services = ServicesScope.of(context);
  List<NoticeEntry>? _all;
  _Tab _tab = _Tab.all;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    // Los avisos que llegan con la app cerrada se apuntan desde "otro
    // proceso": se vuelve a leer del disco para verlos.
    await _services.prefs.reload();
    if (mounted) setState(() => _all = NoticeLog(_services.prefs).all());
  }

  Future<void> _clear() async {
    await NoticeLog(_services.prefs).clear();
    if (mounted) setState(() => _all = <NoticeEntry>[]);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<NoticeEntry>? all = _all;
    final Set<PushKind>? kinds = _kindsOf(_tab);
    final List<NoticeEntry> shown = <NoticeEntry>[
      for (final NoticeEntry e in all ?? <NoticeEntry>[])
        if (kinds == null || kinds.contains(e.kind)) e,
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(t.noticesTitle),
        actions: <Widget>[
          if (all != null && all.isNotEmpty)
            IconButton(
              tooltip: t.noticesClear,
              onPressed: _clear,
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
        ],
      ),
      body: all == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: <Widget>[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final _Tab tab in _Tab.values)
                      ChoiceChip(
                        label: Text(switch (tab) {
                          _Tab.all => t.noticesAll,
                          _Tab.zones => t.noticesZones,
                          _Tab.flights => t.noticesFlights,
                          _Tab.safety => t.noticesSafety,
                        }),
                        selected: _tab == tab,
                        onSelected: (_) => setState(() => _tab = tab),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text(
                      t.noticesEmpty,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: NomadColors.textMuted),
                    ),
                  ),
                for (final NoticeEntry e in shown) _NoticeTile(entry: e),
                const SizedBox(height: 16),
                Text(
                  t.noticesFooter,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: NomadColors.textMuted),
                ),
              ],
            ),
    );
  }
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile({required this.entry});

  final NoticeEntry entry;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, Color color) = glyphOf(entry.kind);
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final String when = DateFormat.MMMd(locale)
        .add_Hm()
        .format(entry.at.toLocal());
    final String? route = entry.route;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.15),
          foregroundColor: color,
          child: Icon(icon),
        ),
        title: Text(entry.title),
        subtitle: Text('${entry.body}\n$when'),
        isThreeLine: true,
        onTap: route == null ? null : () => context.push(route),
      ),
    );
  }
}
