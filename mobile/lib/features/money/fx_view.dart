// Divisas (maqueta "Cambio de moneda"): escribes una cantidad, eliges las
// dos monedas y tocas "Lanzar la moneda": la moneda sube girando y cae del
// otro lado ya convertida.
//
// Los tipos son los oficiales del Banco Central Europeo de ese día. Sin red
// se usan los últimos guardados en el móvil (con aviso de la fecha).
//
// Arriba, Flyra recuerda siempre que es SOLO INFORMATIVA (el banco o la casa
// de cambio te darán otro cambio). Hay botones rápidos (10, 20, 50, 100,
// 200) y, al caer la moneda, "Cómo llevarlo en efectivo": hasta tres formas
// (Menos piezas, Equilibrado, Sueltos y propinas) con las FOTOS de los
// billetes y monedas (si no hay foto de uno, se dibuja con su valor).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/money.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../visa/visa_data.dart' show CountryNames;
import 'banknotes.dart';
import 'currency_info.dart';
import 'currency_photos.dart';
import 'fx_api.dart';
import 'receipt_parser.dart';

class FxView extends StatefulWidget {
  const FxView({super.key});

  @override
  State<FxView> createState() => _FxViewState();
}

class _FxViewState extends State<FxView> with SingleTickerProviderStateMixin {
  late final AppServices _services = ServicesScope.of(context);
  late final AnimationController _toss = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  final TextEditingController _amount = TextEditingController(text: '50');
  FxResult? _fx;
  ApiError? _error;
  String _from = 'EUR';
  String _to = 'USD';
  bool _landed = false;
  // Los nombres de país en tu idioma (para "🇬🇧 GBP · Reino Unido").
  CountryNames? _names;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_fx == null && _error == null) unawaited(_load());
  }

  @override
  void dispose() {
    _toss.dispose();
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    unawaited(
      CountryNames.load()
          .then((CountryNames n) {
            if (mounted) setState(() => _names = n);
          })
          .catchError((Object _) {
            // Sin nombres: se ve solo el código, como antes.
          }),
    );
    try {
      final FxResult fx = await _services.fx.load();
      if (mounted) {
        setState(() {
          _fx = fx;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.error);
    }
  }

  void _pick({String? from, String? to}) {
    setState(() {
      // Si eliges la misma moneda en los dos lados, se intercambian.
      if (from != null) {
        if (from == _to) _to = _from;
        _from = from;
      }
      if (to != null) {
        if (to == _from) _from = _to;
        _to = to;
      }
      _landed = false;
      _toss.reset();
    });
  }

  Future<void> _throw() async {
    if (_toss.isAnimating) return;
    setState(() => _landed = false);
    await _toss.forward(from: 0);
    if (mounted) setState(() => _landed = true);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final FxResult? fx = _fx;
    if (fx == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    _error == ApiError.network
                        ? t.errorNetwork
                        : t.errorUnavailable,
                  ),
                  TextButton(
                    onPressed: () => unawaited(_load()),
                    child: Text(t.guideRetry),
                  ),
                ],
              ),
      );
    }
    final FxRates rates = fx.rates;
    final String locale = Localizations.localeOf(context).toLanguageTag();
    final int? amount = parseAmount(
      _amount.text,
      digits: currencyDigits(_from),
    );
    final int? result = amount == null || !rates.has(_from) || !rates.has(_to)
        ? null
        : rates.convert(amount, _from, _to);
    final String day = DateFormat.yMMMd(locale).format(rates.date);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
      children: <Widget>[
        _FlyraInfo(text: t.fxInfoOnly),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                TextField(
                  controller: _amount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: Theme.of(context).textTheme.headlineSmall,
                  onChanged: (_) => setState(() => _landed = false),
                  decoration: InputDecoration(
                    labelText: t.fxAmount,
                    suffixText: _symbol(_from, locale),
                  ),
                ),
                const SizedBox(height: 8),
                // Botones rápidos: tocar uno escribe esa cantidad.
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final int q in _quick)
                      ChoiceChip(
                        label: Text('$q'),
                        selected: amount == q * _unit(_from),
                        onSelected: (_) => setState(() {
                          _amount.text = '$q';
                          _landed = false;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _CurrencyPicker(
                        label: t.fxFrom,
                        value: _from,
                        describe: _describe,
                        options: rates.currencies,
                        onChanged: (String c) => _pick(from: c),
                      ),
                    ),
                    IconButton(
                      tooltip: t.fxSwap,
                      icon: const Icon(Icons.swap_horiz_rounded),
                      onPressed: () => _pick(from: _to),
                    ),
                    Expanded(
                      child: _CurrencyPicker(
                        label: t.fxTo,
                        value: _to,
                        describe: _describe,
                        options: rates.currencies,
                        onChanged: (String c) => _pick(to: c),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _CoinStage(
          toss: _toss,
          front: _from,
          back: _to,
          locale: locale,
          label: _toss.isAnimating
              ? t.fxInTheAir
              : _landed
              ? t.fxLanded(_to)
              : t.fxReady,
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 72,
          child: Center(
            child: _landed && amount != null && result != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        t.fxAre(formatMoney(amount, _from, locale)),
                        style: const TextStyle(color: NomadColors.textMuted),
                      ),
                      Text(
                        formatMoney(result, _to, locale),
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(color: NomadColors.money),
                      ),
                    ],
                  )
                : Text(
                    amount == null ? t.moneyAmountInvalid : t.fxHint,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: NomadColors.money,
            foregroundColor: NomadColors.background,
          ),
          onPressed: amount == null ? null : () => unawaited(_throw()),
          icon: const Icon(Icons.currency_exchange_rounded),
          label: Text(_landed ? t.fxThrowAgain : t.fxThrow),
        ),
        const SizedBox(height: 12),
        if (rates.has(_from) && rates.has(_to))
          Text(
            t.fxRateLine(
              '1 ${_symbol(_from, locale)}',
              NumberFormat.decimalPatternDigits(
                locale: locale,
                decimalDigits: 4,
              ).format(rates.rate(_from, _to)),
              _symbol(_to, locale),
              day,
            ),
            textAlign: TextAlign.center,
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        if (_landed && result != null) ...<Widget>[
          const SizedBox(height: 16),
          _Banknotes(
            amountMinor: result,
            currency: _to,
            locale: locale,
            onSource: (Uri u) => unawaited(_services.openBooking(u)),
          ),
        ],
        if (fx.offline) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            t.fxOffline(day),
            textAlign: TextAlign.center,
            style: const TextStyle(color: NomadColors.money),
          ),
        ],
      ],
    );
  }
}

