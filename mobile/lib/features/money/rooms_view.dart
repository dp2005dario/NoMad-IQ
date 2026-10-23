// Habitaciones justas (maqueta "Habitaciones justas en grupo"): un piso
// para 5 con habitaciones distintas. ¿Quién duerme dónde y cuánto paga?
//
// - Se sortean las camas (nadie puede quejarse de un sorteo).
// - "Según la habitación": cada tipo de habitación tiene un peso (la del
//   balcón 1,4, una doble 1, el sofá cama 0,6). Quien duerme mejor paga un
//   poco más.
// - "Todos igual": el total a partes iguales.
// - "Apuntar en Gastos" lo guarda en un bote como un gasto "por lo que tomó
//   cada uno": cada habitación es una línea y la "toman" quienes duermen ahí.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';

/// Los tipos de habitación: peso (cuánto "vale" dormir ahí) y camas.
enum RoomKind {
  suite(1.4, 2, Icons.king_bed_rounded, NomadColors.group),
  twin(1.0, 2, Icons.bed_rounded, NomadColors.flights),
  single(0.9, 1, Icons.single_bed_rounded, NomadColors.mint),
  sofa(0.6, 1, Icons.weekend_rounded, NomadColors.money);

  const RoomKind(this.weight, this.beds, this.icon, this.color);

  final double weight;
  final int beds;
  final IconData icon;
  final Color color;

  String label(AppLocalizations t) => switch (this) {
    RoomKind.suite => t.roomsSuite,
    RoomKind.twin => t.roomsDouble,
    RoomKind.single => t.roomsSingle,
    RoomKind.sofa => t.roomsSofa,
  };
}

/// Reparte [total] céntimos según [weights] sin perder ni un céntimo
/// (método del resto mayor, como el servidor): 10 € entre 3 = 3,34 + 3,33 + 3,33.
List<int> divideByWeights(int total, List<double> weights) {
  final double sum = weights.fold(0, (double a, double w) => a + w);
  if (weights.isEmpty || sum <= 0) return <int>[for (final _ in weights) 0];
  final List<double> exact = <double>[
    for (final double w in weights) total * w / sum,
  ];
  final List<int> out = <int>[for (final double e in exact) e.floor()];
  int left = total - out.fold(0, (int a, int b) => a + b);
  final List<int> order = List<int>.generate(weights.length, (int i) => i)
    ..sort((int a, int b) => (exact[b] - out[b]).compareTo(exact[a] - out[a]));
  for (final int i in order) {
    if (left <= 0) break;
    out[i]++;
    left--;
  }
  return out;
}

/// Quién duerme en cada habitación: se llenan por orden con la lista de
/// asientos ya barajada. Si hay más gente que camas, sobran al final.
List<List<int>> assignBeds(List<RoomKind> rooms, List<int> shuffledSeats) {
  final List<List<int>> out = <List<int>>[];
  int next = 0;
  for (final RoomKind r in rooms) {
    final int end = math.min(next + r.beds, shuffledSeats.length);
    out.add(shuffledSeats.sublist(next, end));
    next = end;
  }
  return out;
}

class RoomsView extends StatefulWidget {
  const RoomsView({super.key, this.random});

  /// Para los tests: un sorteo que siempre sale igual.
  final math.Random? random;

  @override
  State<RoomsView> createState() => _RoomsViewState();
}

