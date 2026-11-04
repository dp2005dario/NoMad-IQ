// Ayuda (maqueta "Ayuda"): primero Flyra, y si hace falta una persona. Cada
// opción se abre como una tarjeta con lo que hace y un botón. Las de pago o
// con comisión lo dicen claramente. Salen las cinco como en la maqueta; si
// una aún no tiene socio configurado, su botón avisa de que llega pronto.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../core/config.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
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
    this.claims = false,
  });

  final String title;
  final String sub;
  final String tag;
  final String more;
  final String cta;
  final Color color;

  /// El dibujo del icono (el mismo trazo que la maqueta, en SVG).
  final String icon;
  final VoidCallback onTap;

  /// La de reclamaciones sale abierta al entrar (como en la maqueta).
  final bool claims;
}

/// Los iconos de la maqueta (trazos SVG de 24×24).
const String _plane = 'M2 16l20-6-2-3-7 2-5-5-2 1 3 5-5 1.5-2-1.5-1.5.5z';
const String _shield = 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z';
const String _bank = 'M4 21h16 M6 21V10 M18 21V10 M3 10h18L12 3z';
const String _doc = 'M7 3h8l4 4v14H7z M15 3v4h4 M10 13h6';
const String _chat = 'M4 5h16v11H8l-4 4z';

/// Colores exactos de la maqueta.
const Color _card = Color(0xFF141E25);
const Color _line = Color(0xFF26363F);
const Color _muted = Color(0xFF9FB0B8);

class _HelpScreenState extends State<HelpScreen> {
  late final AppServices _services = ServicesScope.of(context);

  /// Qué tarjeta está abierta (solo una a la vez). Hasta que tocas una,
  /// sale abierta la de reclamaciones (o la primera si no está).
  int? _open;
  bool _touched = false;

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

  /// Una opción cuyo socio aún no está configurado: sale igual (como en la
  /// maqueta) y avisa de que llega pronto, sin llevar a un sitio vacío.
  void _soon() => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(AppLocalizations.of(context).helpSoon)),
  );

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
        icon: _plane,
        // Tus billetes y reservas (con el teléfono de la aerolínea).
        onTap: () => unawaited(context.push(Routes.vault)),
      ),
      _Option(
        title: t.helpInsurance,
        sub: t.helpInsuranceSub,
        tag: t.helpTagPolicy,
        more: t.helpInsuranceMore,
        cta: t.helpInsuranceCta,
        color: NomadColors.mint,
        icon: _shield,
        onTap: () => unawaited(context.push(Routes.vault)),
      ),
      _Option(
        title: t.helpClaims,
        sub: t.helpClaimsSub,
        tag: t.helpTagIfWin,
        more: t.helpClaimsMore,
        cta: t.helpClaimsCta,
        color: NomadColors.money,
        icon: _bank,
        claims: true,
        onTap: claims == null
            ? _soon
            : () => unawaited(_services.openLink(claims)),
      ),
      _Option(
        title: t.helpVisa,
        sub: t.helpVisaSub,
        tag: t.helpTagPaid,
        more: t.helpVisaMore,
        cta: t.helpVisaCta,
        color: NomadColors.safety,
        icon: _doc,
        onTap: visa == null ? _soon : () => unawaited(_services.openLink(visa)),
      ),
      _Option(
        title: t.helpSupport,
        sub: t.helpSupportSub,
        tag: t.helpTagFree,
        more: t.helpSupportMore,
        cta: t.helpSupportCta,
        color: NomadColors.group,
        icon: _chat,
        onTap: email == null
            ? _soon
            : () => unawaited(_services.openLink(_supportMail(t, email))),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<_Option> options = _options(t);
    final int open = _touched
        ? (_open ?? -1)
        : options.indexWhere((_Option o) => o.claims).clamp(0, 99);
    return Scaffold(
      body: SafeArea(
        child: ListView(
          // Abajo, sitio para el botón flotante de Flyra.
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 96),
          children: <Widget>[
            Row(
              children: <Widget>[
                Semantics(
                  button: true,
                  label: MaterialLocalizations.of(context).backButtonTooltip,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => unawaited(Navigator.of(context).maybePop()),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _card,
                        shape: BoxShape.circle,
                        border: Border.all(color: _line),
                      ),
                      child: const Icon(Icons.chevron_left_rounded),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        t.helpTitle,
                        style: const TextStyle(
                          fontFamily: NomadFonts.display,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.5,
                        ),
                      ),
                      Text(
                        t.helpSubtitle,
                        style: const TextStyle(fontSize: 12, color: _muted),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // Flyra primero: resuelve casi todo y no hay que esperar a nadie.
            InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => unawaited(context.push(Routes.flyra())),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  gradient: const LinearGradient(
                    begin: Alignment(-0.5, -1),
                    end: Alignment(0.5, 1),
                    colors: <Color>[Color(0xFF13342A), _card],
                    stops: <double>[0, 0.7],
                  ),
                  border: Border.all(color: const Color(0xFF23523F)),
                ),
                child: Row(
                  children: <Widget>[
                    const FlyraAvatar(size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            t.helpAskFlyra,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          Text(
                            t.helpAskFlyraWhy,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFBFE9D6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.chevron_right_rounded,
                      color: NomadColors.mint,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                t.helpPeople.toUpperCase(),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.7,
                  color: _muted,
                ),
              ),
            ),
            for (int i = 0; i < options.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _OptionCard(
                  option: options[i],
                  open: open == i,
                  onToggle: () => setState(() {
                    _touched = true;
                    _open = open == i ? null : i;
                  }),
                ),
              ),
          ],
        ),
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
    return Material(
      color: _card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: open ? o.color : _line, width: open ? 2 : 1),
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
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: o.color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SvgPicture.string(
                      '<svg viewBox="0 0 24 24" fill="none" stroke="#0B1217" '
                      'stroke-width="2.2" stroke-linecap="round" '
                      'stroke-linejoin="round"><path d="${o.icon}"/></svg>',
                      width: 20,
                      height: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          o.title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          o.sub,
                          style: const TextStyle(fontSize: 11, color: _muted),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    height: 24,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 9),
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
                const SizedBox(height: 10),
                Text(
                  o.more,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: Color(0xFFDCE5E9),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 40,
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: o.color,
                      foregroundColor: NomadColors.background,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontFamily: NomadFonts.body,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    onPressed: o.onTap,
                    child: Text(o.cta),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