extension on _FxViewState {
  /// "🇬🇧 GBP · Reino Unido" (o "🇪🇺 EUR · Zona euro").
  String _describe(String code) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    final String flag = currencyFlag(code);
    final String? country = code == 'EUR'
        ? t.fxEurozone
        : currencyCountry[code] == null
        ? null
        : _names?.name(currencyCountry[code]!, lang);
    return <String>[
      if (flag.isNotEmpty) flag,
      country == null ? code : '$code · $country',
    ].join(' ');
  }
}

/// Las cantidades de los botones rápidos.
const List<int> _quick = <int>[10, 20, 50, 100, 200];

/// Cuántas unidades pequeñas tiene una entera (100 céntimos = 1 euro; el
/// yen no tiene: 1).
int _unit(String currency) {
  int unit = 1;
  for (int i = 0; i < currencyDigits(currency); i++) {
    unit *= 10;
  }
  return unit;
}

/// El aviso fijo de Flyra (con su foto).
class _FlyraInfo extends StatelessWidget {
  const _FlyraInfo({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF1A1530),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF3E3163)),
    ),
    child: Row(
      children: <Widget>[
        const FlyraAvatar(size: 32),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Color(0xFFDCD3F7), height: 1.35),
          ),
        ),
      ],
    ),
  );
}

String _symbol(String code, String locale) =>
    NumberFormat.simpleCurrency(locale: locale, name: code).currencySymbol;

class _CurrencyPicker extends StatelessWidget {
  const _CurrencyPicker({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.describe,
  });

  final String label;
  final String value;
  final List<String> options;
  final String Function(String code) describe;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<String>(
    initialValue: options.contains(value) ? value : null,
    isExpanded: true,
    decoration: InputDecoration(labelText: label),
    items: <DropdownMenuItem<String>>[
      for (final String c in options)
        DropdownMenuItem<String>(
          value: c,
          child: Text(describe(c), overflow: TextOverflow.ellipsis),
        ),
    ],
    onChanged: (String? c) {
      if (c != null) onChanged(c);
    },
  );
}

