// Ayuda (maqueta "Ayuda"): primero Flyra, y si hace falta una persona. Cada
// opción se abre como una tarjeta con lo que hace y un botón. Las de pago o
// con comisión lo dicen claramente, y las que no tienen contacto configurado
// no salen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'help_contacts.dart';

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

/// Una forma de pedir ayuda: textos, color, icono y qué hace el botón.
class _Option {
  const _Option({
    required this.title,
    required this.sub,
    required this.tag,
    required this.more,
    required this.cta,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  final String title;
  final String sub;
  final String tag;
  final String more;
  final String cta;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;
}

class _HelpScreenState extends State<HelpScreen> {
  late final AppServices _services = ServicesScope.of(context);

  /// Qué tarjeta está abierta (solo una a la vez).
  int? _open = 0;

  /// El correo al equipo, ya con la versión y el idioma para no tener que
  /// contarlo. No lleva nada más del móvil.
  Uri _supportMail(AppLocalizations t, String email) {
    final String language = Localizations.localeOf(context).toLanguageTag();
    // Se monta la "query" a mano con %20 (Uri con queryParameters pondría
    // "+" en los espacios, y muchos programas de correo los dejan como "+").
    String enc(String s) => Uri.encodeComponent(s);
    return Uri.parse(
      'mailto:$email?subject=${enc(t.helpMailSubject)}'
      '&body=${enc(t.helpMailBody(AppConfig.version, language))}',
    );
  }

  List<_Option> _options(AppLocalizations t) {
    final HelpContacts c = _services.help;
    final String? email = c.supportEmail;
    final Uri? claims = c.claimsUrl;
    final Uri? visa = c.visaUrl;
    return <_Option>[
      _Option(
        title: t.helpAirline,
        sub: t.helpAirlineSub,
        tag: t.helpTagFree,
        more: t.helpAirlineMore,
        cta: t.helpAirlineCta,
        color: NomadColors.flights,
        icon: Icons.flight_rounded,
        onTap: () => unawaited(context.push(Routes.papers)),
      ),
      _Option(
        title: t.helpInsurance,
        sub: t.helpInsuranceSub,
        tag: t.helpTagPolicy,
        more: t.helpInsuranceMore,
        cta: t.helpInsuranceCta,
        color: NomadColors.mint,
        icon: Icons.health_and_safety_rounded,
        onTap: () => unawaited(context.push(Routes.vault)),
      ),
      if (claims != null)
        _Option(
          title: t.helpClaims,
          sub: t.helpClaimsSub,
          tag: t.helpTagIfWin,
          more: t.helpClaimsMore,
          cta: t.helpClaimsCta,
          color: NomadColors.money,
          icon: Icons.gavel_rounded,
          onTap: () => unawaited(_services.openLink(claims)),
        ),
      if (visa != null)
        _Option(
          title: t.helpVisa,
          sub: t.helpVisaSub,
          tag: t.helpTagPaid,
          more: t.helpVisaMore,
          cta: t.helpVisaCta,
          color: NomadColors.safety,
          icon: Icons.description_rounded,
          onTap: () => unawaited(_services.openLink(visa)),
        ),
      if (email != null)
        _Option(
          title: t.helpSupport,
          sub: t.helpSupportSub,
          tag: t.helpTagFree,
          more: t.helpSupportMore,
          cta: t.helpSupportCta,
          color: NomadColors.group,
          icon: Icons.mail_rounded,
          onTap: () => unawaited(_services.openLink(_supportMail(t, email))),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<_Option> options = _options(t);
    return Scaffold(
      appBar: AppBar(title: Text(t.helpTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: <Widget>[
          Text(
            t.helpSubtitle,
            style: text.bodyMedium?.copyWith(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 16),
          // Flyra primero: resuelve casi todo y no hay que esperar a nadie.
          Card(
            child: ListTile(
              leading: const CircleAvatar(
                backgroundColor: NomadColors.group,
                child: Icon(
                  Icons.auto_awesome_rounded,
                  color: NomadColors.background,
                ),
              ),
              title: Text(t.helpAskFlyra),
              subtitle: Text(t.helpAskFlyraWhy),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => unawaited(context.push(Routes.flyra())),
            ),
          ),
          const SizedBox(height: 24),
          Text(t.helpPeople, style: text.labelLarge),
          const SizedBox(height: 8),
          for (int i = 0; i < options.length; i++)
            _OptionCard(
              option: options[i],
              open: _open == i,
              onToggle: () => setState(() => _open = _open == i ? null : i),
            ),
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.option,
    required this.open,
    required this.onToggle,
  });

  final _Option option;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final _Option o = option;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: open ? o.color : NomadColors.outline,
          width: open ? 2 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: o.color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(o.icon, color: NomadColors.background),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          o.title,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        Text(
                          o.sub,
                          style: const TextStyle(color: NomadColors.textMuted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: o.color),
                    ),
                    child: Text(
                      o.tag,
                      style: TextStyle(
                        color: o.color,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              if (open) ...<Widget>[
                const SizedBox(height: 12),
                Text(o.more),
                const SizedBox(height: 12),
                FilledButton(onPressed: o.onTap, child: Text(o.cta)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