class _RoomsViewState extends State<RoomsView> {
  late final AppServices _services = ServicesScope.of(context);
  late final math.Random _random = widget.random ?? math.Random.secure();
  final TextEditingController _title = TextEditingController();
  final TextEditingController _total = TextEditingController();
  List<ExpenseGroupSummary>? _pots;
  ExpenseGroup? _pot;
  ApiError? _error;
  final List<RoomKind> _rooms = <RoomKind>[
    RoomKind.suite,
    RoomKind.twin,
    RoomKind.sofa,
  ];
  List<int> _order = <int>[];
  bool _fair = true;
  bool _busy = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pots == null && _error == null) unawaited(_loadPots());
  }

  @override
  void dispose() {
    _title.dispose();
    _total.dispose();
    super.dispose();
  }

  Future<void> _loadPots() async {
    try {
      final List<ExpenseGroupSummary> pots = await _services.expenses.list();
      if (!mounted) return;
      setState(() => _pots = pots);
      if (pots.isNotEmpty) await _choose(pots.first.id);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  Future<void> _choose(String id) async {
    try {
      final ExpenseGroup pot = await _services.expenses.get(id);
      if (!mounted) return;
      setState(() {
        _pot = pot;
        _order = <int>[for (final ExpenseMember m in pot.members) m.seat];
        _shuffle();
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  void _shuffle() => _order.shuffle(_random);

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Cada habitación con sus ocupantes y lo que paga CADA uno.
  List<({RoomKind kind, List<int> who, int each})> _plan(int total) {
    final List<List<int>> beds = assignBeds(_rooms, _order);
    final List<double> weights = <double>[
      for (int r = 0; r < _rooms.length; r++)
        for (final int _ in beds[r]) _fair ? _rooms[r].weight : 1,
    ];
    final List<int> shares = divideByWeights(total, weights);
    int k = 0;
    return <({RoomKind kind, List<int> who, int each})>[
      for (int r = 0; r < _rooms.length; r++)
        (
          kind: _rooms[r],
          who: beds[r],
          each: beds[r].isEmpty ? 0 : shares[(k += beds[r].length) - 1],
        ),
    ];
  }

  Future<void> _save(ExpenseGroup pot, int total) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String title = _title.text.trim().isEmpty
        ? t.roomsDefaultTitle
        : _title.text.trim();
    final List<List<int>> beds = assignBeds(_rooms, _order);
    final List<double> weights = <double>[
      for (int r = 0; r < _rooms.length; r++)
        for (final int _ in beds[r]) _fair ? _rooms[r].weight : 1,
    ];
    final List<int> shares = divideByWeights(total, weights);
    final List<TicketItem> items = <TicketItem>[];
    int k = 0;
    for (int r = 0; r < _rooms.length; r++) {
      if (beds[r].isEmpty) continue;
      int price = 0;
      for (int i = 0; i < beds[r].length; i++) {
        price += shares[k++];
      }
      items.add(
        TicketItem(
          name: _rooms[r].label(t),
          priceMinor: price,
          claimedBy: beds[r],
        ),
      );
    }
    setState(() => _busy = true);
    try {
      await _services.expenses.add(
        pot.id,
        NewExpense(
          title: title,
          amountMinor: total,
          payerSeat: pot.mySeat,
          participants: <int>[for (final List<int> b in beds) ...b]..sort(),
          spentOn: DateTime.now(),
          split: SplitMode.items,
          items: items,
        ),
      );
      if (mounted) _say(t.roomsSaved(pot.title));
    } on ApiException catch (e) {
      if (mounted) {
        _say(e.error == ApiError.network ? t.errorNetwork : t.errorUnavailable);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
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
    final String currency = pot.currency;
    final int? total = parseAmount(
      _total.text,
      digits: currencyDigits(currency),
    );
    final int beds = _rooms.fold(0, (int a, RoomKind r) => a + r.beds);
    final List<({RoomKind kind, List<int> who, int each})> plan = _plan(
      total ?? 0,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: <Widget>[
        Text(t.roomsIntro, style: text.bodyLarge),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: pot.id,
          decoration: InputDecoration(labelText: t.roomsPot),
          items: <DropdownMenuItem<String>>[
            for (final ExpenseGroupSummary p in pots)
              DropdownMenuItem<String>(value: p.id, child: Text(p.title)),
          ],
          onChanged: (String? id) {
            if (id != null && id != pot.id) unawaited(_choose(id));
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _title,
          maxLength: maxExpenseTitle,
          decoration: InputDecoration(
            labelText: t.roomsPlace,
            hintText: t.roomsPlaceHint,
            counterText: '',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _total,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: t.roomsTotal,
            suffixText: currency,
          ),
        ),
        const SizedBox(height: 16),
        SegmentedButton<bool>(
          segments: <ButtonSegment<bool>>[
            ButtonSegment<bool>(value: true, label: Text(t.roomsFair)),
            ButtonSegment<bool>(value: false, label: Text(t.roomsEqual)),
          ],
          selected: <bool>{_fair},
          onSelectionChanged: (Set<bool> s) => setState(() => _fair = s.first),
        ),
        const SizedBox(height: 12),
        for (int r = 0; r < plan.length; r++)
          Card(
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
                          color: plan[r].kind.color,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          plan[r].kind.icon,
                          color: NomadColors.background,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          plan[r].kind.label(t),
                          style: text.titleMedium,
                        ),
                      ),
                      if (total != null && plan[r].who.isNotEmpty)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: <Widget>[
                            Text(
                              money(context, plan[r].each, currency),
                              style: text.titleMedium,
                            ),
                            Text(
                              t.roomsEach,
                              style: const TextStyle(
                                fontSize: 11,
                                color: NomadColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      IconButton(
                        tooltip: t.roomsRemove,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: _rooms.length <= 1
                            ? null
                            : () => setState(() => _rooms.removeAt(r)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final int seat in plan[r].who)
                        Chip(
                          avatar: SeatAvatar(
                            seat: seat,
                            name: pot.nameOf(seat),
                            size: 24,
                          ),
                          label: Text(personName(t, pot, seat)),
                        ),
                      if (plan[r].who.isEmpty)
                        Text(
                          t.roomsEmpty,
                          style: const TextStyle(color: NomadColors.textMuted),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        Wrap(
          spacing: 8,
          children: <Widget>[
            for (final RoomKind k in RoomKind.values)
              ActionChip(
                avatar: Icon(k.icon, size: 18),
                label: Text('+ ${k.label(t)}'),
                onPressed: _rooms.length >= 10
                    ? null
                    : () => setState(() => _rooms.add(k)),
              ),
          ],
        ),
        if (_order.length > beds) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            t.roomsNotEnoughBeds(_order.length - beds),
            style: const TextStyle(color: NomadColors.safety),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          _fair ? t.roomsHowFair : t.roomsHowEqual,
          style: const TextStyle(color: NomadColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => setState(_shuffle),
                icon: const Icon(Icons.casino_rounded),
                label: Text(t.roomsShuffle),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: total == null || _busy
                    ? null
                    : () => unawaited(_save(pot, total)),
                child: Text(t.roomsSave),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
