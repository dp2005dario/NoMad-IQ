// "Saldar con Álex" (maqueta 8): cómo pagarle y, al final, apuntarlo.
//
// Lo que se puede hacer de verdad y gratis:
//   - Bizum: ningún banco deja que otra app rellene un Bizum. Lo cómodo es
//     COPIAR el importe y el concepto y pegarlos en la app de tu banco.
//   - PayPal.me: si la otra persona tiene, el enlace abre PayPal con el
//     importe ya puesto.
//   - Efectivo o cualquier otra forma: solo hay que apuntarlo.
//
// Al final, "Ya le he pagado" apunta el pago en el bote. ECLIPTA no ve tu
// banco: lo apuntas tú.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';

/// Abre la hoja. Devuelve lo que se pagó (en unidades mínimas) o null.
Future<int?> showSettleSheet(
  BuildContext context, {
  required ExpenseGroup group,
  required Payment debt,
}) => showModalBottomSheet<int>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: NomadColors.surface,
  builder: (BuildContext context) => _SettleSheet(group: group, debt: debt),
);

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

class _SettleSheet extends StatefulWidget {
  const _SettleSheet({required this.group, required this.debt});

  final ExpenseGroup group;
  final Payment debt;

  @override
  State<_SettleSheet> createState() => _SettleSheetState();
}

class _SettleSheetState extends State<_SettleSheet> {
  late final AppServices _services = ServicesScope.of(context);
  late final int _digits = currencyDigits(widget.group.currency);
  late final TextEditingController _amount = TextEditingController(
    text: plainAmount(widget.debt.amountMinor, _digits),
  );
  final TextEditingController _paypal = TextEditingController();
  bool _copied = false;

  @override
  void dispose() {
    _amount.dispose();
    _paypal.dispose();
    super.dispose();
  }

  int get _minor =>
      parseAmount(_amount.text, digits: _digits) ?? widget.debt.amountMinor;

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(
        text:
            '${money(context, _minor, widget.group.currency)} · '
            '${widget.group.title}',
      ),
    );
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ExpenseGroup g = widget.group;
    final String name = personName(t, g, widget.debt.toSeat);
    final Uri? paypal = paypalMeLink(_paypal.text, _minor, g.currency);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // Tú → Álex, con el importe grande.
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                SeatAvatar(
                  seat: g.mySeat,
                  name: personName(t, g, g.mySeat),
                  size: 44,
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Icon(
                    Icons.arrow_forward_rounded,
                    color: NomadColors.money,
                  ),
                ),
                SeatAvatar(seat: widget.debt.toSeat, name: name, size: 44),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              t.moneySettleTitle(name),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              money(context, _minor, g.currency),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w900,
                color: NomadColors.money,
              ),
            ),
            const SizedBox(height: 16),
            _Way(
              icon: Icons.phone_iphone_rounded,
              color: NomadColors.flights,
              title: t.settleBizumTitle,
              text: t.settleBizum,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(64, 42),
                ),
                icon: Icon(
                  _copied ? Icons.check_rounded : Icons.copy_rounded,
                  size: 18,
                ),
                label: Text(_copied ? t.settleCopied : t.settleCopy),
                onPressed: () => unawaited(_copy()),
              ),
            ),
            const SizedBox(height: 10),
            _Way(
              icon: Icons.link_rounded,
              color: NomadColors.group,
              title: t.settlePaypalTitle,
              text: t.settlePaypalNote(name),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _paypal,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixText: 'paypal.me/',
                        hintText: t.settlePaypalHint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(64, 42),
                    ),
                    onPressed: paypal == null
                        ? null
                        : () => unawaited(_services.openLink(paypal)),
                    child: Text(t.settlePaypalOpen),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(t.moneySettleHelp),
            const SizedBox(height: 8),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: t.moneyAmount,
                suffixText: g.currency,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(64, 50),
                backgroundColor: NomadColors.money,
                foregroundColor: NomadColors.background,
              ),
              icon: const Icon(Icons.task_alt_rounded),
              label: Text(t.moneySettleConfirm),
              onPressed: () =>
                  Navigator.of(context)
                      .pop(parseAmount(_amount.text, digits: _digits)),
            ),
            const SizedBox(height: 8),
            Text(
              t.settleHonest,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: NomadColors.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Una forma de pagar: icono, título, explicación y su botón.
class _Way extends StatelessWidget {
  const _Way({
    required this.icon,
    required this.color,
    required this.title,
    required this.text,
    required this.child,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String text;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: NomadColors.background,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: color.withValues(alpha: 0.45)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          text,
          style: const TextStyle(color: NomadColors.textMuted, fontSize: 12.5),
        ),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}
