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
//
// Extras de la maqueta: los datos del QR VeriFactu (el total de verdad), el
// descuento del ticket, la propina (no viene en el ticket: se suma encima),
// "Lo que paga cada uno" en vivo y el aviso de Flyra si no cuadra.
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
import 'split_preview.dart';
import 'ticket_widgets.dart';

class ExpenseFormScreen extends StatefulWidget {
  const ExpenseFormScreen({
    super.key,
    required this.group,
    this.receipt,
    this.payerSeat,
    this.split,
  });

  final ExpenseGroup group;

  /// Lo leído del ticket (null = a mano).
  final ParsedReceipt? receipt;

  /// Quién paga al abrir (null = tú; [kittySeat] = el bote común).
  final int? payerSeat;

  /// Cómo se reparte al abrir (null = según haya ticket o no).
  final SplitMode? split;

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
  late int _payer = widget.payerSeat ?? widget.group.mySeat;
  late final Set<int> _participants = <int>{
    for (final ExpenseMember m in widget.group.members) m.seat,
  };
  late SplitMode _split =
      widget.split ?? (_lines.isEmpty ? SplitMode.equal : SplitMode.items);

  /// Los porcentajes de cada uno (modo "con pesos"): el reparto habitual del
  /// bote, o 50 para todos.
  late final Map<int, int> _weights = <int, int>{
    for (final ExpenseMember m in widget.group.members)
      m.seat: widget.group.defaultWeights[m.seat] ?? 50,
  };
  late DateTime _day = _initialDay();

  /// La propina, en % (0 = sin propina).
  int _tip = 0;
  String? _titleProblem;
  String? _amountProblem;
  String? _problem;
  bool _busy = false;

  String _initialAmount() {
    final ParsedReceipt? r = widget.receipt;
    if (r == null) return '';
    final int total = r.trustedTotal ?? r.itemsMinor;
    return total > 0 ? _plain(total, _digits) : '';
  }

  /// El día del ticket si lo trae el QR (y no es del futuro); si no, hoy.
  DateTime _initialDay() {
    final DateTime now = DateTime.now();
    final DateTime? qr = widget.receipt?.veriFactu?.date;
    return qr != null && !qr.isAfter(now) ? qr : now;
  }

  /// Las líneas tal y como están ahora (para calcular lo de cada uno).
  List<TicketItem> _items() => <TicketItem>[
    for (final _Line l in _lines)
      if (l.name.text.trim().isNotEmpty &&
          parseAmount(l.price.text, digits: _digits) != null)
        TicketItem(
          name: l.name.text.trim(),
          qty: l.qty,
          priceMinor: parseAmount(l.price.text, digits: _digits)!,
          claimedBy: <int>[
            for (final int s in l.who)
              if (_participants.contains(s)) s,
          ],
        ),
  ];

  /// Las líneas no suman lo del ticket: la suma, menos el descuento, no da
  /// el total (con 1 céntimo de margen por redondeos).
  bool _mismatch(int? amount, int lines) =>
      _split == SplitMode.items &&
      amount != null &&
      lines > 0 &&
      (lines - (widget.receipt?.discountMinor ?? 0) - amount).abs() > 1;

