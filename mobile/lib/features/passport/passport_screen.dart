// Mi pasaporte (maqueta "Pasaporte"): un librito con la tapa de NomadIQ.
// Al abrirlo, una página por país con los sellos de los monumentos que has
// reconocido con la cámara. Cada sello es un "cromo" con su rareza; al
// tocarlo se ve su historia, se puede escuchar y abrir en el mapa.
// Todo sale del móvil: los sellos nunca se mandan a ningún servidor.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/stamps.dart';
import '../home/home_screen.dart' show displayName;
import '../route/flight3d.dart' show CountryCodes;
import '../route/world_data.dart';
import 'passport.dart';

class PassportScreen extends StatefulWidget {
  const PassportScreen({super.key});

  @override
  State<PassportScreen> createState() => _PassportScreenState();
}

class _PassportScreenState extends State<PassportScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final List<Stamp> _stamps = StampBook(_services.prefs).all();
  List<PassportPage>? _pages;
  bool _open = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Los aeropuertos (para saber el país) vienen dentro de la app. Mientras
  /// cargan, o si fallan, los sellos salen todos en "Otros lugares".
  Future<void> _load() async {
    Iterable<Airport> airports = const <Airport>[];
    CountryCodes? codes;
    try {
      airports = (await WorldData.load()).airports.all;
      codes = await CountryCodes.load();
    } on Object {
      // sin datos del mundo: una sola página
    }
    if (!mounted) return;
    setState(() => _pages = pagesOf(_stamps, airports: airports, codes: codes));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<PassportPage> pages = _pages ?? pagesOf(_stamps);
    return Scaffold(
      appBar: AppBar(title: Text(t.passportTitle)),
      body: _stamps.isEmpty
          ? _Empty(onCamera: () => context.go(Routes.camera))
          : AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: _open
                  ? _Pages(
                      key: const ValueKey<String>('pages'),
                      pages: pages,
                      onStamp: _show,
                    )
                  : _Cover(
                      key: const ValueKey<String>('passport-cover'),
                      owner: displayName(SessionScope.of(context).user?.email),
                      onOpen: () => setState(() => _open = true),
                    ),
            ),
    );
  }

  Future<void> _show(Stamp s) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _StampSheet(stamp: s, services: _services),
  );
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onCamera});

  final VoidCallback onCamera;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.approval_rounded,
              size: 64,
              color: NomadColors.textMuted,
            ),
            const SizedBox(height: 16),
            Text(t.passportEmpty, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onCamera,
              icon: const Icon(Icons.photo_camera_rounded),
              label: Text(t.passportOpenCamera),
            ),
          ],
        ),
      ),
    );
  }
}

/// La tapa: azul marino con letras doradas, como un pasaporte de verdad.
class _Cover extends StatelessWidget {
  const _Cover({super.key, required this.owner, required this.onOpen});

  final String? owner;
  final VoidCallback onOpen;

