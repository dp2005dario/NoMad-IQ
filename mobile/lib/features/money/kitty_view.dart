// Bote común y modo pareja (maqueta "Bote común y modo pareja").
//
// - Bote del grupo: cada uno pone dinero en una "hucha" (p. ej. 100 € cada
//   uno al empezar el viaje) y los gastos comunes se pagan desde ella (el
//   súper, el tuk-tuk...). Se ve lo que queda, quién ha puesto ya y en qué se
//   ha gastado. Lo que sobre al final, la hucha lo devuelve.
// - Modo pareja: dos personas que reparten "a medias", "según sueldo"
//   (60/40) o "por plato". El reparto elegido se guarda en el bote y vale
//   para los dos móviles.
//
// Todo se apoya en los mismos botes de Gastos: la hucha es el asiento 0.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expense_form_screen.dart';
import 'expenses_api.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';

class KittyView extends StatefulWidget {
  const KittyView({super.key});

  @override
  State<KittyView> createState() => _KittyViewState();
}

class _KittyViewState extends State<KittyView> {
  late final AppServices _services = ServicesScope.of(context);
  List<ExpenseGroupSummary>? _pots;
  ExpenseGroup? _pot;
  ApiError? _error;
  bool _couple = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pots == null && _error == null) unawaited(_loadPots());
  }

  Future<void> _loadPots() async {
    try {
      final List<ExpenseGroupSummary> pots = await _services.expenses.list();
      if (!mounted) return;
      setState(() => _pots = pots);
      if (pots.isNotEmpty) await _open(pots.first.id);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  Future<void> _open(String id) async {
    try {
      final ExpenseGroup pot = await _services.expenses.get(id);
      if (mounted) {
        setState(() {
          _pot = pot;
          _couple = pot.members.length == 2 && pot.kitty == null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Hace algo en el servidor y recarga el bote; avisa si falla.
  Future<void> _run(Future<void> Function() action, String done) async {
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      await action();
      if (!mounted) return;
      _say(done);
      await _open(_pot!.id);
    } on ApiException catch (e) {
      if (mounted) {
        _say(e.error == ApiError.network ? t.errorNetwork : t.errorUnavailable);
      }
    }
  }

  /// Pide un importe (con [initial] ya escrito). null = canceló.
  /// El diálogo es su propio widget: así el campo de texto se libera cuando
  /// el diálogo termina de cerrarse, no a mitad de la animación.
  Future<int?> _askAmount(String title, String currency, int? initial) =>
      showDialog<int>(
        context: context,
        builder: (BuildContext context) =>
            _AmountDialog(title: title, currency: currency, initial: initial),
      );

  Future<void> _put(ExpenseGroup pot) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final Kitty? k = pot.kitty;
    final int mine = k?.contributed[pot.mySeat] ?? 0;
    final int? amount = await _askAmount(
      t.kittyPut,
      pot.currency,
      k?.askMinor == null || k!.askMinor! <= mine ? null : k.askMinor! - mine,
    );
    if (amount == null || !mounted) return;
    await _run(
      () => _services.expenses.pay(
        pot.id,
        toSeat: kittySeat,
        amountMinor: amount,
      ),
      t.kittyPutDone(money(context, amount, pot.currency)),
    );
  }

  Future<void> _ask(ExpenseGroup pot) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final int? amount = await _askAmount(
      t.kittyAskTitle,
      pot.currency,
      pot.kitty?.askMinor,
    );
    if (amount == null || !mounted) return;
    await _run(
      () => _services.expenses.askKitty(pot.id, amount),
      t.kittyAskDone(money(context, amount, pot.currency)),
    );
  }

  Future<void> _spend(ExpenseGroup pot) async {
    final Expense? added = await Navigator.of(context).push(
      MaterialPageRoute<Expense>(
        builder: (BuildContext context) =>
            ExpenseFormScreen(group: pot, payerSeat: kittySeat),
      ),
    );
    if (added != null && mounted) await _open(pot.id);
  }

  Future<void> _refund(ExpenseGroup pot, int amount) => _run(
    () => _services.expenses.refundFromKitty(pot.id, amount),
    AppLocalizations.of(context).moneyExpenseSaved,
  );

  Future<void> _setRatio(ExpenseGroup pot, int mine) {
    final int other = pot.members.firstWhere((ExpenseMember m) => !m.me).seat;
    return _run(
      () => _services.expenses.setWeights(
        pot.id,
        mine == 50
            ? const <int, int>{}
            : <int, int>{pot.mySeat: mine, other: 100 - mine},
      ),
      AppLocalizations.of(context).kittyRatioSaved,
    );
  }

  Future<void> _addCouple(ExpenseGroup pot) async {
    final Expense? added = await Navigator.of(context).push(
      MaterialPageRoute<Expense>(
        builder: (BuildContext context) => ExpenseFormScreen(
          group: pot,
          split: pot.defaultWeights.isEmpty
              ? SplitMode.equal
              : SplitMode.weights,
        ),
      ),
    );
    if (added != null && mounted) await _open(pot.id);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<ExpenseGroupSummary>? pots = _pots;
    final ExpenseGroup? pot = _pot;
    if (_error == ApiError.signedOut) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t.moneySignIn, textAlign: TextAlign.center),
        ),
      );
    }
    if (pots == null || (pots.isNotEmpty && pot == null)) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Text(
                _error == ApiError.network
                    ? t.errorNetwork
                    : t.errorUnavailable,
              ),
      );
    }
    if (pot == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(t.roomsNeedPot, textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _open(pot.id),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          DropdownButtonFormField<String>(
            initialValue: pot.id,
            decoration: InputDecoration(labelText: t.roomsPot),
            items: <DropdownMenuItem<String>>[
              for (final ExpenseGroupSummary p in pots)
                DropdownMenuItem<String>(value: p.id, child: Text(p.title)),
            ],
            onChanged: (String? id) {
              if (id != null && id != pot.id) unawaited(_open(id));
            },
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            segments: <ButtonSegment<bool>>[
              ButtonSegment<bool>(value: false, label: Text(t.kittyGroup)),
              ButtonSegment<bool>(value: true, label: Text(t.kittyCouple)),
            ],
            selected: <bool>{_couple},
            onSelectionChanged: (Set<bool> s) =>
                setState(() => _couple = s.first),
          ),
          const SizedBox(height: 16),
          if (_couple)
            _CouplePanel(
              pot: pot,
              onRatio: (int mine) => unawaited(_setRatio(pot, mine)),
              onAdd: () => unawaited(_addCouple(pot)),
            )
          else
            _KittyPanel(
              pot: pot,
              onPut: () => unawaited(_put(pot)),
              onAsk: () => unawaited(_ask(pot)),
              onSpend: () => unawaited(_spend(pot)),
              onRefund: (int amount) => unawaited(_refund(pot, amount)),
            ),
        ],
      ),
    );
  }
}

