// "¿Me llega el dinero?" (maqueta "Tu dinero fuera → Gastos").
//
// Eliges un bote, tu límite y los días del viaje. La gráfica enseña lo que
// llevas gastado (TU parte de cada gasto) y hacia dónde vas con tres
// ritmos: seguir igual, gastar un 25 % menos o la mitad. Ver trip_budget.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';
import 'trip_budget.dart';

class BudgetPanel extends StatefulWidget {
  const BudgetPanel({super.key, this.now});

  /// "Hoy" (en los tests, un día fijo).
  final DateTime? now;

  @override
  State<BudgetPanel> createState() => _BudgetPanelState();
}

class _BudgetPanelState extends State<BudgetPanel> {
  late final AppServices _services = ServicesScope.of(context);
  late TripBudget? _budget = TripBudget.load(_services.prefs);
  List<ExpenseGroupSummary>? _pots;
  ExpenseGroup? _pot;
  ApiError? _error;
  bool _editing = false;
  int _pace = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pots == null && _error == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<ExpenseGroupSummary> pots = await _services.expenses.list();
      ExpenseGroup? pot;
      final TripBudget? b = _budget;
      if (b != null && pots.any((ExpenseGroupSummary p) => p.id == b.potId)) {
        pot = await _services.expenses.get(b.potId);
      }
      if (!mounted) return;
      setState(() {
        _pots = pots;
        _pot = pot;
        _error = null;
        _editing = pot == null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  Future<void> _save(TripBudget b) async {
    await b.save(_services.prefs);
    if (!mounted) return;
    setState(() {
      _budget = b;
      _pot = null;
      _pots = null;
    });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final ApiError? error = _error;
    final List<ExpenseGroupSummary>? pots = _pots;
    final ExpenseGroup? pot = _pot;
    final TripBudget? budget = _budget;
    if (error == ApiError.signedOut) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          Text(t.moneySignIn, style: text.bodyLarge),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => context.push(Routes.signIn),
            child: Text(t.signInFromGuest),
          ),
        ],
      );
    }
    if (error != null) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          Text(error == ApiError.network ? t.errorNetwork : t.errorUnavailable),
          TextButton(onPressed: _load, child: Text(t.guideRetry)),
        ],
      );
    }
    if (pots == null) return const Center(child: CircularProgressIndicator());
    if (_editing || pot == null || budget == null) {
      return _BudgetForm(
        pots: pots,
        initial: budget,
        now: widget.now ?? DateTime.now(),
        onSave: _save,
        onCancel: pot == null || budget == null
            ? null
            : () => setState(() => _editing = false),
      );
    }
    return _Forecast(
      pot: pot,
      budget: budget,
      result: forecast(budget, pot, widget.now ?? DateTime.now()),
      pace: _pace,
      onPace: (int i) => setState(() => _pace = i),
      onEdit: () => setState(() => _editing = true),
    );
  }
}

class _BudgetForm extends StatefulWidget {
  const _BudgetForm({
    required this.pots,
    required this.initial,
    required this.now,
    required this.onSave,
    required this.onCancel,
  });

  final List<ExpenseGroupSummary> pots;
  final TripBudget? initial;
  final DateTime now;
  final ValueChanged<TripBudget> onSave;
  final VoidCallback? onCancel;