  static const Color _gold = Color(0xFFE9C46A);

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: AspectRatio(
          aspectRatio: 0.7, // las proporciones de un pasaporte
          child: Material(
            color: const Color(0xFF14284B),
            borderRadius: BorderRadius.circular(16),
            elevation: 8,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: <Widget>[
                    const Text(
                      'NOMADIQ',
                      style: TextStyle(
                        color: _gold,
                        letterSpacing: 6,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.public_rounded, color: _gold, size: 96),
                    const SizedBox(height: 16),
                    Text(
                      t.passportCoverTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 20,
                        letterSpacing: 2,
                      ),
                    ),
                    if (owner != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(
                        owner!.toUpperCase(),
                        style: const TextStyle(color: _gold, letterSpacing: 3),
                      ),
                    ],
                    const Spacer(),
                    Text(
                      t.passportTapToOpen,
                      style: const TextStyle(color: NomadColors.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Pages extends StatelessWidget {
  const _Pages({super.key, required this.pages, required this.onStamp});

  final List<PassportPage> pages;
  final ValueChanged<Stamp> onStamp;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final int stamps = pages.fold(
      0,
      (int n, PassportPage p) => n + p.stamps.length,
    );
    final int countries = pages
        .where((PassportPage p) => p.country != null)
        .length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: <Widget>[
        Text(
          '${t.passportStamps(stamps)} · ${t.passportCountries(countries)}',
          style: text.titleMedium?.copyWith(color: NomadColors.mint),
        ),
        for (final PassportPage page in pages) ...<Widget>[
          const SizedBox(height: 20),
          Text(
            page.country == null
                ? t.passportElsewhere
                : '${flagOf(page.country!)}  ${page.cities.join(' · ')}',
            style: text.titleLarge,
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              const double gap = 10;
              final int columns = (box.maxWidth / 160).floor().clamp(2, 6);
              final double width =
                  (box.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: <Widget>[
                  for (final Stamp s in page.stamps)
                    SizedBox(
                      width: width,
                      child: _StampCard(stamp: s, onTap: () => onStamp(s)),
                    ),
                ],
              );
            },
          ),
        ],
        const SizedBox(height: 24),
        Text(
          t.passportHint,
          style: text.bodySmall?.copyWith(color: NomadColors.textMuted),
        ),
      ],
    );
  }
}

Color rarityColor(Rarity r) => switch (r) {
  Rarity.legendary => const Color(0xFFE9C46A), // oro
  Rarity.epic => NomadColors.group, // violeta
  Rarity.rare => NomadColors.flights, // azul
  Rarity.common => NomadColors.textMuted,
};

String rarityLabel(AppLocalizations t, Rarity r) => switch (r) {
  Rarity.legendary => t.passportRarityLegendary,
  Rarity.epic => t.passportRarityEpic,
  Rarity.rare => t.passportRarityRare,
  Rarity.common => t.passportRarityCommon,
};

/// Un cromo: borde del color de su rareza, el nombre y la fecha del sello.
class _StampCard extends StatelessWidget {
  const _StampCard({required this.stamp, required this.onTap});

  final Stamp stamp;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Rarity rarity = rarityOf(stamp.year);
    final Color color = rarityColor(rarity);
    final String day = DateFormat.yMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(stamp.date.toLocal());
    return Material(
      color: NomadColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: color, width: 2),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.approval_rounded, color: color, size: 22),
                  const Spacer(),
                  Text(
                    rarityLabel(t, rarity).toUpperCase(),
                    style: TextStyle(color: color, fontSize: 10),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                stamp.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                day,
                style: const TextStyle(
                  color: NomadColors.textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La ficha de un cromo: historia, escuchar y verlo en el mapa.
class _StampSheet extends StatefulWidget {
  const _StampSheet({required this.stamp, required this.services});

  final Stamp stamp;
  final AppServices services;

  @override
  State<_StampSheet> createState() => _StampSheetState();
}

class _StampSheetState extends State<_StampSheet> {
  bool _speaking = false;

  @override
  void dispose() {
    if (_speaking) unawaited(widget.services.speaker.stop());
    super.dispose();
  }

  Future<void> _listen() async {
    if (_speaking) {
      await widget.services.speaker.stop();
      if (mounted) setState(() => _speaking = false);
      return;
    }
    final Stamp s = widget.stamp;
    setState(() => _speaking = true);
    await widget.services.speaker.speak(
      <String?>[s.name, s.description].whereType<String>().join('. '),
      Localizations.localeOf(context).toLanguageTag(),
    );
    if (mounted) setState(() => _speaking = false);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Stamp s = widget.stamp;
    final Rarity rarity = rarityOf(s.year);
    final String day = DateFormat.yMMMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(s.date.toLocal());
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(s.name, style: text.headlineSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                Chip(
                  avatar: Icon(
                    Icons.auto_awesome_rounded,
                    color: rarityColor(rarity),
                    size: 18,
                  ),
                  label: Text(rarityLabel(t, rarity)),
                ),
                if (s.year != null)
                  Chip(label: Text('${t.cameraBuilt} ${s.year}')),
              ],
            ),
            if (s.description != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(s.description!, style: text.bodyLarge),
            ],
            const SizedBox(height: 12),
            Text(
              t.passportStampedOn(day),
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            Text(
              t.passportRarityWhy,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _listen,
                  icon: Icon(
                    _speaking ? Icons.stop_rounded : Icons.headphones_rounded,
                  ),
                  label: Text(
                    _speaking ? t.cameraStopListening : t.cameraListen,
                  ),
                ),
                if (s.lat != null && s.lon != null)
                  OutlinedButton.icon(
                    onPressed: () =>
                        widget.services.openLink(osmLink(s.lat!, s.lon!)),
                    icon: const Icon(Icons.map_rounded),
                    label: Text(t.passportSeeOnMap),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
