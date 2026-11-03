// Un gasto por dentro, con el ticket "impreso" como en la maqueta: cada
// línea con el círculo de quién se la pidió y, abajo, lo que paga cada uno.
//
// Si el gasto se reparte "por lo que tomó cada uno", tocar una línea dice
// "esto me lo pedí yo" (o "ya no"). Cada persona marca SOLO lo suyo desde su
// móvil: nadie puede apuntar platos a otro.
//
// Debajo, "Quién ha marcado qué" (lo que ya ha marcado cada uno, con el botón
// de actualizar) y "Repartir con la mesa": mandar el código del bote al
// grupo para que cada uno marque lo suyo.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../features/group/group_api.dart' show formatInviteCode;
import 'expenses_api.dart';
import 'money_widgets.dart';
import 'ticket_widgets.dart';

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
  late ExpenseGroup _group = widget.group;
  bool _changed = false;
  bool _refreshing = false;
  int? _busyLine;

  /// Vuelve a pedir el bote al servidor: así se ve lo que han marcado los
  /// demás desde sus móviles.
  Future<void> _refresh() async {
    setState(() => _refreshing = true);
    try {
      final ExpenseGroup fresh = await _services.expenses.get(_group.id);
      final Expense? again = fresh.expenses
          .where((Expense e) => e.id == _expense.id)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _group = fresh;
        if (again != null) _expense = again;
      });
    } on ApiException catch (e) {
      if (mounted) _say(_error(AppLocalizations.of(context), e.error));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// "Mandar al grupo": el código del bote, para que cada uno marque lo suyo.
  Future<void> _shareTable() async {
    final AppLocalizations t = AppLocalizations.of(context);
    await _services.share(
      const <String>[],
      text: t.tableShareText(
        _expense.title,
        _group.title,
        formatInviteCode(_group.inviteCode),
      ),
    );
  }

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
            IconButton(
              tooltip: t.liveRefresh,
              icon: _refreshing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              onPressed: _refreshing ? null : () => unawaited(_refresh()),
            ),
            if (_canDelete)
              IconButton(
                tooltip: t.moneyDelete,
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: _delete,
              ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
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
              Text(switch (e.split) {
                SplitMode.items => t.moneySplitItems,
                SplitMode.weights => t.moneySplitWeights,
                SplitMode.equal => t.moneySplitEqual,
              }, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              SharesBars(
                group: _group,
                shares: e.shares,
                payerSeat: e.payerSeat,
              ),
              if (byItems) ...<Widget>[
                const SizedBox(height: 20),
                _LiveClaims(group: _group, expense: e),
                const SizedBox(height: 16),
                _TableCard(onShare: () => unawaited(_shareTable())),
              ],
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
      ),
    );
  }
}

/// "Quién ha marcado qué": por persona, los platos que ya ha marcado.
class _LiveClaims extends StatelessWidget {
  const _LiveClaims({required this.group, required this.expense});

  final ExpenseGroup group;
  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: NomadColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.how_to_reg_rounded,
                color: NomadColors.mint,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                t.liveTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: NomadColors.mint,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final int seat in expense.participants)
            Builder(
              builder: (BuildContext context) {
                final List<String> mine = <String>[
                  for (final TicketItem i in expense.items)
                    if (i.claimedBy.contains(seat)) i.name,
                ];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: <Widget>[
                      SeatAvatar(
                        seat: seat,
                        name: personName(t, group, seat),
                        size: 30,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              personName(t, group, seat),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              mine.isEmpty ? t.liveNone : mine.join(', '),
                              style: TextStyle(
                                fontSize: 12.5,
                                color: mine.isEmpty
                                    ? NomadColors.textMuted
                                    : NomadColors.text,
                              ),
                            ),
                          ],
                        ),
                      ),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: mine.isEmpty
                            ? const Icon(
                                Icons.hourglass_empty_rounded,
                                key: ValueKey<bool>(false),
                                size: 18,
                                color: NomadColors.textMuted,
                              )
                            : const Icon(
                                Icons.check_circle_rounded,
                                key: ValueKey<bool>(true),
                                size: 20,
                                color: NomadColors.mint,
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// "Repartir con la mesa": mandar el código del bote al grupo.
class _TableCard extends StatelessWidget {
  const _TableCard({required this.onShare});

  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: <Color>[
            NomadColors.money.withValues(alpha: 0.2),
            NomadColors.surface,
          ],
        ),
        border: Border.all(color: NomadColors.money.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.groups_rounded, color: NomadColors.money),
              const SizedBox(width: 8),
              Text(
                t.tableTitle,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: NomadColors.money,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(t.tableText, style: const TextStyle(height: 1.35)),
          const SizedBox(height: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              minimumSize: const Size(64, 44),
              backgroundColor: NomadColors.money,
              foregroundColor: NomadColors.background,
            ),
            icon: const Icon(Icons.send_rounded, size: 18),
            label: Text(t.tableShare),
            onPressed: onShare,
          ),
        ],
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
    final int adjust =
        expense.amountMinor -
        expense.items.fold(0, (int a, TicketItem i) => a + i.priceMinor);
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
          // Cabecera del ticket: la inicial del local (no hay logo) y el
          // nombre del gasto.
          Row(
            children: <Widget>[
              CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xFF1E1E1E),
                child: Text(
                  expense.title.characters.first.toUpperCase(),
                  style: const TextStyle(
                    color: Color(0xFFF7F3EA),
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  expense.title.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _ink.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          const Divider(color: Color(0xFF1E1E1E), thickness: 0.5),
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
          // Si el total no es la suma de las líneas: propina, pan o un
          // descuento. Se reparte según lo que tomó cada uno.
          if (adjust != 0)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: <Widget>[
                  Expanded(child: Text(t.ticketAdjust, style: _ink)),
                  Text(
                    '${adjust > 0 ? '+' : '−'}'
                    '${money(context, adjust.abs(), group.currency)}',
                    style: _ink,
                  ),
                ],
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
