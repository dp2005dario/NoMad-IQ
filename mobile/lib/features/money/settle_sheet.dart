// "Saldar con Álex" (maqueta 8): cómo pagarle y, al final, apuntarlo.
//
// Lo que se puede hacer de verdad y gratis:
//   - Bizum: ningún banco deja que otra app rellene un Bizum. Lo cómodo es
//     COPIAR el importe y el concepto y pegarlos en la app de tu banco.
//   - "Abrir Bizum en tu banco": se copia el importe, Flyra deja una
//     notificación con los datos (botones para copiar cada uno) y se abre la
//     app oficial de tu banco (la eliges la primera vez).
//   - "Juntar móviles": la animación de los dos móviles y luego lo mismo.
//   - "Que Álex me lo pida": le mandas un mensaje (WhatsApp, lo que uses)
//     para que te envíe una solicitud de Bizum y tú solo la aceptes.
//   - PayPal.me: si la otra persona tiene, el enlace abre PayPal con el
//     importe ya puesto.
//   - Efectivo o cualquier otra forma: solo hay que apuntarlo.
//
// Al final se apunta el pago en el bote ("Saldado con Álex"). ECLIPTA no ve
// tu banco: lo apuntas tú.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../core/settings.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import 'expenses_api.dart';
import 'gastos_art.dart';
import 'gastos_widgets.dart';
import 'money_widgets.dart';
import 'tap_scene.dart';
import 'ticket_printer.dart' show ticketNumber;

/// Abre la hoja para pagarle [debt] a quien toca. [concept] es lo que se
/// copia como concepto (el nombre del gasto o del bote). [onPay] apunta el
/// pago en el servidor y dice si salió bien. Devuelve true si se saldó.
Future<bool> showSettleSheet(
  BuildContext context, {
  required ExpenseGroup group,
  required Payment debt,
  required String concept,
  required Future<bool> Function(int minor) onPay,
}) async =>
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0xB3030608),
      builder: (BuildContext context) => _SettleSheet(
        group: group,
        debt: debt,
        concept: concept,
        onPay: onPay,
      ),
    ) ??
    false;

/// 4300 con 2 decimales → "43.00" (sin símbolo, con punto).
String plainAmount(int minor, int digits) {
  if (digits == 0) return '$minor';
  final String s = minor.abs().toString().padLeft(digits + 1, '0');
  return '${s.substring(0, s.length - digits)}.${s.substring(s.length - digits)}';
}

/// El enlace de PayPal.me con el importe puesto: paypal.me/ana/43.00EUR.
/// null si el usuario tiene caracteres raros.
Uri? paypalMeLink(String user, int minor, String currency) {
  final String clean = user.trim().replaceFirst(RegExp(r'^@'), '');
  if (!RegExp(r'^[A-Za-z0-9]{1,20}$').hasMatch(clean)) return null;
  return Uri.https(
    'www.paypal.me',
    '/$clean/${plainAmount(minor, currencyDigits(currency))}$currency',
  );
}

