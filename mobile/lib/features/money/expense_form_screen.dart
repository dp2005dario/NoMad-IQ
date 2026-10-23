// Apuntar un gasto: qué fue, cuánto, quién pagó y entre quiénes se reparte.
//
// Si viene de "Escanear ticket", ya trae las líneas leídas (Croquetas 12,00,
// Vino 14,00...) y el total. Todo se puede corregir antes de guardar: el
// lector del móvil a veces confunde un 8 con un 3.
//
// Dos formas de repartir (como en la maqueta):
//   - "A partes iguales": el total entre los que participan.
//   - "Por lo que tomó cada uno": cada línea para quien se la pidió. Las que
//     nadie marca son "de todos" y se reparten entre todos.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';

class ExpenseFormScreen extends StatefulWidget {
  const ExpenseFormScreen({super.key, required this.group, this.receipt});

  final ExpenseGroup group;

  /// Lo leído del ticket (null = a mano).
  final ParsedReceipt? receipt;

  @override
  State<ExpenseFormScreen> createState() => _ExpenseFormScreenState();
}

/// Una línea del ticket mientras se edita (con sus cajas de texto).
class _Line {
  _Line(TicketItem item, int digits)
    : name = TextEditingController(text: item.name),
      price = TextEditingController(text: _plain(item.priceMinor, digits)),
      qty = item.qty,
      who = <int>{...item.claimedBy};

  final TextEditingController name;
  final TextEditingController price;
  final int qty;
  final Set<int> who;

  void dispose() {
    name.dispose();
    price.dispose();
  }
}

/// 1200 con 2 decimales → "12.00" (lo que se escribe en la caja).
String _plain(int minor, int digits) {
  if (digits == 0) return '$minor';
  int scale = 1;
  for (int i = 0; i < digits; i++) {
    scale *= 10;
  }
  return '${minor ~/ scale}.${(minor % scale).toString().padLeft(digits, '0')}';
}