class _KittyPanel extends StatelessWidget {
  const _KittyPanel({
    required this.pot,
    required this.onPut,
    required this.onAsk,
    required this.onSpend,
    required this.onRefund,
  });

  final ExpenseGroup pot;
  final VoidCallback onPut;
  final VoidCallback onAsk;
  final VoidCallback onSpend;
  final ValueChanged<int> onRefund;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final Kitty? k = pot.kitty;
    final int put = k?.putMinor ?? 0;
    final int left = k?.leftMinor ?? 0;
    final double ratio = put <= 0 ? 0 : (left / put).clamp(0, 1).toDouble();
    // Si la hucha tiene que devolverme algo (sobra dinero al final).
    final Payment? refund = pot.transfers
        .where((Payment p) => p.fromSeat == kittySeat && p.toSeat == pot.mySeat)
        .firstOrNull;
    final List<Expense> spends = pot.expenses
        .where((Expense e) => e.fromKitty)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0xFF5A4220)),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFF3A2A12), Color(0xFF1A1A14)],
            ),
          ),
          child: Row(
            children: <Widget>[
              SizedBox.square(
                dimension: 96,
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    SizedBox.square(
                      dimension: 96,
                      child: CircularProgressIndicator(
                        value: ratio,
                        strokeWidth: 11,
                        backgroundColor: const Color(0xFF3A3020),
                        color: NomadColors.money,
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    Text(
                      '${(ratio * 100).round()}%',
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFFFD9A8),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t.kittyHeader(pot.title, pot.members.length),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: NomadColors.money,
                      ),
                    ),
                    Text(
                      money(context, left, pot.currency),
                      style: text.headlineMedium,
                    ),
                    Text(
                      t.kittyMeta(
                        money(context, put, pot.currency),
                        money(context, k?.spentMinor ?? 0, pot.currency),
                      ),
                      style: const TextStyle(color: Color(0xFFD8C6A8)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final ExpenseMember m in pot.members)
              _PersonChip(
                seat: m.seat,
                name: personName(t, pot, m.seat),
                put: k?.contributed[m.seat] ?? 0,
                ask: k?.askMinor,
                currency: pot.currency,
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(t.kittySpends, style: text.titleMedium),
        const SizedBox(height: 8),
        if (spends.isEmpty)
          Text(
            t.kittyNoSpends,
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        for (final Expense e in spends)
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.shopping_bag_rounded,
                color: NomadColors.money,
              ),
              title: Text(e.title),
              subtitle: Text(
                MaterialLocalizations.of(context).formatShortDate(e.spentOn),
              ),
              trailing: Text(
                money(context, e.amountMinor, pot.currency),
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: NomadColors.money,
            foregroundColor: NomadColors.background,
          ),
          onPressed: onPut,
          icon: const Icon(Icons.savings_rounded),
          label: Text(t.kittyPut),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onSpend,
          icon: const Icon(Icons.shopping_cart_rounded),
          label: Text(t.kittySpend),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onAsk,
          icon: const Icon(Icons.campaign_rounded),
          label: Text(
            k?.askMinor == null
                ? t.kittyAsk
                : t.kittyAskAgain(money(context, k!.askMinor!, pot.currency)),
          ),
        ),
        if (refund != null) ...<Widget>[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => onRefund(refund.amountMinor),
            child: Text(
              t.kittyRefund(money(context, refund.amountMinor, pot.currency)),
            ),
          ),
        ],
      ],
    );
  }
}

