// Bote común y modo pareja: la maqueta "Bote común" tal cual
// (assets/money/bote.html, dentro de un WebView) con tus botes de Gastos.
//
// - Bote del grupo: cada uno pone dinero en una "hucha" (p. ej. 100 € cada
//   uno al empezar el viaje) y los gastos comunes se pagan desde ella (el
//   súper, el tuk-tuk...). Se ve lo que queda, quién ha puesto ya y en qué se
//   ha gastado. "Comprobar el bote" compara lo que hay de verdad con lo
//   apuntado.
// - Modo pareja: dos personas que reparten "a medias", "según sueldo"
//   (60/40) o "lo que toma cada uno" (55/45). Tocar la cara de un gasto
//   cambia quién lo pagó.
//
// ECLIPTA no mueve dinero: solo apunta lo que hacéis. Todo se apoya en los
// mismos botes de Gastos: la hucha es el asiento 0.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/flights_page.dart' show unpackJson;
import '../route/web_scene.dart';
import 'expense_form_screen.dart';
import 'expenses_api.dart';
import 'kitty_page.dart';
import 'receipt_parser.dart';

class KittyView extends StatefulWidget {
  const KittyView({super.key});

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<KittyView> createState() => _KittyViewState();
}

class _KittyViewState extends State<KittyView> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = KittyView.lastBridge = WebSceneBridge();

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;
  String? _html;
  String? _sent;

  List<ExpenseGroupSummary>? _pots;
  ExpenseGroup? _pot;
  ExpenseGroup? _couple;
  ApiError? _error;

  /// Un aviso de Flyra que la página debe enseñar con los datos nuevos.
  Map<String, Object?> _fly = <String, Object?>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pots == null && _error == null) unawaited(_start());
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(kittyPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    await _load();
  }

  Future<void> _load({String? potId}) async {
    try {
      final List<ExpenseGroupSummary> pots = await _services.expenses.list();
      final String? groupId = potId ?? _pot?.id ?? groupPotOf(pots)?.id;
      final String? coupleId = _couple?.id ?? couplePotOf(pots)?.id;
      final ExpenseGroup? pot = groupId == null
          ? null
          : await _services.expenses.get(groupId);
      final ExpenseGroup? couple = coupleId == null
          ? null
          : coupleId == groupId
          ? pot
          : await _services.expenses.get(coupleId);
      if (!mounted) return;
      setState(() {
        _pots = pots;
        _pot = pot;
        _couple = couple;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Hace algo en el servidor y recarga; avisa si falla.
  Future<bool> _run(Future<void> Function() action) async {
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      await action();
      if (!mounted) return true;
      await _load();
      return true;
    } on ApiException catch (e) {
      if (mounted) {
        _say(e.error == ApiError.network ? t.errorNetwork : t.errorUnavailable);
      }
      return false;
    }
  }

  /// Pide un importe (con [initial] ya escrito). null = canceló.
  Future<int?> _askAmount(String title, String currency, int? initial) =>
      showDialog<int>(
        context: context,
        builder: (BuildContext context) =>
            _AmountDialog(title: title, currency: currency, initial: initial),
      );

  Future<void> _put(int minor) async {
    final ExpenseGroup? pot = _pot;
    if (pot == null || minor <= 0) return;
    final bool ok = await _run(
      () =>
          _services.expenses.pay(pot.id, toSeat: kittySeat, amountMinor: minor),
    );
    if (ok && mounted) {
      setState(
        () => _fly = <String, Object?>{
          'fly': 'ok',
          'okAmt': minorToWhole(minor, pot.currency),
        },
      );
    }
  }

  /// Gastar del bote o apuntar un gasto de pareja.
  Future<void> _add(
    ExpenseGroup pot, {
    required String title,
    required int whole,
    required int payer,
  }) async {
    final List<int> seats = <int>[
      for (final ExpenseMember m in pot.members) m.seat,
    ];
    final bool weighted = payer != kittySeat && pot.defaultWeights.isNotEmpty;
    await _run(
      () => _services.expenses.add(
        pot.id,
        NewExpense(
          title: title,
          amountMinor: wholeToMinor(whole, pot.currency),
          payerSeat: payer,
          participants: seats,
          spentOn: DateTime.now(),
          split: weighted ? SplitMode.weights : SplitMode.equal,
          weights: weighted
              ? <int>[for (final int s in seats) pot.defaultWeights[s] ?? 0]
              : const <int>[],
        ),
      ),
    );
  }

  Future<void> _scan(ExpenseGroup pot) async {
    final Expense? added = await Navigator.of(context).push(
      MaterialPageRoute<Expense>(
        builder: (BuildContext context) =>
            ExpenseFormScreen(group: pot, payerSeat: kittySeat),
      ),
    );
    if (added != null && mounted) await _load();
  }

  /// "Comprobar el bote": lo que hay de verdad frente a lo apuntado.
  Future<void> _check(ExpenseGroup pot) async {
    final int? has = await _askAmount(
      '¿Cuánto dinero hay ahora en el bote?',
      pot.currency,
      null,
    );
    if (has == null || !mounted) return;
    final int left = pot.kitty?.leftMinor ?? 0;
    if (has > left) {
      _say(
        'Hay más dinero del apuntado: quizá alguien puso su parte sin apuntarla.',
      );
      return;
    }
    setState(
      () => _fly = <String, Object?>{
        'fly': has == left ? 'fine' : 'err',
        'has': minorToWhole(has, pot.currency),
      },
    );
  }

  /// Cambia quién pagó un gasto de pareja: se borra y se apunta igual con
  /// el otro como pagador (el servidor no deja cambiarlo).
  Future<void> _swap(ExpenseGroup pot, Expense e) async {
    final int other = pot.members
        .firstWhere((ExpenseMember m) => m.seat != e.payerSeat)
        .seat;
    await _run(() async {
      await _services.expenses.add(
        pot.id,
        NewExpense(
          title: e.title,
          amountMinor: e.amountMinor,
          payerSeat: other,
          participants: e.participants,
          spentOn: e.spentOn,
          split: e.split == SplitMode.weights
              ? SplitMode.weights
              : SplitMode.equal,
          weights: e.split == SplitMode.weights ? e.weights : const <int>[],
        ),
      );
      await _services.expenses.delete(pot.id, e.id);
    });
  }

  Future<void> _share(String text) async {
    try {
      await _services.share(const <String>[], text: text);
    } on Object {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _say('Mensaje copiado. Pégalo donde quieras.');
    }
  }

  Future<void> _pickPot() async {
    final List<ExpenseGroupSummary> pots =
        _pots ?? const <ExpenseGroupSummary>[];
    if (pots.length < 2) return;
    final String? id = await showModalBottomSheet<String>(
      context: context,
      useRootNavigator: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final ExpenseGroupSummary p in pots)
              ListTile(
                leading: const Icon(Icons.savings_rounded),
                title: Text(p.title),
                selected: p.id == _pot?.id,
                onTap: () => Navigator.pop(context, p.id),
              ),
          ],
        ),
      ),
    );
    if (id != null && mounted) await _load(potId: id);
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final Map<String, Object?>? data = p.length == 3 ? unpackJson(p[2]) : null;
    final ExpenseGroup? pot = _pot;
    final ExpenseGroup? couple = _couple;
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'put' when pot != null && n != null:
        unawaited(_put(wholeToMinor(n, pot.currency)));
      case 'putask' when pot != null:
        unawaited(
          _askAmount(
            'Poner dinero en el bote',
            pot.currency,
            null,
          ).then((int? v) => v == null ? null : _put(v)),
        );
      case 'remind' when pot != null && n != null:
        final List<Object?> people =
            potJson(pot, DateTime.now())['people']! as List<Object?>;
        if (n >= people.length) return;
        final String name = (people[n]! as Map<String, Object?>)['name']!
            .toString();
        final int? ask = pot.kitty?.askMinor;
        unawaited(
          _share(
            'Hola $name, falta tu parte del bote «${pot.title}»'
            '${ask == null ? '' : ': ${formatMoney(ask, pot.currency, 'es')}'}. '
            'Envíasela a quien guarda el bote y apúntala en ECLIPTA.',
          ),
        );
      case 'spend' when pot != null && data != null:
        unawaited(
          _add(
            pot,
            title: '${data['n'] ?? 'Gasto'}',
            whole: (data['a'] as num?)?.round() ?? 0,
            payer: kittySeat,
          ),
        );
      case 'scan' when pot != null:
        unawaited(_scan(pot));
      case 'more' when pot != null:
        unawaited(
          _run(
            () => _services.expenses.askKitty(
              pot.id,
              (pot.kitty?.askMinor ?? 0) + wholeToMinor(20, pot.currency),
            ),
          ),
        );
      case 'check' when pot != null:
        unawaited(_check(pot));
      case 'pickpot':
        unawaited(_pickPot());
      case 'split' when couple != null && n != null && n < coupleSplits.length:
        final int other = couple.members
            .firstWhere((ExpenseMember x) => !x.me)
            .seat;
        final int mine = coupleSplits[n];
        unawaited(
          _run(
            () => _services.expenses.setWeights(
              couple.id,
              mine == 50
                  ? const <int, int>{}
                  : <int, int>{couple.mySeat: mine, other: 100 - mine},
            ),
          ),
        );
      case 'swap' when couple != null && n != null:
        if (n < couple.expenses.length) {
          unawaited(_swap(couple, couple.expenses[n]));
        }
      case 'settle' when couple != null && n != null:
        final int other = couple.members
            .firstWhere((ExpenseMember x) => !x.me)
            .seat;
        unawaited(
          _run(
            () => _services.expenses.pay(
              couple.id,
              toSeat: other,
              amountMinor: wholeToMinor(n, couple.currency),
            ),
          ),
        );
      case 'askpay' when couple != null && n != null:
        unawaited(
          _share(
            'Para quedar en paz en «${couple.title}» me tienes que enviar '
            '${formatMoney(wholeToMinor(n, couple.currency), couple.currency, 'es')}. '
            'Cuando lo hagas, apúntalo en ECLIPTA.',
          ),
        );
      case 'cadd' when couple != null && data != null:
        final int other = couple.members
            .firstWhere((ExpenseMember x) => !x.me)
            .seat;
        unawaited(
          _add(
            couple,
            title: '${data['n'] ?? 'Gasto'}',
            whole: (data['a'] as num?)?.round() ?? 0,
            payer: data['w'] == 'ot' ? other : couple.mySeat,
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = kittyPageData(
      now: DateTime.now(),
      pot: _pot,
      couple: _couple,
      loading: _pots == null && _error == null,
      signedOut: _error == ApiError.signedOut,
      failed: _error != null && _error != ApiError.signedOut,
      startCouple: _pot == null && _couple != null,
    );
    final Map<String, Object?> fly = _fly;
    final String push = kittyPushScript(<String, Object?>{...data, ...fly});
    if (_html == null) {
      _html = kittyPageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      _fly = <String, Object?>{};
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            _services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }
}

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
