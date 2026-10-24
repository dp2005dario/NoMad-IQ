// Piezas pequeñas que comparten las pantallas de Dinero: el círculo de color
// de cada persona, el saldo en verde/rojo y las monedas que se pueden elegir.
import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'expenses_api.dart';

/// Monedas para un bote nuevo. Son las más usadas al viajar; el servidor
/// admite cualquier código ISO de 3 letras.
const List<String> potCurrencies = <String>[
  'EUR',
  'USD',
  'GBP',
  'JPY',
  'CHF',
  'MXN',
  'BRL',
  'ARS',
  'COP',
  'CLP',
  'CAD',
  'AUD',
  'CNY',
  'INR',
  'AED',
  'SAR',
  'MAD',
  'TRY',
  'THB',
  'KRW',
];

/// Colores de las caritas, como en la maqueta (cada asiento el suyo).
const List<Color> seatColors = <Color>[
  NomadColors.group,
  NomadColors.safety,
  NomadColors.flights,
  NomadColors.money,
  NomadColors.mint,
  Color(0xFFFF7EB6),
  Color(0xFF7FE0E6),
  Color(0xFFE6D86B),
];

Color seatColor(int seat) => seat == kittySeat
    ? const Color(0xFFFFD9A8)
    : seatColors[(seat - 1) % seatColors.length];

/// "Tú" para ti, "El bote común" para la hucha y el nombre que eligió para
/// los demás.
String personName(AppLocalizations t, ExpenseGroup group, int seat) =>
    seat == kittySeat
    ? t.kittyName
    : seat == group.mySeat
    ? t.groupYou
    : group.nameOf(seat);

/// El dinero escrito en el idioma de la persona.
String money(BuildContext context, int minor, String currency) => formatMoney(
  minor,
  currency,
  Localizations.localeOf(context).toLanguageTag(),
);

/// Un círculo de color con la inicial de la persona.
class SeatAvatar extends StatelessWidget {
  const SeatAvatar({
    super.key,
    required this.seat,
    required this.name,
    this.size = 36,
    this.selected = true,
  });

  final int seat;
  final String name;
  final double size;

  /// Apagado (gris) cuando la persona no está marcada.
  final bool selected;

  @override
  Widget build(BuildContext context) => Semantics(
    label: name,
    excludeSemantics: true,
    child: Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? seatColor(seat) : NomadColors.surfaceHigh,
        border: selected ? null : Border.all(color: NomadColors.outline),
      ),
      child: Text(
        name.characters.first.toUpperCase(),
        style: TextStyle(
          color: selected ? NomadColors.background : NomadColors.textMuted,
          fontWeight: FontWeight.w800,
          fontSize: size * 0.42,
        ),
      ),
    ),
  );
}

/// "Te deben 12,00 €" en verde, "Debes 21,50 €" en rojo o "En paz".
class BalanceText extends StatelessWidget {
  const BalanceText({
    super.key,
    required this.balanceMinor,
    required this.currency,
    this.style,
  });

  final int balanceMinor;
  final String currency;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String amount = money(context, balanceMinor.abs(), currency);
    final (String text, Color color) = balanceMinor > 0
        ? (t.moneyOwedToYou(amount), NomadColors.mint)
        : balanceMinor < 0
        ? (t.moneyYouOwe(amount), NomadColors.safety)
        : (t.moneySettled, NomadColors.textMuted);
    return Text(
      text,
      style: (style ?? const TextStyle()).copyWith(
        color: color,
        fontWeight: FontWeight.w800,
      ),
    );
  }
}

/// El saldo de una persona en una fila: "+12,00 €" / "−21,50 €".
String signedMoney(BuildContext context, int minor, String currency) {
  if (minor == 0) return money(context, 0, currency);
  final String abs = money(context, minor.abs(), currency);
  return minor > 0 ? '+$abs' : '−$abs';
}