  /// "Usar la suma": el total pasa a ser lo que suman las líneas.
  void _useLinesSum() => setState(() {
    final int sum = _linesMinor - (widget.receipt?.discountMinor ?? 0);
    _amount.text = _plain(sum > 0 ? sum : _linesMinor, _digits);
  });

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
    final int? ticket = parseAmount(_amount.text, digits: _digits);
    // Lo que se reparte = el ticket + la propina.
    final int? amount = ticket == null ? null : ticket + tipFor(ticket, _tip);
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
          : _split == SplitMode.weights &&
                _participants.any((int s) => (_weights[s] ?? 0) < 1)
          ? t.moneyWeightsInvalid
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
          items: _split == SplitMode.items ? items : const <TicketItem>[],
          weights: <int>[
            for (final int s in _participants.toList()..sort())
              _weights[s] ?? 50,
          ],
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
    final int? ticket = parseAmount(_amount.text, digits: _digits);
    final int tip = ticket == null ? 0 : tipFor(ticket, _tip);
    final int? amount = ticket == null ? null : ticket + tip;
    final int lines = _linesMinor;
    final ParsedReceipt? receipt = widget.receipt;
    final Map<int, int> preview = amount == null || amount <= 0
        ? const <int, int>{}
        : previewShares(
            amountMinor: amount,
            split: _split,
            participants: _participants.toList()..sort(),
            items: _items(),
            weights: <int>[
              for (final int s in _participants.toList()..sort())
                _weights[s] ?? 50,
            ],
          );
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
          if (receipt?.veriFactu != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: VeriFactuCard(
                data: receipt!.veriFactu!,
                onCheck: () =>
                    unawaited(_services.openLink(receipt.veriFactu!.link)),
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
          if ((receipt?.discountMinor ?? 0) > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.local_offer_rounded,
                    size: 18,
                    color: NomadColors.mint,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t.ticketDiscount(
                        money(context, receipt!.discountMinor, group.currency),
                      ),
                      style: const TextStyle(
                        color: NomadColors.textMuted,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          // Propina: no viene en el ticket, se suma encima.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.volunteer_activism_rounded, size: 20),
                    const SizedBox(width: 8),
                    Text(t.tipTitle, style: text.titleSmall),
                  ],
                ),
              ),
              for (final int p in const <int>[0, 5, 10])
                ChoiceChip(
                  label: Text(p == 0 ? t.tipNone : '$p %'),
                  selected: _tip == p,
                  onSelected: (_) => setState(() => _tip = p),
                ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 250),
            child: tip > 0 && amount != null
                ? Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      t.tipAdded(
                        money(context, tip, group.currency),
                        money(context, amount, group.currency),
                      ),
                      style: const TextStyle(
                        color: NomadColors.money,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
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
              // Pagar con la hucha, si el bote la usa.
              if (group.kitty != null || _payer == kittySeat)
                DropdownMenuItem<int>(
                  value: kittySeat,
                  child: Text(t.kittyName),
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
              ButtonSegment<SplitMode>(
                value: SplitMode.weights,
                label: Text(t.moneySplitWeights),
              ),
            ],
            selected: <SplitMode>{_split},
            onSelectionChanged: (Set<SplitMode> s) =>
                setState(() => _split = s.first),
          ),
          if (_split == SplitMode.weights) ...<Widget>[
            const SizedBox(height: 8),
            for (final ExpenseMember m in group.members)
              if (_participants.contains(m.seat))
                Row(
                  children: <Widget>[
                    SeatAvatar(seat: m.seat, name: m.name, size: 28),
                    const SizedBox(width: 8),
                    Expanded(child: Text(personName(t, group, m.seat))),
                    SizedBox(
                      width: 160,
                      child: Slider(
                        value: (_weights[m.seat] ?? 50).toDouble(),
                        min: 1,
                        max: 100,
                        divisions: 99,
                        label: '${_weights[m.seat] ?? 50}',
                        onChanged: (double v) =>
                            setState(() => _weights[m.seat] = v.round()),
                      ),
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${_weights[m.seat] ?? 50}',
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
          ],
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
            if (_mismatch(ticket, lines))
              FlyraMoneyNote(
                title: t.mismatchTitle,
                text: receipt?.veriFactu != null
                    ? t.mismatchQr(
                        money(context, lines, group.currency),
                        money(context, ticket!, group.currency),
                      )
                    : t.mismatchText(
                        money(context, lines, group.currency),
                        money(context, ticket!, group.currency),
                      ),
                actions: <Widget>[
                  if (_lines.length < maxTicketItems)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(64, 40),
                      ),
                      icon: const Icon(Icons.edit_note_rounded, size: 18),
                      label: Text(t.moneyAddLine),
                      onPressed: _addLine,
                    ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(64, 40),
                    ),
                    onPressed: _useLinesSum,
                    child: Text(t.mismatchUseSum),
                  ),
                ],
              ),
          ],
          if (preview.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            Text(t.previewTitle, style: text.titleMedium),
            const SizedBox(height: 6),
            SharesBars(group: group, shares: preview, payerSeat: _payer),
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