/// La hoja de abajo con el fondo y el asa de la maqueta.
class GastosSheet extends StatelessWidget {
  const GastosSheet({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      child: Container(
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: Color(0xFF3A4B56))),
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.4,
            colors: <Color>[Color(0xFF1A2A33), Color(0xFF0C1419)],
            stops: <double>[0, 0.7],
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF33444E),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                for (final Widget c in children) ...<Widget>[
                  const SizedBox(height: 12),
                  c,
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Un botón ancho de la maqueta (relleno o con borde).
class GastosButton extends StatelessWidget {
  const GastosButton({
    super.key,
    required this.label,
    required this.onTap,
    this.height = 44,
    this.background = GastosColors.card,
    this.border = const Color(0xFF2B3D47),
    this.foreground = GastosColors.text,
    this.fontSize = 13,
    this.icon,
  });

  final String label;
  final VoidCallback? onTap;
  final double height;
  final Color background;
  final Color? border;
  final Color foreground;
  final double fontSize;
  final Widget? icon;

  @override
  Widget build(BuildContext context) => Material(
    color: background,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(height >= 48 ? 16 : 14),
      side: border == null ? BorderSide.none : BorderSide(color: border!),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: height),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (icon != null) ...<Widget>[icon!, const SizedBox(width: 8)],
            Flexible(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w800,
                  color: foreground,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

enum _Step { pick, main, copied, req, paypal, tap, done }

/// Los bancos de la lista "¿Desde qué banco haces Bizum?" (sin logos: solo
/// el nombre). El último botón es "Otro banco".
const List<String> bizumBanks = <String>[
  'CaixaBank',
  'BBVA',
  'Santander',
  'Sabadell',
  'ING',
  'Openbank',
];

/// Lo que se guarda cuando eliges "Otro banco".
const String otherBank = 'other';

/// La app oficial de cada banco en Android (su "nombre de paquete"). Tienen
/// que estar también en AndroidManifest.xml (`<queries>`) o Android no deja
/// abrirlas.
const Map<String, List<String>> bankApps = <String, List<String>>{
  'CaixaBank': <String>['es.lacaixa.mobile.android.newwapicon'],
  'BBVA': <String>['com.bbva.bbvacontigo'],
  'Santander': <String>['es.bancosantander.apps'],
  'Sabadell': <String>['net.inverline.bancosabadell.officelocator.android'],
  'ING': <String>['www.ingdirect.nativeframe'],
  'Openbank': <String>['es.openbank.mobile'],
};

/// Abre la app oficial de [bank] si está instalada. true = se abrió.
/// (Sin app, en iPhone o en los tests: false, y se explica qué hacer.)
Future<bool> openBankApp(String bank) async {
  final List<String>? apps = bankApps[bank];
  if (apps == null) return false;
  try {
    return await const MethodChannel('nomadiq/apps')
            .invokeMethod<bool>('open', apps) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}

class _SettleSheet extends StatefulWidget {
  const _SettleSheet({
    required this.group,
    required this.debt,
    required this.concept,
    required this.onPay,
  });

  final ExpenseGroup group;
  final Payment debt;
  final String concept;
  final Future<bool> Function(int minor) onPay;

  @override
  State<_SettleSheet> createState() => _SettleSheetState();
}

class _SettleSheetState extends State<_SettleSheet>
    with SingleTickerProviderStateMixin {
  late final AppServices _services = ServicesScope.of(context);
  final TextEditingController _paypal = TextEditingController();

  /// La escena de "Juntar móviles" (5,6 s).
  late final AnimationController _tap = AnimationController(
    vsync: this,
    duration: tapSceneLength,
  );
  _Step? _step;
  bool _busy = false;
  bool _paypalOpened = false;

  /// Se abrió la app del banco (si no, se explica que la abras tú).
  bool _opened = false;

  /// El banco elegido ("BBVA", [otherBank]) o null si aún no.
  String? _bank;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_step != null) return;
    final String? saved = _services.prefs.readData(LocalData.bizumBank);
    _bank = saved == null || saved.isEmpty ? null : saved;
    // La primera vez se pregunta el banco; luego, directo a pagar.
    _step = _bank == null ? _Step.pick : _Step.main;
  }

  @override
  void dispose() {
    _paypal.dispose();
    _tap.dispose();
    super.dispose();
  }

  int get _minor => widget.debt.amountMinor;

  String get _amount => money(context, _minor, widget.group.currency);

  /// El nombre del banco para los textos ("BBVA" o "tu banco").
  String _bankName(AppLocalizations t) =>
      _bank == null || _bank == otherBank ? t.settleYourBank : _bank!;

  Future<void> _pickBank(String bank) async {
    setState(() {
      _bank = bank;
      _step = _Step.main;
    });
    await _services.prefs.writeData(LocalData.bizumBank, bank);
  }

  /// "Abrir Bizum en tu banco": copia el importe, deja una notificación de
  /// Flyra con los datos y abre la app del banco.
  Future<void> _copyOpen() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String number = ticketNumber(context, _minor, widget.group.currency);
    await Clipboard.setData(ClipboardData(text: number));
    final bool allowed = await _services.notices.requestPermission();
    if (allowed) {
      await _services.notices.showCopyData(
        title: t.notifPayTitle,
        body: '$_amount · ${widget.concept}',
        copies: <(String, String)>[
          (t.notifCopyAmount, number),
          (t.notifCopyConcept, widget.concept),
        ],
      );
    }
    final bool opened = _bank == null ? false : await openBankApp(_bank!);
    if (!mounted) return;
    setState(() {
      _opened = opened;
      _step = _Step.copied;
    });
  }

  Future<void> _ask(String name) async {
    final AppLocalizations t = AppLocalizations.of(context);
    await _services.share(
      const <String>[],
      text: t.settleAskText(name, _amount, widget.concept),
    );
    if (mounted) setState(() => _step = _Step.req);
  }

  /// "Juntar móviles": la escena con vibraciones y, al final, abre el banco.
  Future<void> _joinPhones() async {
    setState(() => _step = _Step.tap);
    _tap.value = 0;
    bool buzz1 = false;
    bool buzz2 = false;
    void listener() {
      final double s = _tap.value * tapSceneLength.inMilliseconds / 1000;
      if (!buzz1 && s >= 0.8) {
        buzz1 = true;
        unawaited(HapticFeedback.mediumImpact());
      }
      if (!buzz2 && s >= 3.95) {
        buzz2 = true;
        unawaited(HapticFeedback.heavyImpact());
      }
    }

    _tap.addListener(listener);
    await _tap.forward().orCancel.catchError((Object _) {});
    _tap.removeListener(listener);
    if (mounted && _step == _Step.tap) await _copyOpen();
  }

  Future<void> _paid() async {
    setState(() => _busy = true);
    final bool ok = await widget.onPay(_minor);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (ok) _step = _Step.done;
    });
  }

