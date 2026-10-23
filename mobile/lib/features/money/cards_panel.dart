// "¿Con qué tarjeta pago aquí?" (maqueta "Tu dinero fuera → Tarjetas").
//
// Apuntas tus tarjetas con lo que cobran fuera (lo pone en las condiciones
// de tu banco) y cuánto piensas gastar. La app calcula cuánto te costaría
// cada una en el viaje y marca la más barata con "MEJOR AQUÍ".
// Todo se queda en el móvil: ver travel_cards.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'money_widgets.dart';
import 'receipt_parser.dart';
import 'travel_cards.dart';

/// Los colores de los dibujos de tarjeta (como en la maqueta).
const List<List<Color>> cardFaces = <List<Color>>[
  <Color>[Color(0xFF2E5BFF), Color(0xFF1A2F8A)],
  <Color>[Color(0xFF3A3A3A), Color(0xFF111111)],
  <Color>[Color(0xFFFF8A65), Color(0xFFB8442A)],
  <Color>[Color(0xFF3DDC97), Color(0xFF1C6E4A)],
  <Color>[Color(0xFFB69CFF), Color(0xFF5B3FB0)],
];

/// "2,5 %" en español, "2.5 %" en inglés.
String pct(BuildContext context, double v) =>
    '${NumberFormat.decimalPattern(Localizations.localeOf(context).toLanguageTag()).format(v)} %';

class CardsPanel extends StatefulWidget {
  const CardsPanel({super.key});

  @override
  State<CardsPanel> createState() => _CardsPanelState();
}

class _CardsPanelState extends State<CardsPanel> {
  late final AppServices _services = ServicesScope.of(context);
  late Wallet _wallet = Wallet.load(_services.prefs);
  late final TextEditingController _spend = TextEditingController(
    text: _plainAmount(_wallet.plan.spendMinor, _wallet.plan.currency),
  );

  @override
  void dispose() {
    _spend.dispose();
    super.dispose();
  }

  void _change(Wallet w) {
    setState(() => _wallet = w);
    unawaited(w.save(_services.prefs));
  }

  void _setPlan({String? currency, int? spendMinor, int? cashPct}) {
    final SpendPlan p = _wallet.plan;
    _change(
      _wallet.copyWith(
        plan: SpendPlan(
          currency: currency ?? p.currency,
          spendMinor: spendMinor ?? p.spendMinor,
          cashPct: cashPct ?? p.cashPct,
        ),
      ),
    );
  }

  Future<void> _edit([int? index]) async {
    final _Edit? result = await showDialog<_Edit>(
      context: context,
      builder: (BuildContext context) => _CardDialog(
        card: index == null ? null : _wallet.cards[index],
        currency: _wallet.plan.currency,
        color: _wallet.cards.length % cardFaces.length,
      ),
    );
    if (result == null || !mounted) return;
    final List<TravelCard> cards = List<TravelCard>.of(_wallet.cards);
    if (result.card == null) {
      cards.removeAt(index!);
    } else if (index == null) {
      cards.add(result.card!);
    } else {
      cards[index] = result.card!;
    }
    _change(_wallet.copyWith(cards: cards));
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextTheme text = Theme.of(context).textTheme;
    final SpendPlan plan = _wallet.plan;
    final int digits = currencyDigits(plan.currency);
    final List<int> costs = <int>[
      for (final TravelCard c in _wallet.cards) tripCost(c, plan, digits),
    ];
    final int? best = _wallet.best(digits);
    final int worst = costs.isEmpty ? 0 : costs.reduce((a, b) => a > b ? a : b);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: <Widget>[
        Text(t.abroadCardsIntro, style: text.bodyLarge),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: _spend,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(labelText: t.abroadTripSpend),
                onChanged: (String v) {
                  final int? minor = parseAmount(v, digits: digits);
                  if (minor != null) _setPlan(spendMinor: minor);
                },
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: plan.currency,
              onChanged: (String? c) {
                if (c == null) return;
                _setPlan(
                  currency: c,
                  spendMinor: parseAmount(
                    _spend.text,
                    digits: currencyDigits(c),
                  ),
                );
              },
              items: <DropdownMenuItem<String>>[
                for (final String c in potCurrencies)
                  DropdownMenuItem<String>(value: c, child: Text(c)),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(t.abroadCashShare(plan.cashPct)),
        Slider(
          value: plan.cashPct.toDouble(),
          max: 100,
          divisions: 20,
          label: '${plan.cashPct} %',
          onChanged: (double v) => _setPlan(cashPct: v.round()),
        ),
        const SizedBox(height: 8),
        for (int i = 0; i < _wallet.cards.length; i++)
          _CardRow(
            card: _wallet.cards[i],
            cost: costs[i],
            currency: plan.currency,
            best: i == best && _wallet.cards.length > 1,
            onTap: () => _edit(i),
          ),
        if (_wallet.cards.length < maxTravelCards)
          OutlinedButton.icon(
            onPressed: _edit,
            icon: const Icon(Icons.add_card_rounded),
            label: Text(t.abroadAddCard),
          ),
        if (best != null && _wallet.cards.length > 1) ...<Widget>[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: NomadColors.surface,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: NomadColors.mint),
            ),
            child: Text(
              t.abroadCardTip(
                _wallet.cards[best].name,
                money(context, worst - costs[best], plan.currency),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          t.abroadCardsPrivacy,
          style: const TextStyle(fontSize: 12, color: NomadColors.textMuted),
        ),
      ],
    );
  }
}

String _plainAmount(int minor, String currency) {
  final int digits = currencyDigits(currency);
  final String s = (minor / _pow10(digits)).toStringAsFixed(digits);
  return digits == 0 ? s : s.replaceFirst(RegExp(r'\.?0+$'), '');
}

