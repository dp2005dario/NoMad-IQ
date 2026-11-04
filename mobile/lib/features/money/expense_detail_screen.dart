// Un gasto por dentro, IGUAL que la maqueta 8 ("Gastos"):
//
//   - Arriba: volver, la inicial del local, el nombre del gasto, quién pagó
//     y tu cara con su anillo de colores.
//   - "TU DINERO": Dinero fuera, Bote común y Divisas.
//   - El datáfono que imprime el ticket (si el gasto tiene líneas), con
//     "Volver a imprimir" y "Escanear QR del ticket".
//   - "A partes iguales" / "Por lo que tomó cada uno". En el segundo, cada
//     plato con su dibujo y un circulito por persona: tocas quién lo tomó.
//     Debajo, los extras: pan y cubierto, descuento y propina.
//   - Una tarjeta por persona con lo que le toca y, al final, "Le debes a
//     Álex" con el botón "Saldar".
//
// Cualquiera que esté en el gasto puede cambiar el reparto: se guarda en el
// servidor al momento y los demás lo ven al actualizar.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/motion.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';
import 'gastos_art.dart';
import 'gastos_sheets.dart';
import 'gastos_widgets.dart';
import 'money_screen.dart' show MoneyTab;
import 'money_widgets.dart';
import 'receipt_parser.dart';
import 'receipt_scanner.dart';
import 'settle_sheet.dart';
import 'split_preview.dart';
import 'ticket_printer.dart';

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