  /// La pregunta [question] con "Sí, marcar saldado" y "Todavía no".
  List<Widget> _askPaid(AppLocalizations t, String question, int delay) =>
      <Widget>[
        riseLater(
          delay,
          Text(
            question,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
        ),
        riseLater(
          delay + 1,
          Row(
            children: <Widget>[
              Expanded(
                child: GastosButton(
                  label: t.settleYesPaid,
                  height: 48,
                  fontSize: 14,
                  background: NomadColors.mint,
                  border: null,
                  foreground: const Color(0xFF06281A),
                  onTap: _busy ? null : () => unawaited(_paid()),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GastosButton(
                  label: t.settleNotYet,
                  height: 48,
                  fontSize: 14,
                  background: Colors.transparent,
                  border: const Color(0xFF33444E),
                  foreground: const Color(0xFFDCE5E9),
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ),
            ],
          ),
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ExpenseGroup g = widget.group;
    final String name = personName(t, g, widget.debt.toSeat);
    final Color color = seatColor(widget.debt.toSeat);
    final String bank = _bankName(t);
    final _Step step = _step ?? _Step.main;
    if (step == _Step.done) {
      return GastosSheet(
        children: <Widget>[
          _Settled(name: name),
          GastosButton(
            label: t.settleReady,
            height: 52,
            background: GastosColors.text,
            border: null,
            foreground: NomadColors.background,
            fontSize: 15,
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      );
    }
    if (step == _Step.tap) {
      return AnimatedBuilder(
        animation: _tap,
        builder: (BuildContext context, _) {
          final double s = _tap.value * tapSceneLength.inMilliseconds / 1000;
          return GastosSheet(
            children: <Widget>[
              TapTitle(t: s),
              TapScene(
                t: s,
                otherInitial: name.characters.first.toUpperCase(),
                otherColor: color,
                debtLabel: t.tapDebtWith(name),
                amount: _amount,
                zero: money(context, 0, g.currency),
              ),
              TapOpening(t: s, text: t.tapOpening(bank)),
            ],
          );
        },
      );
    }
    final Uri? paypal = paypalMeLink(_paypal.text, _minor, g.currency);
    Widget row(Widget label, String value) => Container(
      height: 36,
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFF22323B))),
      ),
      child: Row(
        children: <Widget>[
          label,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    const TextStyle labelStyle = TextStyle(
      fontSize: 13,
      color: GastosColors.muted,
    );
    Widget bankButton(String label, String value) => GastosButton(
      label: label,
      height: 40,
      background: GastosColors.card,
      border: const Color(0xFF2B3D47),
      onTap: () => unawaited(_pickBank(value)),
    );
    return GastosSheet(
      children: <Widget>[
        Text(
          t.settleWith(name),
          style: const TextStyle(
            fontFamily: NomadFonts.display,
            fontVariations: <FontVariation>[FontVariation.weight(800)],
            fontSize: 20,
          ),
        ),
        Row(
          children: <Widget>[
            Container(
              width: 52,
              height: 52,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              child: Text(
                name.characters.first.toUpperCase(),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: NomadColors.background,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      _amount,
                      style: const TextStyle(
                        fontFamily: NomadFonts.display,
                        fontVariations: <FontVariation>[
                          FontVariation.weight(800),
                        ],
                        fontSize: 34,
                        height: 1,
                      ),
                    ),
                  ),
                  Text(
                    t.settleToBy(name),
                    style: const TextStyle(
                      fontSize: 12,
                      color: GastosColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        Column(
          children: <Widget>[
            row(Text(t.settleConcept, style: labelStyle), widget.concept),
            row(
              Row(
                children: <Widget>[
                  Text('${t.settleBankLabel} · ', style: labelStyle),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _step = _Step.pick),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        t.settleBankChange,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF9CC4FF),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              bank,
            ),
          ],
        ),
        ...switch (step) {
          _Step.pick => <Widget>[
            Text(
              t.settleBankAsk,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 4.2,
              children: <Widget>[
                for (final String b in bizumBanks) bankButton(b, b),
                bankButton(t.settleBankOther, otherBank),
              ],
            ),
            Text(
              t.settleBankNote,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: GastosColors.muted,
              ),
            ),
          ],
          _Step.main => <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: NomadColors.mint, width: 2),
                    color: NomadColors.background,
                  ),
                  child: const ClipOval(child: FlyraAvatar(size: 40)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: GastosColors.card,
                      border: Border.all(color: const Color(0xFF2B3D47)),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(6),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16),
                      ),
                    ),
                    child: Text(
                      t.settleFlyraOpen(bank),
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: Color(0xFFCFE9DE),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            GastosButton(
              label: t.settleOpenIn(bank),
              height: 52,
              fontSize: 15,
              background: NomadColors.mint,
              border: null,
              foreground: const Color(0xFF06281A),
              icon: const Icon(
                Icons.copy_rounded,
                size: 18,
                color: Color(0xFF06281A),
              ),
              onTap: () => unawaited(_copyOpen()),
            ),
            GastosButton(
              label: t.settleAsk(name),
              background: const Color(0xFF10221C),
              border: const Color(0xFF1F4237),
              foreground: const Color(0xFF9BFFD3),
              onTap: () => unawaited(_ask(name)),
            ),
            GastosButton(
              label: t.settleTapWith(name),
              background: GastosColors.card,
              border: const Color(0xFF2B3D47),
              onTap: () => unawaited(_joinPhones()),
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: GastosButton(
                    label: t.settlePaypalTitle,
                    fontSize: 12.5,
                    background: const Color(0xFF13213A),
                    border: const Color(0xFF2A3E63),
                    foreground: const Color(0xFFCFE0FF),
                    onTap: () => setState(() => _step = _Step.paypal),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: GastosButton(
                    label: t.settleCash,
                    fontSize: 12.5,
                    background: Colors.transparent,
                    border: const Color(0xFF33444E),
                    foreground: const Color(0xFFDCE5E9),
                    onTap: _busy ? null : () => unawaited(_paid()),
                  ),
                ),
              ],
            ),
            GastosButton(
              label: MaterialLocalizations.of(context).cancelButtonLabel,
              height: 36,
              background: Colors.transparent,
              border: null,
              foreground: GastosColors.muted,
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
          _Step.copied => <Widget>[
            _Done(text: t.settleCopiedLine(_amount, widget.concept), delay: 0),
            _Done(text: t.settleNotifLine, delay: 1),
            _Done(
              text: _opened ? t.settleOpeningLine(bank) : t.settleNoApp(bank),
              delay: 2,
            ),
            ..._askPaid(t, t.settleSentBizum(name), 3),
          ],
          _Step.req => <Widget>[
            _InfoBox(
              color: NomadColors.mint,
              title: t.settleReqTitle(name),
              text: t.settleAskedText(_amount),
            ),
            GastosButton(
              label: t.settleOk,
              height: 48,
              background: GastosColors.text,
              border: null,
              foreground: NomadColors.background,
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
          _Step.paypal => <Widget>[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF13213A),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFF2A3E63)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t.settlePaypalOnly(name).toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF9CC4FF),
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: _paypal,
                    onChanged: (_) => setState(() {}),
                    style: const TextStyle(
                      fontFamily: 'Cousine',
                      fontSize: 14,
                      color: GastosColors.text,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixText: 'paypal.me/',
                      prefixStyle: const TextStyle(
                        fontFamily: 'Cousine',
                        fontSize: 14,
                        color: GastosColors.text,
                      ),
                      hintText: t.settlePaypalHint,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t.settlePaypalFees,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFFCFE0FF),
                    ),
                  ),
                ],
              ),
            ),
            GastosButton(
              label: t.settlePaypalOpen,
              height: 48,
              background: paypal == null
                  ? GastosColors.card
                  : const Color(0xFF6CA8FF),
              border: null,
              foreground: paypal == null
                  ? GastosColors.muted
                  : NomadColors.background,
              onTap: paypal == null
                  ? null
                  : () async {
                      await _services.openLink(paypal);
                      if (mounted) setState(() => _paypalOpened = true);
                    },
            ),
            if (_paypalOpened) ..._askPaid(t, t.settleSentQuestion(name), 0),
            GastosButton(
              label: t.settleBack,
              height: 48,
              background: Colors.transparent,
              border: const Color(0xFF33444E),
              onTap: () => setState(() => _step = _Step.main),
            ),
          ],
          _Step.done || _Step.tap => const <Widget>[],
        },
      ],
    );
  }
}