/// "Ana · 100 € · puesto" (o "pendiente" si aún no llega a lo pedido).
class _PersonChip extends StatelessWidget {
  const _PersonChip({
    required this.seat,
    required this.name,
    required this.put,
    required this.ask,
    required this.currency,
  });

  final int seat;
  final String name;
  final int put;
  final int? ask;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool ok = ask == null ? put > 0 : put >= ask!;
    return Container(
      width: 92,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NomadColors.outline),
      ),
      child: Column(
        children: <Widget>[
          SeatAvatar(seat: seat, name: name, size: 32),
          const SizedBox(height: 4),
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            money(context, put, currency),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          Text(
            ok ? t.kittyDone : t.kittyPending,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: ok ? NomadColors.mint : NomadColors.safety,
            ),
          ),
        ],
      ),
    );
  }
}

class _CouplePanel extends StatelessWidget {
  const _CouplePanel({
    required this.pot,
    required this.onRatio,
    required this.onAdd,
  });

  final ExpenseGroup pot;
  final ValueChanged<int> onRatio;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    if (pot.members.length != 2) {
      return Text(t.kittyCoupleOnlyTwo, textAlign: TextAlign.center);
    }
    final ExpenseMember me = pot.members.firstWhere((ExpenseMember m) => m.me);
    final ExpenseMember other = pot.members.firstWhere(
      (ExpenseMember m) => !m.me,
    );
    final int mine = pot.defaultWeights.isEmpty
        ? 50
        : (100 *
                  (pot.defaultWeights[me.seat] ?? 0) /
                  pot.defaultWeights.values.fold<int>(
                    0,
                    (int a, int b) => a + b,
                  ))
              .round();
    final int balance = pot.myBalance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: const Color(0xFF5A2A44)),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[Color(0xFF3A1A2A), NomadColors.surface],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  SeatAvatar(seat: me.seat, name: me.name, size: 52),
                  const SizedBox(width: 4),
                  SeatAvatar(seat: other.seat, name: other.name, size: 52),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${me.name} · ${other.name} · ${pot.title}',
                textAlign: TextAlign.center,
                style: text.titleLarge,
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Text(
                    '${t.groupYou} $mine%',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: seatColor(me.seat),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      t.kittyHowSplit,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: NomadColors.textMuted),
                    ),
                  ),
                  Text(
                    '${other.name} ${100 - mine}%',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: seatColor(other.seat),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: SizedBox(
                  height: 14,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        flex: mine,
                        child: ColoredBox(color: seatColor(me.seat)),
                      ),
                      Expanded(
                        flex: 100 - mine,
                        child: ColoredBox(color: seatColor(other.seat)),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  ChoiceChip(
                    label: Text(t.kittyHalf),
                    selected: mine == 50,
                    onSelected: (_) => onRatio(50),
                  ),
                  ChoiceChip(
                    label: Text(t.kittyByIncome),
                    selected: mine != 50,
                    onSelected: (_) async {
                      final int? picked = await showDialog<int>(
                        context: context,
                        builder: (BuildContext context) =>
                            _RatioDialog(initial: mine == 50 ? 60 : mine),
                      );
                      if (picked != null) onRatio(picked);
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: _Stat(
                label: t.kittyTogether,
                value: money(context, pot.totalMinor, pot.currency),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _Stat(
                label: t.kittyAccounts,
                value: balance == 0
                    ? t.moneySettled
                    : balance < 0
                    ? t.kittyOwes(
                        t.groupYou,
                        money(context, -balance, pot.currency),
                      )
                    : t.kittyOwes(
                        other.name,
                        money(context, balance, pot.currency),
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
          label: Text(t.moneyAddExpense),
        ),
        const SizedBox(height: 8),
        Text(
          t.kittyCoupleHelp,
          style: const TextStyle(color: NomadColors.textMuted),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: NomadColors.surface,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: NomadColors.outline),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: NomadColors.textMuted),
        ),
        Text(value, style: Theme.of(context).textTheme.titleMedium),
      ],
    ),
  );
}

