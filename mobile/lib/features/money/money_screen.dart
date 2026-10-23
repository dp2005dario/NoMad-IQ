// Dinero: todo lo que tiene que ver con pagar en un viaje, en una pantalla
// con pestañas arriba (como en la maqueta):
//   - Tu dinero: los botes de gastos compartidos ("¿cuánto le debo a Álex?").
//   - Dinero fuera, Bote común, Habitaciones y Divisas (cada una en su archivo).
//
// Se abre desde el atajo "Gastos" de Inicio (o con /money?tab=...).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';
import 'fx_view.dart';
import 'money_widgets.dart';

/// Las pestañas de Dinero (el nombre va en la dirección: /money?tab=fx).
enum MoneyTab {
  expenses,
  abroad,
  kitty,
  rooms,
  fx;

  String label(AppLocalizations t) => switch (this) {
    MoneyTab.expenses => t.moneyTabExpenses,
    MoneyTab.abroad => t.moneyTabAbroad,
    MoneyTab.kitty => t.moneyTabKitty,
    MoneyTab.rooms => t.moneyTabRooms,
    MoneyTab.fx => t.moneyTabFx,
  };
}

class MoneyScreen extends StatefulWidget {
  const MoneyScreen({super.key, this.tab = MoneyTab.expenses});

  final MoneyTab tab;

  @override
  State<MoneyScreen> createState() => _MoneyScreenState();
}

class _MoneyScreenState extends State<MoneyScreen> {
  late MoneyTab _tab = widget.tab;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.moneyTitle)),
      body: Column(
        children: <Widget>[
          // Las pestañas como "pastillas" que se deslizan de lado (en
          // pantallas estrechas o con letra grande no caben todas).
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: <Widget>[
                for (final MoneyTab tab in MoneyTab.values)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 8),
                    child: ChoiceChip(
                      label: Text(tab.label(t)),
                      selected: tab == _tab,
                      selectedColor: NomadColors.money,
                      labelStyle: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: tab == _tab
                            ? NomadColors.background
                            : NomadColors.text,
                      ),
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _tab = tab),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: switch (_tab) {
              MoneyTab.expenses => const ExpenseGroupsView(),
              MoneyTab.fx => const FxView(),
              _ => _Soon(text: t.moneySoon),
            },
          ),
        ],
      ),
    );
  }
}

class _Soon extends StatelessWidget {
  const _Soon({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(text, textAlign: TextAlign.center),
    ),
  );
}

/// "Tu dinero": tus botes de gastos compartidos.
class ExpenseGroupsView extends StatefulWidget {
  const ExpenseGroupsView({super.key});

  @override
  State<ExpenseGroupsView> createState() => _ExpenseGroupsViewState();
}

class _ExpenseGroupsViewState extends State<ExpenseGroupsView> {
  late final AppServices _services = ServicesScope.of(context);
  List<ExpenseGroupSummary>? _groups;
  ApiError? _error;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_groups == null && _error == null) unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final List<ExpenseGroupSummary> groups = await _services.expenses.list();
      if (mounted) {
        setState(() {
          _groups = groups;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  Future<void> _open(String id) async {
    await context.push(Routes.expenseGroup(id));
    if (mounted) unawaited(_load()); // quizá cambió algo dentro
  }

  Future<void> _create() async {
    final ExpenseGroup? group = await _showPotSheet(context, join: false);
    if (group != null && mounted) await _open(group.id);
  }

  Future<void> _join() async {
    final ExpenseGroup? group = await _showPotSheet(context, join: true);
    if (group != null && mounted) await _open(group.id);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final List<ExpenseGroupSummary>? groups = _groups;
    final ApiError? error = _error;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
        children: <Widget>[
          Text(t.moneyExpensesIntro, style: text.bodyLarge),
          const SizedBox(height: 16),
          if (error == ApiError.signedOut) ...<Widget>[
            Text(t.moneySignIn, style: text.bodyLarge),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => context.push(Routes.signIn),
              child: Text(t.signInFromGuest),
            ),
          ] else ...<Widget>[
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add_rounded),
              label: Text(t.moneyNewPot),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _join,
              icon: const Icon(Icons.vpn_key_rounded),
              label: Text(t.moneyJoinPot),
            ),
            const SizedBox(height: 20),
            if (error != null)
              Column(
                children: <Widget>[
                  Text(
                    error == ApiError.network
                        ? t.errorNetwork
                        : t.errorUnavailable,
                    textAlign: TextAlign.center,
                  ),
                  TextButton(
                    onPressed: () => unawaited(_load()),
                    child: Text(t.guideRetry),
                  ),
                ],
              )
            else if (groups == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (groups.isEmpty)
              Text(
                t.moneyNoPots,
                style: const TextStyle(color: NomadColors.textMuted),
              )
            else
              for (final ExpenseGroupSummary g in groups) ...<Widget>[
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: const Icon(
                      Icons.receipt_long_rounded,
                      color: NomadColors.money,
                    ),
                    title: Text(g.title, style: text.titleMedium),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t.moneyPotMeta(
                            g.members,
                            money(context, g.totalMinor, g.currency),
                          ),
                        ),
                        BalanceText(
                          balanceMinor: g.myBalanceMinor,
                          currency: g.currency,
                        ),
                      ],
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _open(g.id),
                  ),
                ),
                const SizedBox(height: 10),
              ],
          ],
        ],
      ),
    );
  }
}

