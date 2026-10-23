// Un gasto por dentro, con el ticket "impreso" como en la maqueta: cada
// línea con el círculo de quién se la pidió y, abajo, lo que paga cada uno.
//
// Si el gasto se reparte "por lo que tomó cada uno", tocar una línea dice
// "esto me lo pedí yo" (o "ya no"). Cada persona marca SOLO lo suyo desde su
// móvil: nadie puede apuntar platos a otro.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';
import 'money_widgets.dart';

class ExpenseDetailScreen extends StatefulWidget {
  const ExpenseDetailScreen({
    super.key,
    required this.group,
    required this.expense,
  });

  final ExpenseGroup group;
  final Expense expense;

  @override
  State<ExpenseDetailScreen> createState() => _ExpenseDetailScreenState();
}

class _ExpenseDetailScreenState extends State<ExpenseDetailScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late Expense _expense = widget.expense;
  bool _changed = false;
  int? _busyLine;

  ExpenseGroup get _group => widget.group;

  bool get _canDelete =>
      _expense.createdBy == _group.mySeat ||
      _expense.payerSeat == _group.mySeat;

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String _error(AppLocalizations t, ApiError e) =>
      e == ApiError.network ? t.errorNetwork : t.errorUnavailable;

  Future<void> _toggle(int index) async {
    final bool mine = _expense.items[index].claimedBy.contains(_group.mySeat);
    setState(() => _busyLine = index);
    try {
      final Expense updated = await _services.expenses.claim(
        _group.id,
        _expense.id,
        index,
        claimed: !mine,
      );
      if (mounted) {
        setState(() {
          _expense = updated;
          _changed = true;
        });
      }
    } on ApiException catch (e) {
      if (mounted) _say(_error(AppLocalizations.of(context), e.error));
    } finally {
      if (mounted) setState(() => _busyLine = null);
    }
  }

  Future<void> _delete() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t.moneyDeleteTitle),
        content: Text(t.moneyDeleteHelp),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: NomadColors.safety),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t.moneyDelete),
          ),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await _services.expenses.delete(_group.id, _expense.id);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) _say(_error(t, e.error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Expense e = _expense;
    final bool byItems = e.split == SplitMode.items;
    // PopScope: al volver atrás se avisa de si algo cambió (para recargar).
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, bool? result) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(e.title),
          actions: <Widget>[
            if (_canDelete)
              IconButton(
                tooltip: t.moneyDelete,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: _delete,
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: <Widget>[
            Text(
              t.moneyPaidBy(
                personName(t, _group, e.payerSeat),
                MaterialLocalizations.of(context).formatShortDate(e.spentOn),
              ),
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 12),
            if (e.items.isNotEmpty)
              _Ticket(
                group: _group,
                expense: e,
                busyLine: _busyLine,
                onTap: byItems ? _toggle : null,
              ),
            if (byItems) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                t.moneyClaimHelp,
                style: const TextStyle(color: NomadColors.textMuted),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              byItems ? t.moneySplitItems : t.moneySplitEqual,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            for (final MapEntry<int, int> s in e.shares.entries)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: SeatAvatar(seat: s.key, name: _group.nameOf(s.key)),
                title: Text(personName(t, _group, s.key)),
                trailing: Text(
                  money(context, s.value, _group.currency),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            if (e.originalMinor != null &&
                e.originalCurrency != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                t.moneyOriginal(
                  money(context, e.originalMinor!, e.originalCurrency!),
                ),
                style: const TextStyle(color: NomadColors.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// El ticket en papel blanco con letra de máquina, como en la maqueta.
class _Ticket extends StatelessWidget {
  const _Ticket({
    required this.group,
    required this.expense,
    required this.busyLine,
    required this.onTap,
  });

  final ExpenseGroup group;
  final Expense expense;
  final int? busyLine;

  /// null = no se puede marcar (gasto a partes iguales).
  final void Function(int index)? onTap;

  static const TextStyle _ink = TextStyle(
    color: Color(0xFF1E1E1E),
    fontFamily: 'monospace',
    fontSize: 14,
  );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF7F3EA),
        borderRadius: BorderRadius.circular(6),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Colors.black45,
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < expense.items.length; i++)
            InkWell(
              onTap: onTap == null || busyLine != null ? null : () => onTap!(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 28,
                      child: Text('${expense.items[i].qty}', style: _ink),
                    ),
                    Expanded(child: Text(expense.items[i].name, style: _ink)),
                    if (busyLine == i)
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else if (expense.items[i].claimedBy.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: NomadColors.mint,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          t.moneyEveryone,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: NomadColors.background,
                          ),
                        ),
                      )
                    else
                      for (final int s in expense.items[i].claimedBy)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(start: 2),
                          child: SeatAvatar(
                            seat: s,
                            name: personName(t, group, s),
                            size: 22,
                          ),
                        ),
                    const SizedBox(width: 8),
                    Text(
                      money(
                        context,
                        expense.items[i].priceMinor,
                        group.currency,
                      ),
                      style: _ink,
                    ),
                  ],
                ),
              ),
            ),
          const Divider(color: Color(0xFF1E1E1E), thickness: 1),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.moneyTotal,
                  style: _ink.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              Text(
                money(context, expense.amountMinor, group.currency),
                style: _ink.copyWith(fontWeight: FontWeight.w800, fontSize: 16),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