  @override
  State<_BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends State<_BudgetForm> {
  late String? _potId =
      widget.pots.any((ExpenseGroupSummary p) => p.id == widget.initial?.potId)
      ? widget.initial!.potId
      : widget.pots.isEmpty
      ? null
      : widget.pots.first.id;
  late final TextEditingController _limit = TextEditingController();
  late DateTimeRange _range = widget.initial == null
      ? DateTimeRange(
          start: DateUtils.dateOnly(widget.now),
          end: DateUtils.dateOnly(widget.now).add(const Duration(days: 6)),
        )
      : DateTimeRange(start: widget.initial!.start, end: widget.initial!.end);
  bool _invalid = false;

  String get _currency => widget.pots
      .firstWhere(
        (ExpenseGroupSummary p) => p.id == _potId,
        orElse: () => widget.pots.first,
      )
      .currency;

  @override
  void initState() {
    super.initState();
    final TripBudget? b = widget.initial;
    if (b != null && _potId == b.potId) {
      final int digits = currencyDigits(_currency);
      _limit.text = (b.limitMinor / _pow10(digits)).toStringAsFixed(digits);
    }
  }

  @override
  void dispose() {
    _limit.dispose();
    super.dispose();
  }

  Future<void> _pickDates() async {
    final DateTimeRange? r = await showDateRangePicker(
      context: context,
      initialDateRange: _range,
      firstDate: DateTime(widget.now.year - 1),
      lastDate: DateTime(widget.now.year + 2),
    );
    if (r != null && mounted) setState(() => _range = r);
  }

  void _save() {
    final String? pot = _potId;
    final int? limit = parseAmount(
      _limit.text,
      digits: currencyDigits(_currency),
    );
    if (pot == null || limit == null || limit <= 0) {
      setState(() => _invalid = true);
      return;
    }
    widget.onSave(
      TripBudget(
        potId: pot,
        limitMinor: limit,
        start: _range.start,
        end: _range.end,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final DateFormat day = DateFormat.MMMd(
      Localizations.localeOf(context).toLanguageTag(),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: <Widget>[
        Text(t.abroadBudgetIntro, style: text.bodyLarge),
        const SizedBox(height: 16),
        if (widget.pots.isEmpty) ...<Widget>[
          Text(t.abroadBudgetNoPots),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => context.go(Routes.money()),
            child: Text(t.moneyNewPot),
          ),
        ] else ...<Widget>[
          DropdownButtonFormField<String>(
            initialValue: _potId,
            decoration: InputDecoration(labelText: t.abroadBudgetPot),
            items: <DropdownMenuItem<String>>[
              for (final ExpenseGroupSummary p in widget.pots)
                DropdownMenuItem<String>(
                  value: p.id,
                  child: Text('${p.title} · ${p.currency}'),
                ),
            ],
            onChanged: (String? v) => setState(() => _potId = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _limit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: t.abroadBudgetLimit,
              suffixText: _currency,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDates,
            icon: const Icon(Icons.date_range_rounded),
            label: Text(
              '${day.format(_range.start)} – ${day.format(_range.end)}',
            ),
          ),
          if (_invalid) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              t.abroadBudgetInvalid,
              style: const TextStyle(color: NomadColors.safety),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: Text(t.flightsOriginSave)),
          if (widget.onCancel != null)
            TextButton(
              onPressed: widget.onCancel,
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
        ],
      ],
    );
  }
}

int _pow10(int n) => n <= 0 ? 1 : 10 * _pow10(n - 1);

class _Forecast extends StatelessWidget {
  const _Forecast({
    required this.pot,
    required this.budget,
    required this.result,
    required this.pace,
    required this.onPace,
    required this.onEdit,
  });

  final ExpenseGroup pot;
  final TripBudget budget;
  final BudgetForecast result;
  final int pace;
  final ValueChanged<int> onPace;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final String cur = pot.currency;
    final int end = result.endings[pace];
    final int over = end - budget.limitMinor;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: <Widget>[
        Text(
          t
              .abroadBudgetHeader(
                pot.title,
                result.day,
                result.days,
                money(context, budget.limitMinor, cur),
              )
              .toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1,
            color: NomadColors.textMuted,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          over > 0
              ? t.abroadOver(money(context, over, cur))
              : t.abroadUnder(money(context, -over, cur)),
          style: text.titleLarge?.copyWith(
            color: over > 0 ? NomadColors.safety : NomadColors.mint,
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          label: t.abroadBudgetChart(
            money(context, result.spentMinor, cur),
            money(context, end, cur),
          ),
          child: SizedBox(
            height: 170,
            child: CustomPaint(
              size: Size.infinite,
              painter: _ChartPainter(
                result: result,
                limit: budget.limitMinor,
                end: end,
                overColor: over > 0 ? NomadColors.safety : NomadColors.mint,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: <Widget>[
            Text(t.abroadDayN(1), style: _small),
            const Spacer(),
            Text(t.abroadToday, style: _small),
            const Spacer(),
            Text(t.abroadDayN(result.days), style: _small),
          ],
        ),
        const SizedBox(height: 16),
        Text(t.abroadIfFromToday, style: text.titleMedium),
        const SizedBox(height: 8),
        for (int i = 0; i < budgetPaces.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: i == pace ? const Color(0xFF2A2418) : NomadColors.surface,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => onPace(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: i == pace
                          ? NomadColors.money
                          : NomadColors.outline,
                      width: i == pace ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              switch (i) {
                                0 => t.abroadPaceSame,
                                1 => t.abroadPaceLess,
                                _ => t.abroadPaceHalf,
                              },
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              t.abroadPerDay(
                                money(
                                  context,
                                  (result.perDayMinor * budgetPaces[i]).round(),
                                  cur,
                                ),
                              ),
                              style: _small,
                            ),
                          ],
                        ),
                      ),
                      Text(
                        money(context, result.endings[i], cur),
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: result.endings[i] > budget.limitMinor
                              ? NomadColors.safety
                              : NomadColors.mint,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: onEdit,
          icon: const Icon(Icons.tune_rounded),
          label: Text(t.abroadBudgetEdit),
        ),
      ],
    );
  }
}

const TextStyle _small = TextStyle(fontSize: 12, color: NomadColors.textMuted);

class _ChartPainter extends CustomPainter {
  _ChartPainter({
    required this.result,
    required this.limit,
    required this.end,
    required this.overColor,
  });

  final BudgetForecast result;
  final int limit;
  final int end;
  final Color overColor;

  @override
  void paint(Canvas canvas, Size size) {
    final int top = <int>[
      limit,
      end,
      result.spentMinor,
    ].reduce((int a, int b) => a > b ? a : b);
    final double maxY = top * 1.1;
    final int span = result.days <= 1 ? 1 : result.days - 1;
    double x(int dayIndex) => size.width * dayIndex / span;
    double y(int v) => size.height - size.height * v / maxY;

    // Línea del límite (discontinua).
    final Paint limitPaint = Paint()
      ..color = NomadColors.textMuted
      ..strokeWidth = 1;
    for (double px = 0; px < size.width; px += 10) {
      canvas.drawLine(
        Offset(px, y(limit)),
        Offset(px + 5, y(limit)),
        limitPaint,
      );
    }

    // Lo gastado de verdad (con el área rellena debajo).
    final Path real = Path()..moveTo(x(0), y(result.cumulative.first));
    for (int i = 1; i < result.cumulative.length; i++) {
      real.lineTo(x(i), y(result.cumulative[i]));
    }
    final int today = result.cumulative.length - 1;
    final Path area = Path.from(real)
      ..lineTo(x(today), size.height)
      ..lineTo(x(0), size.height)
      ..close();
    canvas
      ..drawPath(
        area,
        Paint()..color = NomadColors.money.withValues(alpha: 0.18),
      )
      ..drawPath(
        real,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = NomadColors.money,
      );

    // Hacia dónde vas con el ritmo elegido.
    final Offset now = Offset(x(today), y(result.cumulative.last));
    canvas
      ..drawLine(
        now,
        Offset(x(span), y(end)),
        Paint()
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..color = overColor,
      )
      ..drawCircle(now, 6, Paint()..color = NomadColors.text);
  }

  @override
  bool shouldRepaint(_ChartPainter old) =>
      old.result != result || old.limit != limit || old.end != end;
}