/// Crear un bote ([join] false) o entrar en uno con código ([join] true).
Future<ExpenseGroup?> _showPotSheet(
  BuildContext context, {
  required bool join,
}) => showModalBottomSheet<ExpenseGroup>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (BuildContext context) => _PotSheet(join: join),
);

class _PotSheet extends StatefulWidget {
  const _PotSheet({required this.join});

  final bool join;

  @override
  State<_PotSheet> createState() => _PotSheetState();
}

class _PotSheetState extends State<_PotSheet> {
  late final AppServices _services = ServicesScope.of(context);
  final TextEditingController _main = TextEditingController();
  late final TextEditingController _name = TextEditingController(
    text: _services.prefs.readGroupName() ?? '',
  );
  String _currency = 'EUR';
  String? _problem;
  String? _nameProblem;
  bool _busy = false;

  @override
  void dispose() {
    _main.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final String main = _main.text.trim();
    final String name = _name.text.trim();
    setState(() {
      _problem = main.isEmpty ? t.groupRequired : null;
      _nameProblem = name.isEmpty ? t.groupRequired : null;
    });
    if (main.isEmpty || name.isEmpty) return;
    setState(() => _busy = true);
    try {
      final ExpenseGroup group = widget.join
          ? await _services.expenses.join(main, myName: name)
          : await _services.expenses.create(
              title: main,
              currency: _currency,
              myName: name,
            );
      await _services.prefs.writeGroupName(name);
      if (mounted) Navigator.of(context).pop(group);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _problem = switch (e.error) {
          ApiError.notFound ||
          ApiError.invalidInput when widget.join => t.groupJoinNotFound,
          ApiError.conflict => t.moneyPotFull,
          ApiError.network => t.errorNetwork,
          ApiError.signedOut => t.moneySignIn,
          _ => t.errorUnavailable,
        };
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            widget.join ? t.moneyJoinPot : t.moneyNewPot,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _main,
            autofocus: true,
            textCapitalization: widget.join
                ? TextCapitalization.characters
                : TextCapitalization.sentences,
            maxLength: widget.join ? 12 : maxGroupTitle,
            decoration: InputDecoration(
              labelText: widget.join ? t.groupJoinCodeLabel : t.moneyPotName,
              hintText: widget.join ? t.groupJoinHint : t.moneyPotNameHint,
              errorText: _problem,
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          if (!widget.join) ...<Widget>[
            DropdownButtonFormField<String>(
              initialValue: _currency,
              decoration: InputDecoration(labelText: t.moneyPotCurrency),
              items: <DropdownMenuItem<String>>[
                for (final String c in potCurrencies)
                  DropdownMenuItem<String>(value: c, child: Text(c)),
              ],
              onChanged: (String? c) => setState(() => _currency = c ?? 'EUR'),
            ),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _name,
            maxLength: maxPersonName,
            decoration: InputDecoration(
              labelText: t.groupYourName,
              helperText: t.moneyYourNameHelp,
              helperMaxLines: 2,
              errorText: _nameProblem,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _send,
            child: _busy
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.join ? t.groupJoinAction : t.moneyCreate),
          ),
        ],
      ),
    );
  }
}