/// Entra con un retraso de [index] × 0,4 s (como en la maqueta).
Widget riseLater(int index, Widget child) => TweenAnimationBuilder<double>(
  tween: Tween<double>(begin: 0, end: 1),
  duration: Duration(milliseconds: 350 + 400 * index),
  builder: (BuildContext context, double v, Widget? c) {
    final double start = (400 * index) / (350 + 400 * index);
    return riseIn(((v - start) / (1 - start)).clamp(0, 1), c!);
  },
  child: child,
);

/// Una línea con su ✓ verde.
class _Done extends StatelessWidget {
  const _Done({required this.text, required this.delay});

  final String text;
  final int delay;

  @override
  Widget build(BuildContext context) => riseLater(
    delay,
    Row(
      children: <Widget>[
        Container(
          width: 22,
          height: 22,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: NomadColors.mint,
          ),
          child: const Icon(
            Icons.check_rounded,
            size: 14,
            color: NomadColors.background,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
      ],
    ),
  );
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({
    required this.color,
    required this.title,
    required this.text,
  });

  final Color color;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF10221C),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF1F4237)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w800,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          text,
          style: const TextStyle(
            fontSize: 12.5,
            height: 1.45,
            color: Color(0xFFCFE9DE),
          ),
        ),
      ],
    ),
  );
}

