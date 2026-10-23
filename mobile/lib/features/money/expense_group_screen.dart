// Un bote por dentro: quién debe a quién, los gastos apuntados y el botón
// "Añadir gasto" (escaneando el ticket o a mano).
//
// "Saldar" NO mueve dinero: NomadIQ no es un banco. Le pagas a tu amigo como
// siempre (efectivo, Bizum, transferencia...) y aquí apuntas que ya está,
// para que las cuentas cuadren para todos.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../features/group/group_api.dart' show formatInviteCode;
import '../../l10n/generated/app_localizations.dart';
import 'expense_detail_screen.dart';
import 'expense_form_screen.dart';
import 'expenses_api.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';
import 'receipt_scanner.dart';

class ExpenseGroupScreen extends StatefulWidget {
  const ExpenseGroupScreen({super.key, required this.groupId});

  final String groupId;

  @override
  State<ExpenseGroupScreen> createState() => _ExpenseGroupScreenState();
}

class _ExpenseGroupScreenState extends State<ExpenseGroupScreen> {
  late final AppServices _services = ServicesScope.of(context);
  ExpenseGroup? _group;
  ApiError? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_group == null && _error == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final ExpenseGroup group = await _services.expenses.get(widget.groupId);
      if (mounted) {
        setState(() {
          _group = group;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _copyCode(ExpenseGroup group) async {
    await Clipboard.setData(ClipboardData(text: group.inviteCode));
    if (mounted) _say(AppLocalizations.of(context).moneyCodeCopied);
  }

  /// "Añadir gasto": primero se elige cómo (ticket o a mano).
  Future<void> _add(ExpenseGroup group) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final _AddWay? way = await showModalBottomSheet<_AddWay>(
      context: context,
      useRootNavigator: true,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.document_scanner_rounded),
              title: Text(t.moneyScanReceipt),
              subtitle: Text(t.moneyScanPrivacy),
              onTap: () => Navigator.of(context).pop(_AddWay.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(t.moneyReceiptFromGallery),
              onTap: () => Navigator.of(context).pop(_AddWay.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: Text(t.moneyAddByHand),
              onTap: () => Navigator.of(context).pop(_AddWay.byHand),
            ),
          ],
        ),
      ),
    );
    if (!mounted || way == null) return; // cerró la hoja sin elegir
    ParsedReceipt? receipt;
    final ReceiptSource? source = switch (way) {
      _AddWay.camera => ReceiptSource.camera,
      _AddWay.gallery => ReceiptSource.gallery,
      _AddWay.byHand => null,
    };
    if (source != null) {
      final List<String>? rows = await _services.receipts.scan(
        source,
        currency: group.currency,
      );
      if (!mounted || rows == null) return;
      receipt = parseReceipt(rows, digits: currencyDigits(group.currency));
      if (receipt.isEmpty) _say(t.moneyScanNothing);
    }
    final Expense? added = await Navigator.of(context).push(
      MaterialPageRoute<Expense>(
        builder: (BuildContext context) =>
            ExpenseFormScreen(group: group, receipt: receipt),
      ),
    );
    if (added != null && mounted) {
      _say(t.moneyExpenseSaved);
      await _load();
    }
  }

  Future<void> _openExpense(ExpenseGroup group, Expense expense) async {
    final bool? changed = await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (BuildContext context) =>
            ExpenseDetailScreen(group: group, expense: expense),
      ),
    );
    if (changed == true && mounted) await _load();
  }

  /// "Saldar": confirma el importe y apunta el pago.
  Future<void> _settle(ExpenseGroup group, Payment debt) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final int digits = currencyDigits(group.currency);
    final TextEditingController amount = TextEditingController(
      text: (debt.amountMinor / _pow10(digits)).toStringAsFixed(digits),
    );
    final int? minor = await showDialog<int>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.moneySettleTitle(group.nameOf(debt.toSeat))),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.moneySettleHelp),
            const SizedBox(height: 12),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: t.moneyAmount,
                suffixText: group.currency,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context)
                    .pop(parseAmount(amount.text, digits: digits)),
            child: Text(t.moneySettleConfirm),
          ),
        ],
      ),
    );
    amount.dispose();
    if (minor == null || !mounted) return;
    try {
      await _services.expenses.pay(
        group.id,
        toSeat: debt.toSeat,
        amountMinor: minor,
      );
      if (mounted) {
        _say(t.moneySettled);
        await _load();
      }
    } on ApiException catch (e) {
      if (mounted) {
        _say(e.error == ApiError.network ? t.errorNetwork : t.errorUnavailable);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ExpenseGroup? group = _group;
    final ApiError? error = _error;
    return Scaffold(
      appBar: AppBar(
        title: Text(group?.title ?? t.moneyTabExpenses),
        actions: <Widget>[
          if (group != null)
            IconButton(
              tooltip: t.moneyCopyCode,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              onPressed: () => _copyCode(group),
            ),
        ],
      ),
      floatingActionButton: group == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: NomadColors.money,
              foregroundColor: NomadColors.background,
              onPressed: () => _add(group),
              icon: const Icon(Icons.add_rounded),
              label: Text(t.moneyAddExpense),
            ),
      body: group == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          error == ApiError.notFound
                              ? t.moneyPotGone
                              : error == ApiError.network
                              ? t.errorNetwork
                              : t.errorUnavailable,
                          textAlign: TextAlign.center,
                        ),
                        TextButton(
                          onPressed: () => unawaited(_load()),
                          child: Text(t.guideRetry),
                        ),
                      ],
                    ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                children: <Widget>[
                  _MyBalance(
                    group: group,
                    onSettle: (Payment d) => _settle(group, d),
                  ),
                  const SizedBox(height: 12),
                  _InviteCard(group: group, onCopy: () => _copyCode(group)),
                  const SizedBox(height: 20),
                  Text(
                    t.moneyBalances,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  for (final ExpenseMember m in group.members)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: SeatAvatar(seat: m.seat, name: m.name),
                      title: Text(personName(t, group, m.seat)),
                      trailing: Text(
                        signedMoney(
                          context,
                          group.balances[m.seat] ?? 0,
                          group.currency,
                        ),
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: switch (group.balances[m.seat] ?? 0) {
                            > 0 => NomadColors.mint,
                            < 0 => NomadColors.safety,
                            _ => NomadColors.textMuted,
                          },
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    t.moneyExpenses(
                      money(context, group.totalMinor, group.currency),
                    ),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (group.expenses.isEmpty)
                    Text(
                      t.moneyNoExpenses,
                      style: const TextStyle(color: NomadColors.textMuted),
                    ),
                  for (final Expense e in group.expenses)
                    Card(
                      child: ListTile(
                        leading: SeatAvatar(
                          seat: e.payerSeat,
                          name: group.nameOf(e.payerSeat),
                        ),
                        title: Text(e.title),
                        subtitle: Text(
                          t.moneyPaidBy(
                            personName(t, group, e.payerSeat),
                            MaterialLocalizations.of(context)
                                .formatShortDate(e.spentOn),
                          ),
                        ),
                        trailing: Text(
                          money(context, e.amountMinor, group.currency),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        onTap: () => _openExpense(group, e),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// Las tres formas de apuntar un gasto.
enum _AddWay { camera, gallery, byHand }

int _pow10(int n) => n == 0 ? 1 : 10 * _pow10(n - 1);

/// La tarjeta de arriba: "Le debes a Álex 21,50 € [Saldar]" o "Estáis en paz".
class _MyBalance extends StatelessWidget {
  const _MyBalance({required this.group, required this.onSettle});

  final ExpenseGroup group;
  final void Function(Payment debt) onSettle;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<Payment> debts = group.myDebts;
    final int mine = group.myBalance;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2418),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: NomadColors.money.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (debts.isEmpty)
            BalanceText(
              balanceMinor: mine,
              currency: group.currency,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          for (final Payment d in debts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          TextSpan(
                            text: t.moneyYouOweTo(group.nameOf(d.toSeat)),
                          ),
                          const TextSpan(text: ' '),
                          TextSpan(
                            text: money(context, d.amountMinor, group.currency),
                            style: const TextStyle(
                              color: NomadColors.money,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      // En una fila el botón no puede ocupar todo el ancho.
                      minimumSize: const Size(0, 48),
                      backgroundColor: NomadColors.money,
                      foregroundColor: NomadColors.background,
                    ),
                    onPressed: () => onSettle(d),
                    child: Text(t.moneySettle),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.group, required this.onCopy});

  final ExpenseGroup group;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.vpn_key_rounded, color: NomadColors.money),
        title: Text(t.moneyInviteCode),
        subtitle: Text(
          formatInviteCode(group.inviteCode),
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            letterSpacing: 2,
            fontSize: 18,
          ),
        ),
        trailing: IconButton(
          tooltip: t.moneyCopyCode,
          icon: const Icon(Icons.copy_rounded),
          onPressed: onCopy,
        ),
      ),
    );
  }
}