int _pow10(int n) => n <= 0 ? 1 : 10 * _pow10(n - 1);

class _CardRow extends StatelessWidget {
  const _CardRow({
    required this.card,
    required this.cost,
    required this.currency,
    required this.best,
    required this.onTap,
  });

  final TravelCard card;
  final int cost;
  final String currency;
  final bool best;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<Color> face = cardFaces[card.color % cardFaces.length];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: best ? NomadColors.mint : NomadColors.outline,
                width: best ? 2 : 1,
              ),
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 64,
                  height: 42,
                  padding: const EdgeInsets.fromLTRB(7, 6, 7, 6),
                  alignment: Alignment.bottomLeft,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    gradient: LinearGradient(colors: face),
                  ),
                  child: Text(
                    card.last4 == null ? '••••' : '•••• ${card.last4}',
                    style: const TextStyle(
                      fontSize: 9,
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Text(
                            card.name,
                            style: const TextStyle(fontWeight: FontWeight.w800),
                          ),
                          if (best)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: NomadColors.mint,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                t.abroadBest,
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: NomadColors.background,
                                ),
                              ),
                            ),
                        ],
                      ),
                      Text(
                        t.abroadCardFees(
                          pct(context, card.payPct),
                          pct(context, card.atmPct),
                          money(context, card.atmFixedMinor, currency),
                        ),
                        style: const TextStyle(
                          fontSize: 12,
                          color: NomadColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      money(context, cost, currency),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: best ? NomadColors.mint : NomadColors.text,
                      ),
                    ),
                    Text(
                      t.abroadInYourTrip,
                      style: const TextStyle(
                        fontSize: 11,
                        color: NomadColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Lo que devuelve el editor: la tarjeta nueva o cambiada, o null = borrar.
class _Edit {
  const _Edit(this.card);

  final TravelCard? card;
}

class _CardDialog extends StatefulWidget {
  const _CardDialog({
    required this.card,
    required this.currency,
    required this.color,
  });

  final TravelCard? card;
  final String currency;
  final int color;

  @override
  State<_CardDialog> createState() => _CardDialogState();
}

class _CardDialogState extends State<_CardDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.card?.name ?? '',
  );
  late final TextEditingController _last4 = TextEditingController(
    text: widget.card?.last4 ?? '',
  );
  late final TextEditingController _pay = TextEditingController(
    text: _num(widget.card?.payPct),
  );
  late final TextEditingController _atm = TextEditingController(
    text: _num(widget.card?.atmPct),
  );
  late final TextEditingController _fixed = TextEditingController(
    text: widget.card == null
        ? ''
        : _plainAmount(widget.card!.atmFixedMinor, widget.currency),
  );
  late int _color = widget.card?.color ?? widget.color;
  bool _invalid = false;

  static String _num(double? v) => v == null
      ? ''
      : v == v.roundToDouble()
      ? v.round().toString()
      : v.toString();

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _name,
      _last4,
      _pay,
      _atm,
      _fixed,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _pct(String v) {
    final String s = v.trim().replaceAll(',', '.');
    if (s.isEmpty) return 0;
    final double? d = double.tryParse(s);
    return d != null && validPct(d) ? d : null;
  }

  void _save() {
    final String name = _name.text.trim();
    final String last4 = _last4.text.trim();
    final double? pay = _pct(_pay.text);
    final double? atm = _pct(_atm.text);
    final int? fixed = _fixed.text.trim().isEmpty
        ? 0
        : parseAmount(_fixed.text, digits: currencyDigits(widget.currency));
    if (name.isEmpty ||
        name.length > 40 ||
        (last4.isNotEmpty && !isLast4(last4)) ||
        pay == null ||
        atm == null ||
        fixed == null) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(
      _Edit(
        TravelCard(
          name: name,
          last4: last4.isEmpty ? null : last4,
          color: _color,
          payPct: pay,
          atmPct: atm,
          atmFixedMinor: fixed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    const TextInputType decimal = TextInputType.numberWithOptions(
      decimal: true,
    );
    return AlertDialog(
      title: Text(widget.card == null ? t.abroadAddCard : t.abroadEditCard),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          TextField(
            controller: _name,
            maxLength: 40,
            decoration: InputDecoration(labelText: t.abroadCardName),
          ),
          TextField(
            controller: _last4,
            maxLength: 4,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              labelText: t.abroadCardLast4,
              helperText: t.abroadCardLast4Help,
            ),
          ),
          TextField(
            controller: _pay,
            keyboardType: decimal,
            decoration: InputDecoration(
              labelText: t.abroadCardPayPct,
              suffixText: '%',
            ),
          ),
          TextField(
            controller: _atm,
            keyboardType: decimal,
            decoration: InputDecoration(
              labelText: t.abroadCardAtmPct,
              suffixText: '%',
            ),
          ),
          TextField(
            controller: _fixed,
            keyboardType: decimal,
            decoration: InputDecoration(
              labelText: t.abroadCardAtmFixed,
              suffixText: widget.currency,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: <Widget>[
              for (int i = 0; i < cardFaces.length; i++)
                GestureDetector(
                  onTap: () => setState(() => _color = i),
                  child: Container(
                    width: 36,
                    height: 24,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(5),
                      gradient: LinearGradient(colors: cardFaces[i]),
                      border: Border.all(
                        color: i == _color ? Colors.white : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_invalid) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              t.abroadCardInvalid,
              style: const TextStyle(color: NomadColors.safety),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        if (widget.card != null)
          TextButton(
            onPressed: () => Navigator.of(context).pop(const _Edit(null)),
            child: Text(t.moneyDelete),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          onPressed: _save,
          child: Text(t.flightsOriginSave),
        ),
      ],
    );
  }
}