/// El "escenario" de la moneda: un suelo, la sombra y la moneda que salta
/// girando (3,5 vueltas: cae enseñando la otra cara).
class _CoinStage extends StatelessWidget {
  const _CoinStage({
    required this.toss,
    required this.front,
    required this.back,
    required this.locale,
    required this.label,
  });

  final Animation<double> toss;
  final String front;
  final String back;
  final String locale;
  final String label;

  @override
  Widget build(BuildContext context) => Container(
    height: 280,
    clipBehavior: Clip.antiAlias,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      border: Border.all(color: const Color(0xFF22313A)),
      gradient: const RadialGradient(
        center: Alignment.bottomCenter,
        radius: 1.1,
        colors: <Color>[Color(0xFF1D2C35), Color(0xFF0F1A20)],
      ),
    ),
    child: Stack(
      children: <Widget>[
        const Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 60,
          child: ColoredBox(color: Color(0xFF16232B)),
        ),
        PositionedDirectional(
          start: 14,
          top: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: const Color(0xCC0B1217),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              label,
              style: const TextStyle(
                color: NomadColors.money,
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.6,
              ),
            ),
          ),
        ),
        AnimatedBuilder(
          animation: toss,
          builder: (BuildContext context, Widget? _) {
            final double p = toss.value;
            // Sube y baja (una parábola) y rebota un poco al caer.
            final double lift = p < 0.9
                ? math.sin(math.pi * p / 0.9) * 170
                : math.sin(math.pi * (p - 0.9) / 0.1) * 12;
            // 3,5 vueltas: al final se ve la cara de detrás (la convertida).
            final double angle = Curves.easeOutCubic.transform(p) * math.pi * 7;
            final bool showBack = p > 0 && math.cos(angle) < 0;
            final bool landedBack = p >= 1;
            return Stack(
              alignment: Alignment.bottomCenter,
              children: <Widget>[
                // La sombra se hace pequeña cuando la moneda sube.
                Positioned(
                  bottom: 30,
                  child: Opacity(
                    opacity: 0.55 - lift / 170 * 0.35,
                    child: Container(
                      width: 120 * (1 - lift / 170 * 0.6),
                      height: 18,
                      decoration: const BoxDecoration(
                        shape: BoxShape.rectangle,
                        borderRadius: BorderRadius.all(
                          Radius.elliptical(60, 9),
                        ),
                        color: Colors.black54,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  bottom: 46 + lift,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0015)
                      ..rotateX(0.3)
                      ..rotateY(landedBack ? math.pi : angle),
                    child: (showBack || landedBack)
                        // La cara de detrás va dada la vuelta para leerse bien.
                        ? Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.rotationY(math.pi),
                            child: _CoinFace(currency: back, locale: locale),
                          )
                        : _CoinFace(currency: front, locale: locale),
                  ),
                ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

/// Una cara de la moneda: aro, centro dorado o plateado y el símbolo.
class _CoinFace extends StatelessWidget {
  const _CoinFace({required this.currency, required this.locale});

  final String currency;
  final String locale;

  // Unas monedas doradas por fuera y otras plateadas, como las de verdad.
  static const Set<String> _goldRing = <String>{'JPY', 'GBP', 'CNY', 'INR'};

  @override
  Widget build(BuildContext context) {
    final bool gold = _goldRing.contains(currency);
    const Color silver = Color(0xFFB9BEC3);
    const Color goldC = Color(0xFFC9962E);
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-0.3, -0.4),
          colors: gold
              ? const <Color>[Color(0xFFF3DE97), goldC]
              : const <Color>[Color(0xFFEEF1F3), Color(0xFF9DA5AD)],
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Colors.black45,
            blurRadius: 12,
            offset: Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Container(
        width: 96,
        height: 96,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: const Color(0xFF6F777E), width: 1.5),
          gradient: RadialGradient(
            center: const Alignment(-0.2, -0.3),
            colors: gold
                ? const <Color>[Color(0xFFF1F3F5), silver]
                : const <Color>[Color(0xFFF6D77A), goldC],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _symbol(currency, locale),
              style: const TextStyle(
                fontFamily: NomadFonts.display,
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: Color(0xFF3E3420),
              ),
            ),
            Text(
              currency,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.5,
                color: Color(0xFF3E3420),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "¿Qué billetes son?": las formas de juntar la cantidad con billetes de
/// [currency], dibujados (no son fotos de billetes reales).
class _Banknotes extends StatelessWidget {
  const _Banknotes({
    required this.amountMinor,
    required this.currency,
    required this.locale,
    required this.onSource,
  });

  final int amountMinor;
  final String currency;
  final String locale;
  final ValueChanged<Uri> onSource;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final BanknoteSet? set = banknotes[currency];
    if (set == null) return const SizedBox.shrink();
    final int unit = _unit(currency);
    final List<NoteMix> mixes = noteMixes(amountMinor ~/ unit, currency);
    if (mixes.isEmpty) return const SizedBox.shrink();
    // Lo que no llega a billete (incluidos los céntimos) va en monedas.
    final int coinsMinor = amountMinor - (amountMinor ~/ unit) * unit;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(t.fxCashTitle, style: Theme.of(context).textTheme.titleMedium),
            for (int i = 0; i < mixes.length; i++) ...<Widget>[
              const SizedBox(height: 10),
              // El nombre de cada forma: la 1ª tiene menos piezas; las
              // siguientes, billetes cada vez más pequeños.
              Text(
                <String>[t.fxMixFewest, t.fxMixBalanced, t.fxMixSmall][i],
                style: const TextStyle(
                  color: NomadColors.money,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final NotePile p in mixes[i].piles)
                    _Note(
                      photo: notePhoto(currency, p.value),
                      label: formatMoney(
                        p.value * unit,
                        currency,
                        locale,
                        compact: true,
                      ),
                      count: p.count,
                    ),
                ],
              ),
              // Las monedas, dibujadas (si conocemos las de esa divisa).
              if (coinPiles(mixes[i].rest * unit + coinsMinor, currency)
                  case final List<NotePile> c when c.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final NotePile p in c)
                        _Coin(
                          photo: coinPhoto(currency, p.value),
                          label: formatMoney(
                            p.value,
                            currency,
                            locale,
                            compact: true,
                          ),
                          count: p.count,
                        ),
                    ],
                  ),
                )
              else if (mixes[i].rest * unit + coinsMinor > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    t.fxNotesCoins(
                      formatMoney(
                        mixes[i].rest * unit + coinsMinor,
                        currency,
                        locale,
                      ),
                    ),
                    style: const TextStyle(color: NomadColors.textMuted),
                  ),
                ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => onSource(Uri.parse(set.source)),
              child: Text(t.fxNotesSource),
            ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.label, required this.count, this.photo});

  final String label;
  final int count;

  /// La foto del billete (assets/divisas/...), o null para dibujarlo.
  final String? photo;

  @override
  Widget build(BuildContext context) {
    final String? photo = this.photo;
    final Widget drawn = Container(
      width: 86,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: NomadColors.money.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: NomadColors.money, width: 1.5),
      ),
      child: Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          label: label,
          image: photo != null,
          child: photo == null
              ? drawn
              : ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.asset(
                    photo,
                    width: 110,
                    height: 56,
                    fit: BoxFit.contain,
                    excludeFromSemantics: true,
                    // Si la foto no carga, el billete dibujado.
                    errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                        drawn,
                  ),
                ),
        ),
        const SizedBox(width: 4),
        Text('× $count', style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    );
  }
}

/// Una moneda: su foto (o un círculo dorado con su valor) y cuántas.
class _Coin extends StatelessWidget {
  const _Coin({required this.label, required this.count, this.photo});

  final String label;
  final int count;

  /// La foto de la moneda (assets/divisas/...), o null para dibujarla.
  final String? photo;

  @override
  Widget build(BuildContext context) {
    final String? photo = this.photo;
    final Widget drawn = Container(
      width: 44,
      height: 44,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const RadialGradient(
          colors: <Color>[Color(0xFFF6DD8B), Color(0xFFC9A04A)],
        ),
        border: Border.all(color: const Color(0xFF8E6E2C), width: 1.5),
      ),
      child: FittedBox(
        child: Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            color: Color(0xFF3B2A08),
          ),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          label: label,
          image: photo != null,
          child: photo == null
              ? drawn
              : Image.asset(
                  photo,
                  width: 44,
                  height: 44,
                  fit: BoxFit.contain,
                  excludeFromSemantics: true,
                  errorBuilder: (BuildContext c, Object e, StackTrace? s) =>
                      drawn,
                ),
        ),
        const SizedBox(width: 4),
        Text('× $count', style: const TextStyle(fontWeight: FontWeight.w800)),
      ],
    );
  }
}