/// "Saldado con Álex": el ✓ que salta con confeti.
class _Settled extends StatelessWidget {
  const _Settled({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1400),
      builder: (BuildContext context, double v, _) => SizedBox(
        height: 190,
        child: Stack(
          alignment: Alignment.topCenter,
          clipBehavior: Clip.none,
          children: <Widget>[
            // El confeti sale del centro hacia fuera.
            for (int i = 0; i < 34; i++) _Confetti(index: i, progress: v),
            Positioned(
              top: 10,
              child: Transform.scale(
                scale: Curves.elasticOut.transform((v * 1.6).clamp(0, 1)),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: NomadColors.mint,
                    boxShadow: <BoxShadow>[
                      BoxShadow(color: Color(0x803DDC97), blurRadius: 30),
                    ],
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 40,
                    color: Color(0xFF06281A),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 96,
              left: 0,
              right: 0,
              child: Opacity(
                opacity: ((v - 0.2) / 0.3).clamp(0, 1),
                child: Column(
                  children: <Widget>[
                    Text(
                      t.settleDoneTitle(name),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontFamily: NomadFonts.display,
                        fontVariations: <FontVariation>[
                          FontVariation.weight(800),
                        ],
                        fontSize: 22,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t.settleDoneGroup(name),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 13,
                        color: GastosColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Confetti extends StatelessWidget {
  const _Confetti({required this.index, required this.progress});

  final int index;
  final double progress;

  static const List<Color> _colors = <Color>[
    Color(0xFF3DDC97),
    Color(0xFFFFB86B),
    Color(0xFFB69CFF),
    Color(0xFF6CA8FF),
    Color(0xFFFFD25E),
    Color(0xFFFF8A65),
  ];

  @override
  Widget build(BuildContext context) {
    final math.Random r = math.Random(index * 7919);
    final double angle = r.nextDouble() * 2 * math.pi;
    final double far = 70 + r.nextDouble() * 90;
    final double k = Curves.easeOut.transform(progress);
    return Positioned(
      top: 44 + math.sin(angle) * far * k,
      left: 0,
      right: 0,
      child: Transform.translate(
        offset: Offset(math.cos(angle) * far * k, 0),
        child: Center(
          child: Opacity(
            opacity: (1 - progress).clamp(0, 1),
            child: Transform.rotate(
              angle: progress * (r.nextDouble() * 8 - 4),
              child: Container(
                width: 6,
                height: 10,
                decoration: BoxDecoration(
                  color: _colors[index % _colors.length],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