class _ExpenseDetailScreenState extends State<ExpenseDetailScreen>
    with TickerProviderStateMixin {
  late final AppServices _services = ServicesScope.of(context);
  late Expense _expense = widget.expense;
  late ExpenseGroup _group = widget.group;
  bool _changed = false;

  /// El reparto mientras lo cambias (se guarda en el servidor al momento).
  late SplitMode _split = _expense.split;
  late List<List<int>> _owners = _ownersOf(_expense);
  late int _cover = _expense.coverMinor;
  late int _discount = _expense.discountMinor;
  late int _tip = _expense.tipPct;

  /// Cada cambio lleva un número: si llegan respuestas viejas, se ignoran.
  int _round = 0;

  /// El QR de Hacienda, si lo has escaneado aquí.
  VeriFactu? _qr;
  bool _alert = false;

  /// El reloj del ticket (se vuelve a empezar con "Volver a imprimir").
  late final AnimationController _print = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (TicketPrinter.length * 1000).round()),
  );

  /// El reloj de la entrada del resto (tarjetas, deuda...): 6 s.
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );
  bool _started = false;

  static List<List<int>> _ownersOf(Expense e) => <List<int>>[
    for (final TicketItem i in e.items) List<int>.of(i.claimedBy),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) {
      _print.value = 1;
      _intro.value = 1;
      return;
    }
    unawaited(_print.forward());
    // Sin ticket no hay que esperar a que se imprima.
    unawaited(_intro.forward(from: _expense.items.isEmpty ? 0.74 : 0));
  }

  @override
  void dispose() {
    _print.dispose();
    _intro.dispose();
    super.dispose();
  }

  void _say(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  String _error(AppLocalizations t, ApiError e) =>
      e == ApiError.network ? t.errorNetwork : t.errorUnavailable;

  /// Vuelve a pedir el bote: así se ve lo que han marcado los demás.
  Future<void> _refresh() async {
    try {
      final ExpenseGroup fresh = await _services.expenses.get(_group.id);
      final Expense? again = fresh.expenses
          .where((Expense e) => e.id == _expense.id)
          .firstOrNull;
      if (!mounted) return;
      setState(() {
        _group = fresh;
        if (again != null) _take(again);
      });
    } on ApiException catch (e) {
      if (mounted) _say(_error(AppLocalizations.of(context), e.error));
    }
  }

  void _take(Expense e) {
    _expense = e;
    _split = e.split;
    _owners = _ownersOf(e);
    _cover = e.coverMinor;
    _discount = e.discountMinor;
    _tip = e.tipPct;
  }

  /// Guarda el reparto tal como está ahora en la pantalla.
  Future<void> _save() async {
    final int round = ++_round;
    try {
      final Expense saved = await _services.expenses.rework(
        _group.id,
        _expense.id,
        split: _split,
        owners: _split == SplitMode.items ? _owners : null,
        coverMinor: _cover,
        discountMinor: _discount,
        tipPct: _tip,
      );
      if (!mounted || round != _round) return;
      _changed = true;
      // El bote cambia (saldos, deudas): se vuelve a pedir.
      setState(() => _take(saved));
      unawaited(_refresh());
    } on ApiException catch (e) {
      if (!mounted || round != _round) return;
      setState(() => _take(_expense)); // vuelve a como estaba
      _say(_error(AppLocalizations.of(context), e.error));
    }
  }

  void _change(VoidCallback edit) {
    setState(edit);
    unawaited(_save());
  }

  bool get _iAmIn => _expense.participants.contains(_group.mySeat);

  /// Las líneas con lo que has marcado en la pantalla.
  List<TicketItem> get _items => <TicketItem>[
    for (int i = 0; i < _expense.items.length; i++)
      TicketItem(
        name: _expense.items[i].name,
        qty: _expense.items[i].qty,
        priceMinor: _expense.items[i].priceMinor,
        claimedBy: _owners[i],
      ),
  ];

  /// Lo que se reparte: ticket + cubierto − descuento + propina.
  int get _amount {
    final int base = _expense.ticketMinor + _cover - _discount;
    return base + tipFor(base, _tip);
  }

  Map<int, int> get _shares => _split == SplitMode.weights
      ? _expense.shares
      : previewShares(
          amountMinor: _amount,
          split: _split,
          participants: _expense.participants,
          items: _items,
        );

  /// Tocar a una persona en un plato: la pone o la quita.
  void _toggle(int line, int seat) {
    final List<int> all = _expense.participants;
    final List<int> now = _owners[line].isEmpty ? all : _owners[line];
    final List<int> next = now.contains(seat)
        ? <int>[
            for (final int s in now)
              if (s != seat) s,
          ]
        : <int>[
            for (final int s in all)
              if (s == seat || now.contains(s)) s,
          ];
    if (next.isEmpty) return; // alguien tiene que haberlo tomado
    _change(() => _owners[line] = next.length == all.length ? <int>[] : next);
  }

  Future<void> _askAmount(String title, int current, ValueChanged<int> set) {
    final AppLocalizations t = AppLocalizations.of(context);
    final int digits = currencyDigits(_group.currency);
    final TextEditingController c = TextEditingController(
      text: current > 0 ? plainAmount(current, digits) : '',
    );
    return showDialog<int>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: t.moneyAmount,
            suffixText: _group.currency,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(parseAmount(c.text, digits: digits)),
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ],
      ),
    ).then((int? v) {
      c.dispose();
      if (v != null && v > 0 && mounted) set(v);
    });
  }

  /// "Escanear QR del ticket": abre la cámara y lee el QR de Hacienda.
  Future<void> _scanQr() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final ScannedTicket? scanned = await _services.receipts.scanTicket(
      ReceiptSource.camera,
      currency: _group.currency,
    );
    if (!mounted || scanned == null) return;
    final VeriFactu? qr = scanned.qr == null
        ? null
        : parseVeriFactu(scanned.qr!);
    if (qr == null) {
      _say(t.qrNone);
      return;
    }
    final bool use = await showQrSheet(context, data: qr, raw: scanned.qr!);
    if (!use || !mounted) return;
    setState(() {
      _qr = qr;
      _alert = qr.totalMinor != _expense.ticketMinor + _cover - _discount;
    });
  }

  Future<void> _settle(Payment debt) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool paid = await showSettleSheet(
      context,
      group: _group,
      debt: debt,
      concept: _expense.title,
      onPay: (int minor) async {
        try {
          await _services.expenses.pay(
            _group.id,
            toSeat: debt.toSeat,
            amountMinor: minor,
          );
          return true;
        } on ApiException catch (e) {
          if (mounted) _say(_error(t, e.error));
          return false;
        }
      },
    );
    if (paid && mounted) {
      _changed = true;
      await _refresh();
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

  bool get _canDelete =>
      _expense.createdBy == _group.mySeat ||
      _expense.payerSeat == _group.mySeat;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final Expense e = _expense;
    final bool ticket = e.items.isNotEmpty;
    final bool byItems = _split == SplitMode.items && ticket;
    final Map<int, int> shares = _shares;
    return PopScope<bool>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, bool? result) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        backgroundColor: NomadColors.background,
        body: GastosSky(
          child: Stack(
            children: <Widget>[
              SafeArea(
                bottom: false,
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: AnimatedBuilder(
                    animation: _intro,
                    builder: (BuildContext context, _) {
                      final double s = _intro.value * 6;
                      double at(double start, double length) =>
                          ((s - start) / length).clamp(0, 1);
                      return ListView(
                        padding: const EdgeInsets.fromLTRB(16, 18, 16, 40),
                        children: <Widget>[
                          _Header(group: _group, expense: e),
                          const SizedBox(height: 14),
                          MoneyTiles(
                            title: t.gastosYourMoney,
                            abroad: t.moneyTabAbroad,
                            kitty: t.moneyTabKitty,
                            fx: t.moneyTabFx,
                            onOpen: (MoneyTab tab) =>
                                context.push(Routes.money(tab: tab)),
                          ),
                          if (ticket) ...<Widget>[
                            const SizedBox(height: 14),
                            _Stage(
                              clock: _print,
                              lines: e.items.length,
                              onReprint: () =>
                                  unawaited(_print.forward(from: 0)),
                            ),
                          ],
                          if (_group.currency == 'EUR') ...<Widget>[
                            const SizedBox(height: 14),
                            GastosButton(
                              label: t.gastosScanQr,
                              height: 46,
                              fontSize: 14,
                              background: const Color(0xFF10221C),
                              border: const Color(0xFF1F4237),
                              foreground: const Color(0xFF9BFFD3),
                              icon: const Icon(
                                Icons.qr_code_scanner_rounded,
                                size: 18,
                                color: NomadColors.mint,
                              ),
                              onTap: () => unawaited(_scanQr()),
                            ),
                          ],
                          if (ticket) ...<Widget>[
                            const SizedBox(height: 14),
                            TicketPrinter(
                              clock: _print,
                              group: _group,
                              expense: e.copyWithItems(_items),
                            ),
                            const SizedBox(height: 14),
                            riseIn(
                              at(4.5, 0.5),
                              SplitSwitch(
                                labels: <String>[t.gastosEqual, t.gastosByItem],
                                selected: switch (_split) {
                                  SplitMode.equal => 0,
                                  SplitMode.items => 1,
                                  SplitMode.weights => null,
                                },
                                onPick: !_iAmIn
                                    ? null
                                    : (int i) {
                                        final SplitMode next = i == 0
                                            ? SplitMode.equal
                                            : SplitMode.items;
                                        if (next != _split) {
                                          _change(() => _split = next);
                                        }
                                      },
                              ),
                            ),
                          ],
                          if (byItems) ...<Widget>[
                            const SizedBox(height: 14),
                            _ByItem(
                              key: const ValueKey<String>('byItem'),
                              group: _group,
                              expense: e,
                              owners: _owners,
                              cover: _cover,
                              discount: _discount,
                              tip: _tip,
                              qr: _qr,
                              enabled: _iAmIn,
                              onTable: () => unawaited(
                                showTableSheet(
                                  context,
                                  group: _group,
                                  expense: e.copyWithItems(_items),
                                  reload: () async {
                                    await _refresh();
                                    return _expense;
                                  },
                                ),
                              ),
                              onToggle: _toggle,
                              onEveryone: (int line) =>
                                  _change(() => _owners[line] = <int>[]),
                              onCover: () => _cover > 0
                                  ? _change(() => _cover = 0)
                                  : unawaited(
                                      _askAmount(
                                        t.gastosCover,
                                        e.coverMinor,
                                        (int v) => _change(() => _cover = v),
                                      ),
                                    ),
                              onDiscount: () => _discount > 0
                                  ? _change(() => _discount = 0)
                                  : unawaited(
                                      _askAmount(
                                        t.gastosDiscount,
                                        e.discountMinor,
                                        (int v) => _change(() => _discount = v),
                                      ),
                                    ),
                              onTip: (int pct) => _change(() => _tip = pct),
                            ),
                          ],
                          const SizedBox(height: 14),
                          riseIn(
                            at(4.6, 0.5),
                            _People(
                              group: _group,
                              expense: e,
                              shares: shares,
                              intro: s,
                            ),
                          ),
                          const SizedBox(height: 14),
                          riseIn(
                            at(4.7, 0.5),
                            _DebtCard(
                              group: _group,
                              expense: e,
                              shares: shares,
                              pulse: s >= 5.2,
                              onSettle: (Payment p) => unawaited(_settle(p)),
                            ),
                          ),
                          if (_canDelete) ...<Widget>[
                            const SizedBox(height: 8),
                            Center(
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(64, 40),
                                  foregroundColor: GastosColors.muted,
                                ),
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  size: 18,
                                ),
                                label: Text(t.moneyDelete),
                                onPressed: _delete,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
              ),
              if (_alert && _qr != null)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 16,
                  child: SafeArea(
                    top: false,
                    child: FlyraAlert(
                      title: t.mismatchTitle,
                      text: t.gastosQrMismatch(
                        money(
                          context,
                          e.items.fold(
                                0,
                                (int a, TicketItem i) => a + i.priceMinor,
                              ) +
                              _cover -
                              _discount,
                          _group.currency,
                        ),
                        money(context, _qr!.totalMinor, _group.currency),
                      ),
                      button: t.gastosAlertOk,
                      onClose: () => setState(() => _alert = false),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Arriba: volver, el local, el nombre del gasto, quién pagó y tu cara.
class _Header extends StatelessWidget {
  const _Header({required this.group, required this.expense});

  final ExpenseGroup group;
  final Expense expense;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool mine = expense.payerSeat == group.mySeat;
    final String who = personName(t, group, expense.payerSeat);
    final bool read = expense.items.isNotEmpty;
    final String paid = mine
        ? (read ? t.gastosPaidByMeRead : t.gastosPaidByMe)
        : (read ? t.gastosPaidByRead(who) : t.gastosPaidBy(who));
    final String me = group.nameOf(group.mySeat);
    final Color myColor = seatColor(group.mySeat);
    return Row(
      children: <Widget>[
        Semantics(
          button: true,
          label: MaterialLocalizations.of(context).backButtonTooltip,
          excludeSemantics: true,
          child: Material(
            color: GastosColors.card,
            shape: const CircleBorder(
              side: BorderSide(color: GastosColors.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => Navigator.of(context).maybePop(),
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.chevron_left_rounded,
                  color: GastosColors.text,
                  size: 26,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        PlaceInitial(name: expense.title),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                expense.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: NomadFonts.display,
                  fontVariations: <FontVariation>[FontVariation.weight(800)],
                  fontSize: 24,
                  letterSpacing: -0.48,
                  height: 1.15,
                  color: GastosColors.text,
                ),
              ),
              Text(
                paid,
                style: const TextStyle(fontSize: 12, color: GastosColors.muted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // Tu cara, con el anillo que gira: abre tus ajustes.
        Semantics(
          button: true,
          label: t.gastosMyProfile,
          excludeSemantics: true,
          child: GestureDetector(
            onTap: () => context.push(Routes.settings),
            child: SizedBox(
              width: 54,
              height: 54,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  OnScreenOnly(
                    child: SpinRing(
                      size: 54,
                      width: 2.5,
                      colors: <Color>[
                        myColor,
                        NomadColors.mint,
                        NomadColors.flights,
                        myColor,
                      ],
                      period: const Duration(seconds: 4),
                    ),
                  ),
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: myColor,
                      border: Border.all(
                        color: NomadColors.background,
                        width: 2,
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: myColor.withValues(alpha: 0.53),
                          blurRadius: 18,
                        ),
                      ],
                    ),
                    child: Text(
                      me.characters.first.toUpperCase(),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: NomadColors.background,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "IMPRIMIENDO EL TICKET…" → "FLYRA ESTÁ LEYENDO…" → "LISTO" y el botón
/// "Volver a imprimir".
class _Stage extends StatelessWidget {
  const _Stage({
    required this.clock,
    required this.lines,
    required this.onReprint,
  });

  final Animation<double> clock;
  final int lines;
  final VoidCallback onReprint;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: AnimatedBuilder(
            animation: clock,
            builder: (BuildContext context, _) {
              final double s = clock.value * TicketPrinter.length;
              return Text(
                s < 3
                    ? t.gastosPrinting
                    : s < 4.4
                    ? t.gastosReading
                    : t.gastosReady('$lines'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.72,
                  color: GastosColors.amber,
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: const Color(0xFF2A1F12),
          shape: const StadiumBorder(
            side: BorderSide(color: Color(0xFF5C4325)),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onReprint,
            child: Container(
              height: 34,
              constraints: const BoxConstraints(minWidth: 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              child: Text(
                t.gastosReprint,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFFFD3A3),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Por lo que tomó cada uno": los platos, los extras y si cuadra.
class _ByItem extends StatelessWidget {
  const _ByItem({
    super.key,
    required this.group,
    required this.expense,
    required this.owners,
    required this.cover,
    required this.discount,
    required this.tip,
    required this.qr,
    required this.enabled,
    required this.onTable,
    required this.onToggle,
    required this.onEveryone,
    required this.onCover,
    required this.onDiscount,
    required this.onTip,
  });

  final ExpenseGroup group;
  final Expense expense;
  final List<List<int>> owners;
  final int cover;
  final int discount;
  final int tip;
  final VeriFactu? qr;
  final bool enabled;
  final VoidCallback onTable;
  final void Function(int line, int seat) onToggle;
  final void Function(int line) onEveryone;
  final VoidCallback onCover;
  final VoidCallback onDiscount;
  final ValueChanged<int> onTip;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String cur = group.currency;
    final List<int> people = expense.participants.toList()..sort();
    String m(int minor) => money(context, minor, cur);
    // Lo que toma cada uno de platos (cada plato entre quien lo tomó).
    final Map<int, int> plates = <int, int>{for (final int p in people) p: 0};
    int lines = 0;
    for (int i = 0; i < expense.items.length; i++) {
      final int price = expense.items[i].priceMinor;
      lines += price;
      final List<int> who = owners[i].isEmpty ? people : owners[i];
      divide(price, <int, int>{for (final int s in who) s: 1}).forEach((
        int s,
        int v,
      ) {
        plates[s] = (plates[s] ?? 0) + v;
      });
    }
    final int me = group.mySeat;
    final int ticket = expense.ticketMinor;
    final int base = ticket + cover - discount;
    final int tipMinor = tipFor(base, tip);
    // Los extras, repartidos igual que los platos.
    final int myCover = divide(cover, plates)[me] ?? 0;
    final int myDiscount = divide(discount, plates)[me] ?? 0;
    final int myTotal = divide(base + tipMinor, plates)[me] ?? 0;
    final int myTip = myTotal - (plates[me] ?? 0) - myCover + myDiscount;
    final String breakdown = <String>[
      t.gastosMyPart(m(plates[me] ?? 0)),
      if (cover > 0) t.gastosMyCover(m(myCover)),
      if (discount > 0) t.gastosMyDiscount(m(myDiscount)),
      if (tipMinor > 0) t.gastosMyTip(m(myTip)),
      t.gastosMyTotal(m(myTotal)),
    ].join(' ');
    final int shouldBe = qr?.totalMinor ?? base;
    final bool bad = lines + cover - discount != shouldBe;
    final String status = bad
        ? (qr != null
              ? t.gastosSumBadQr(m(lines + cover - discount), m(shouldBe))
              : t.gastosSumBad(m(lines), m(ticket)))
        : '${qr != null ? t.gastosSumOkQr(m(base)) : t.gastosSumOk(m(base))}'
              '${tipMinor > 0 ? t.gastosSumTip(m(tipMinor)) : ''}';
    final Color dot = bad ? const Color(0xFFFF6B6B) : NomadColors.mint;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration(milliseconds: 500 + 70 * expense.items.length),
      builder: (BuildContext context, double v, _) {
        final double ms = v * (500 + 70 * expense.items.length);
        double at(int i) => ((ms - 100 - 70 * i) / 400).clamp(0, 1);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _GradientButton(label: t.gastosTable, onTap: onTable),
            const SizedBox(height: 8),
            Text(t.gastosLinesTitle, style: gastosLabel),
            for (int i = 0; i < expense.items.length; i++) ...<Widget>[
              const SizedBox(height: 8),
              riseIn(
                at(i),
                _LineCard(
                  group: group,
                  item: expense.items[i],
                  owners: owners[i].isEmpty ? people : owners[i],
                  everyone: owners[i].isEmpty,
                  people: people,
                  enabled: enabled,
                  onToggle: (int seat) => onToggle(i, seat),
                  onEveryone: () => onEveryone(i),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: gastosBox(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(t.gastosExtras, style: gastosLabel),
                  _ExtraRow(
                    label: t.gastosCover,
                    chips: <Widget>[
                      ToggleChip(
                        label: cover > 0 ? '+${m(cover)}' : t.tipNone,
                        on: cover > 0,
                        color: const Color(0xFF9CC4FF),
                        onTap: enabled ? onCover : null,
                      ),
                    ],
                  ),
                  _ExtraRow(
                    label: t.gastosDiscount,
                    chips: <Widget>[
                      ToggleChip(
                        label: discount > 0 ? '−${m(discount)}' : t.tipNone,
                        on: discount > 0,
                        color: NomadColors.mint,
                        onTap: enabled ? onDiscount : null,
                      ),
                    ],
                  ),
                  _ExtraRow(
                    label: t.tipTitle,
                    chips: <Widget>[
                      for (final int p in <int>[0, 5, 10])
                        Padding(
                          padding: const EdgeInsetsDirectional.only(start: 6),
                          child: ToggleChip(
                            label: p == 0 ? t.tipNone : '$p %',
                            on: tip == p,
                            color: p == 0
                                ? GastosColors.text
                                : GastosColors.amber,
                            onTap: enabled ? () => onTip(p) : null,
                          ),
                        ),
                    ],
                  ),
                  Text(
                    t.gastosVatNote,
                    style: const TextStyle(
                      fontSize: 11.5,
                      height: 1.45,
                      color: GastosColors.muted,
                    ),
                  ),
                  if (expense.participants.contains(me)) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      breakdown,
                      style: const TextStyle(
                        fontSize: 12,
                        height: 1.45,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFFCFE9DE),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: bad ? const Color(0xFF2A1414) : const Color(0xFF10221C),
                border: Border.all(
                  color: bad
                      ? const Color(0xFF6B2B2B)
                      : const Color(0xFF1F4237),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dot,
                      boxShadow: <BoxShadow>[
                        BoxShadow(color: dot, blurRadius: 10),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      status,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        fontWeight: FontWeight.w800,
                        color: bad
                            ? const Color(0xFFFFB3B3)
                            : const Color(0xFF9BFFD3),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ExtraRow extends StatelessWidget {
  const _ExtraRow({required this.label, required this.chips});

  final String label;
  final List<Widget> chips;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: Text(
          label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
        ),
      ),
      ...chips,
    ],
  );
}

/// "Que cada uno marque lo suyo desde su móvil" (verde → azul).
class _GradientButton extends StatelessWidget {
  const _GradientButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    clipBehavior: Clip.antiAlias,
    child: Ink(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-0.9, -0.5),
          end: Alignment(0.9, 0.5),
          colors: <Color>[Color(0xFF3DDC97), Color(0xFF6CA8FF)],
        ),
      ),
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(
                Icons.share_outlined,
                size: 18,
                color: NomadColors.background,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: NomadColors.background,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Un plato: su dibujo, nombre y precio, y quién lo tomó.
class _LineCard extends StatelessWidget {
  const _LineCard({
    required this.group,
    required this.item,
    required this.owners,
    required this.everyone,
    required this.people,
    required this.enabled,
    required this.onToggle,
    required this.onEveryone,
  });

  final ExpenseGroup group;
  final TicketItem item;
  final List<int> owners;
  final bool everyone;
  final List<int> people;
  final bool enabled;
  final ValueChanged<int> onToggle;
  final VoidCallback onEveryone;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String each = money(
      context,
      (item.priceMinor / owners.length).round(),
      group.currency,
    );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: gastosBox(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '${item.qty}×',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF7F9098),
                ),
              ),
              const SizedBox(width: 10),
              DishThumb(name: item.name),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.name,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                money(context, item.priceMinor, group.currency),
                style: const TextStyle(
                  fontFamily: NomadFonts.display,
                  fontVariations: <FontVariation>[FontVariation.weight(800)],
                  fontSize: 15,
                ),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              Expanded(
                child: Wrap(
                  spacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    for (final int s in people)
                      PersonToggle(
                        label: s == group.mySeat
                            ? t.groupYou
                            : group.nameOf(s).characters.first.toUpperCase(),
                        name: personName(t, group, s),
                        on: owners.contains(s),
                        color: seatColor(s),
                        onTap: enabled ? () => onToggle(s) : null,
                      ),
                    _DashedPill(
                      label: t.moneyEveryone,
                      onTap: enabled && !everyone ? onEveryone : null,
                    ),
                  ],
                ),
              ),
              Text(
                owners.length == 1
                    ? t.gastosForOne
                    : t.gastosEach('${owners.length}', each),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF9BFFD3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Todos", con el borde de rayas.
class _DashedPill extends StatelessWidget {
  const _DashedPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 44,
        child: Center(
          widthFactor: 1,
          child: CustomPaint(
            painter: _DashBorder(),
            child: Container(
              height: 30,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: GastosColors.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _DashBorder extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Path p = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5),
          Radius.circular(size.height / 2),
        ),
      );
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0xFF3A4B56);
    for (final m in p.computeMetrics()) {
      for (double d = 0; d < m.length; d += 6) {
        canvas.drawPath(m.extractPath(d, d + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(_DashBorder old) => false;
}

/// La tarjeta de cada persona, de dos en dos.
class _People extends StatelessWidget {
  const _People({
    required this.group,
    required this.expense,
    required this.shares,
    required this.intro,
  });

  final ExpenseGroup group;
  final Expense expense;
  final Map<int, int> shares;

  /// Segundos desde que se abrió la pantalla (para las entradas).
  final double intro;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<int> seats = shares.keys.toList()..sort();
    final bool iOwe = (group.balances[group.mySeat] ?? 0) < 0;
    final List<Widget> cards = <Widget>[
      for (int i = 0; i < seats.length; i++)
        cardIn(
          ((intro - 4.6 - i * 0.12) / 0.6).clamp(0, 1),
          PersonCard(
            index: i,
            color: seatColor(seats[i]),
            initial: group.nameOf(seats[i]).characters.first.toUpperCase(),
            name: personName(t, group, seats[i]),
            amount: money(context, shares[seats[i]]!, group.currency),
            tag: seats[i] == expense.payerSeat
                ? t.gastosPaidTag
                : seats[i] == group.mySeat && !iOwe
                ? t.gastosSettledTag
                : null,
            tagColor: seats[i] == expense.payerSeat
                ? const Color(0xFFFFD25E)
                : NomadColors.mint,
          ),
        ),
    ];
    return Column(
      children: <Widget>[
        for (int r = 0; r < cards.length; r += 2) ...<Widget>[
          if (r > 0) const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(child: cards[r]),
              const SizedBox(width: 8),
              Expanded(
                child: r + 1 < cards.length ? cards[r + 1] : const SizedBox(),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

/// "Le debes a Álex" con "Saldar", o "Te deben" si pagaste tú.
class _DebtCard extends StatelessWidget {
  const _DebtCard({
    required this.group,
    required this.expense,
    required this.shares,
    required this.pulse,
    required this.onSettle,
  });

  final ExpenseGroup group;
  final Expense expense;
  final Map<int, int> shares;
  final bool pulse;
  final ValueChanged<Payment> onSettle;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final int me = group.mySeat;
    final int payer = expense.payerSeat;
    if (payer == kittySeat) return const SizedBox.shrink();
    final bool iPaid = payer == me;
    final int amount = iPaid
        ? shares.entries
              .where((MapEntry<int, int> e) => e.key != me)
              .fold(0, (int a, MapEntry<int, int> e) => a + e.value)
        : shares[me] ?? 0;
    if (amount <= 0) return const SizedBox.shrink();
    final int myBalance = group.balances[me] ?? 0;
    final bool settled = !iPaid && myBalance >= 0;
    final String name = personName(t, group, payer);
    final Color who = seatColor(iPaid ? me : payer);
    return LoopClock(
      period: const Duration(seconds: 4),
      builder: (BuildContext context, double v) => Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          // El borde de colores que se mueve sin parar.
          gradient: LinearGradient(
            colors: const <Color>[
              Color(0xFFFFB86B),
              Color(0xFFFF8A65),
              Color(0xFFFFD25E),
              Color(0xFF3DDC97),
              Color(0xFFFFB86B),
            ],
            tileMode: TileMode.repeated,
            begin: Alignment(-1 - 4 * v, 0),
            end: Alignment(3 - 4 * v, 0),
          ),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0xB3FFB86B),
              blurRadius: 36,
              spreadRadius: -18,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const RadialGradient(
              center: Alignment.topLeft,
              radius: 1.6,
              colors: <Color>[Color(0xFF3A2A16), Color(0xFF22180E)],
              stops: <double>[0, 0.6],
            ),
          ),
          child: Stack(
            children: <Widget>[
              const Positioned.fill(
                child: Sheen(
                  width: 40,
                  period: Duration(milliseconds: 3600),
                  delay: Duration(seconds: 1),
                  color: Color(0x2EFFE6B4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: <Widget>[
                    _Coins(
                      color: who,
                      letter: (iPaid ? group.nameOf(me) : group.nameOf(payer))
                          .characters
                          .first
                          .toUpperCase(),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            iPaid ? t.gastosOwedToYou : t.gastosYouOwe(name),
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFFFFD3A3),
                            ),
                          ),
                          const SizedBox(height: 2),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerStart,
                            child: Text(
                              money(context, amount, group.currency),
                              style: const TextStyle(
                                fontFamily: NomadFonts.display,
                                fontVariations: <FontVariation>[
                                  FontVariation.weight(800),
                                ],
                                fontSize: 28,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IntrinsicWidth(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (!iPaid)
                            _SettleButton(
                              label: settled
                                  ? t.gastosSettledButton
                                  : t.gastosSettle,
                              pulse: pulse && !settled,
                              onTap: settled
                                  ? null
                                  : () => onSettle(
                                      Payment(
                                        fromSeat: me,
                                        toSeat: payer,
                                        amountMinor: amount < -myBalance
                                            ? amount
                                            : -myBalance,
                                      ),
                                    ),
                            ),
                          if (!iPaid) const SizedBox(height: 6),
                          Material(
                            color: Colors.transparent,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: const BorderSide(color: Color(0xFF5C4325)),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () =>
                                  context.push(Routes.money(tab: MoneyTab.fx)),
                              child: Container(
                                height: 36,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    const Icon(
                                      Icons.toll_rounded,
                                      size: 14,
                                      color: Color(0xFFFFD3A3),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      t.moneyTabFx,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFFFFD3A3),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// La cara de quien cobra, flotando, con tres monedas que dan vueltas.
class _Coins extends StatelessWidget {
  const _Coins({required this.color, required this.letter});

  final Color color;
  final String letter;

  @override
  Widget build(BuildContext context) => LoopClock(
    period: const Duration(milliseconds: 9600),
    builder: (BuildContext context, double v) {
      final double secs = v * 9.6;
      // Sube y baja 5 px cada 3 s.
      final double float = -5 * (0.5 - 0.5 * math.cos(secs / 3 * 2 * math.pi));
      return Transform.translate(
        offset: Offset(0, float),
        child: SizedBox(
          width: 52,
          height: 52,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              Positioned(
                left: 10,
                top: 10,
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: color.withValues(alpha: 0.6),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                  child: Text(
                    letter,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: NomadColors.background,
                    ),
                  ),
                ),
              ),
              for (int i = 0; i < 3; i++)
                _orbitCoin(
                  secs / 3.2 + i / 3,
                  <Color>[
                    const Color(0xFFFFD25E),
                    const Color(0xFFFFC23D),
                    const Color(0xFFFFE38A),
                  ][i],
                ),
            ],
          ),
        ),
      );
    },
  );

  Widget _orbitCoin(double turn, Color c) {
    final double a = turn * 2 * math.pi;
    return Positioned(
      left: 26 - 7 + 34 * math.cos(a) * 0.62,
      top: 26 - 7 + 34 * math.sin(a) * 0.62,
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            center: const Alignment(-0.3, -0.4),
            colors: <Color>[
              const Color(0xFFFFF4C9),
              c,
              const Color(0xFF9A5B07),
            ],
            stops: const <double>[0, 0.45, 1],
          ),
          boxShadow: <BoxShadow>[BoxShadow(color: c, blurRadius: 8)],
        ),
      ),
    );
  }
}

/// "Saldar": naranja, con un pulso que llama la atención.
class _SettleButton extends StatelessWidget {
  const _SettleButton({
    required this.label,
    required this.pulse,
    required this.onTap,
  });

  final String label;
  final bool pulse;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => LoopClock(
    period: const Duration(seconds: 2),
    builder: (BuildContext context, double v) {
      final double ring = pulse
          ? 10 * (0.5 - 0.5 * math.cos(v * 2 * math.pi))
          : 0;
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: const Color(0xFFFFB86B)
                  .withValues(alpha: 0.55 * (1 - ring / 10)),
              spreadRadius: ring,
            ),
            const BoxShadow(
              color: Color(0xCCFFB86B),
              blurRadius: 18,
              spreadRadius: -6,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: <Color>[
                  Color(0xFFFFD08A),
                  Color(0xFFFFB86B),
                  Color(0xFFFF9F5A),
                ],
                stops: <double>[0, 0.55, 1],
              ),
            ),
            child: InkWell(
              onTap: onTap,
              child: Stack(
                children: <Widget>[
                  const Positioned.fill(
                    child: Sheen(
                      width: 18,
                      period: Duration(milliseconds: 2600),
                      color: Color(0x8CFFFFFF),
                    ),
                  ),
                  Container(
                    height: 44,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    alignment: Alignment.center,
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: NomadColors.background,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