class _ExpenseFormScreenState extends State<ExpenseFormScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final int _digits = currencyDigits(widget.group.currency);
  final TextEditingController _title = TextEditingController();
  late final TextEditingController _amount = TextEditingController(
    text: _initialAmount(),
  );
  late final List<_Line> _lines = <_Line>[
    for (final TicketItem i in widget.receipt?.items ?? const <TicketItem>[])
      _Line(i, _digits),
  ];
  late int _payer = widget.group.mySeat;
  late final Set<int> _participants = <int>{
    for (final ExpenseMember m in widget.group.members) m.seat,
  };
  late SplitMode _split = _lines.isEmpty ? SplitMode.equal : SplitMode.items;
  DateTime _day = DateTime.now();
  String? _titleProblem;
  String? _amountProblem;
  String? _problem;
  bool _busy = false;

  String _initialAmount() {
    final ParsedReceipt? r = widget.receipt;
    if (r == null) return '';
    final int total = r.totalMinor ?? r.itemsMinor;
    return total > 0 ? _plain(total, _digits) : '';
  }

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    for (final _Line l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  int get _linesMinor => _lines.fold(
    0,
    (int sum, _Line l) =>
        sum + (parseAmount(l.price.text, digits: _digits) ?? 0),
  );

  void _addLine() => setState(
    () => _lines.add(_Line(const TicketItem(name: '', priceMinor: 0), _digits)),
  );

  void _removeLine(int i) => setState(() => _lines.removeAt(i).dispose());

  Future<void> _pickDay() async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(now.year - 2),
      lastDate: now,
    );
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _save() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String title = _title.text.trim();
    final int? amount = parseAmount(_amount.text, digits: _digits);
    final List<TicketItem> items = <TicketItem>[];
    for (final _Line l in _lines) {
      final String name = l.name.text.trim();
      final int? price = parseAmount(l.price.text, digits: _digits);
      if (name.isEmpty || price == null) continue; // líneas a medias, fuera
      items.add(
        TicketItem(
          name: name,
          qty: l.qty,
          priceMinor: price,
          claimedBy: <int>[
            for (final int s in l.who)
              if (_participants.contains(s)) s,
          ],
        ),
      );
    }
    setState(() {
      _titleProblem = title.isEmpty ? t.groupRequired : null;
      _amountProblem = amount == null ? t.moneyAmountInvalid : null;
      _problem = _participants.isEmpty
          ? t.moneyNobody
          : _split == SplitMode.items && items.isEmpty
          ? t.moneyNoLines
          : null;
    });
    if (_titleProblem != null || _amountProblem != null || _problem != null) {
      return;
    }
    setState(() => _busy = true);
    try {
      final Expense saved = await _services.expenses.add(
        widget.group.id,
        NewExpense(
          title: title,
          amountMinor: amount!,
          payerSeat: _payer,
          participants: _participants.toList()..sort(),
          spentOn: _day,
          split: _split,
          items: items,
        ),
      );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = switch (e.error) {
          ApiError.network => t.errorNetwork,
          ApiError.invalidInput => t.moneyCheckFields,
          _ => t.errorUnavailable,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ExpenseGroup group = widget.group;
    final TextTheme text = Theme.of(context).textTheme;
    final int? amount = parseAmount(_amount.text, digits: _digits);
    final int lines = _linesMinor;
    return Scaffold(
      appBar: AppBar(title: Text(t.moneyAddExpense)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          if (widget.receipt != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                t.moneyScannedLines(widget.receipt!.items.length),
                style: const TextStyle(
                  color: NomadColors.money,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          TextField(
            controller: _title,
            autofocus: widget.receipt == null,
            maxLength: maxExpenseTitle,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: t.moneyWhat,
              hintText: t.moneyWhatHint,
              errorText: _titleProblem,
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: t.moneyAmount,
                    suffixText: group.currency,
                    errorText: _amountProblem,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                // En una fila el botón no puede ocupar todo el ancho.
                style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
                onPressed: _pickDay,
                icon: const Icon(Icons.event_rounded),
                label: Text(
                  MaterialLocalizations.of(context).formatShortDate(_day),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<int>(
            initialValue: _payer,
            decoration: InputDecoration(labelText: t.moneyWhoPaid),
            items: <DropdownMenuItem<int>>[
              for (final ExpenseMember m in group.members)
                DropdownMenuItem<int>(
                  value: m.seat,
                  child: Text(personName(t, group, m.seat)),
                ),
            ],
            onChanged: (int? s) => setState(() => _payer = s ?? _payer),
          ),
          const SizedBox(height: 16),
          Text(t.moneyForWhom, style: text.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final ExpenseMember m in group.members)
                FilterChip(
                  avatar: SeatAvatar(seat: m.seat, name: m.name, size: 24),
                  label: Text(personName(t, group, m.seat)),
                  selected: _participants.contains(m.seat),
                  onSelected: (bool on) => setState(
                    () => on
                        ? _participants.add(m.seat)
                        : _participants.remove(m.seat),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          SegmentedButton<SplitMode>(
            segments: <ButtonSegment<SplitMode>>[
              ButtonSegment<SplitMode>(
                value: SplitMode.equal,
                label: Text(t.moneySplitEqual),
              ),
              ButtonSegment<SplitMode>(
                value: SplitMode.items,
                label: Text(t.moneySplitItems),
              ),
            ],
            selected: <SplitMode>{_split},
            onSelectionChanged: (Set<SplitMode> s) =>
                setState(() => _split = s.first),
          ),
          if (_split == SplitMode.items) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              t.moneyItemsHelp,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < _lines.length; i++)
              _LineEditor(
                key: ObjectKey(_lines[i]),
                line: _lines[i],
                group: group,
                participants: _participants,
                onChanged: () => setState(() {}),
                onRemove: () => _removeLine(i),
              ),
            if (_lines.length < maxTicketItems)
              TextButton.icon(
                onPressed: _addLine,
                icon: const Icon(Icons.add_rounded),
                label: Text(t.moneyAddLine),
              ),
            if (amount != null && lines > 0 && lines != amount)
              Text(
                t.moneyLinesMismatch(
                  money(context, lines, group.currency),
                  money(context, amount, group.currency),
                ),
                style: const TextStyle(color: NomadColors.money),
              ),
          ],
          if (_problem != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(_problem!, style: const TextStyle(color: NomadColors.safety)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_save()),
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(t.moneySave),
          ),
        ],
      ),
    );
  }
}

/// Una línea del ticket: nombre, precio y quién se la pidió.
class _LineEditor extends StatelessWidget {
  const _LineEditor({
    super.key,
    required this.line,
    required this.group,
    required this.participants,
    required this.onChanged,
    required this.onRemove,
  });

  final _Line line;
  final ExpenseGroup group;
  final Set<int> participants;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                if (line.qty > 1)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: Text(
                      '${line.qty}×',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: line.name,
                    maxLength: maxItemName,
                    decoration: InputDecoration(
                      hintText: t.moneyLineName,
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: line.price,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      hintText: t.moneyAmount,
                      suffixText: group.currency,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: t.moneyRemoveLine,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: onRemove,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final ExpenseMember m in group.members)
                  if (participants.contains(m.seat))
                    InkResponse(
                      onTap: () {
                        line.who.contains(m.seat)
                            ? line.who.remove(m.seat)
                            : line.who.add(m.seat);
                        onChanged();
                      },
                      child: SeatAvatar(
                        seat: m.seat,
                        name: personName(t, group, m.seat),
                        size: 30,
                        selected: line.who.contains(m.seat),
                      ),
                    ),
                if (line.who.isEmpty)
                  Text(
                    t.moneyEveryone,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