/// "Según sueldo": elige tu porcentaje con una barra.
class _RatioDialog extends StatefulWidget {
  const _RatioDialog({required this.initial});

  final int initial;

  @override
  State<_RatioDialog> createState() => _RatioDialogState();
}

class _RatioDialogState extends State<_RatioDialog> {
  late int _mine = widget.initial;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.kittyByIncome),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(t.kittyRatioLine(_mine, 100 - _mine)),
          Slider(
            value: _mine.toDouble(),
            min: 10,
            max: 90,
            divisions: 16,
            label: '$_mine%',
            onChanged: (double v) => setState(() => _mine = v.round()),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_mine),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}

/// Pide un importe en la moneda del bote.
class _AmountDialog extends StatefulWidget {
  const _AmountDialog({
    required this.title,
    required this.currency,
    required this.initial,
  });

  final String title;
  final String currency;
  final int? initial;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  late final int _digits = currencyDigits(widget.currency);
  late final TextEditingController _field = TextEditingController(
    text: widget.initial == null || widget.initial! <= 0
        ? ''
        : (widget.initial! / math.pow(10, _digits)).toStringAsFixed(_digits),
  );

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _field,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: t.moneyAmount,
          suffixText: widget.currency,
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context)
                  .pop(parseAmount(_field.text, digits: _digits)),
          child: Text(MaterialLocalizations.of(context).okButtonLabel),
        ),
      ],
    );
  }
}
