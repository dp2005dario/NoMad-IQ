// Pequeñas ayudas para escribir rutas, fechas y precios de vuelos en el
// idioma del usuario (todas las pantallas de Vuelos las comparten).
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import '../../core/money.dart';
import '../../l10n/generated/app_localizations.dart';
import 'fares_api.dart';

/// El idioma de la pantalla como lo entiende intl ("es", "pt_BR"...).
String localeOf(BuildContext context) =>
    Intl.canonicalizedLocale(Localizations.localeOf(context).toString());

String priceText(BuildContext context, Money m, {bool compact = true}) =>
    formatMoney(m.amountMinor, m.currency, localeOf(context), compact: compact);

/// "15 dic." / "Dec 15".
String dayText(BuildContext context, DateTime day) =>
    DateFormat.MMMd(localeOf(context)).format(day);

/// "MAD → NRT". Los códigos IATA se leen igual en todos los idiomas; con
/// Directionality.ltr la flecha apunta bien también en árabe.
String routeText(FareRoute r) => '${r.origin} → ${r.destination}';

String cabinText(AppLocalizations t, String cabin) => switch (cabin) {
  'PREMIUM_ECONOMY' => t.cabinPremium,
  'BUSINESS' => t.cabinBusiness,
  'FIRST' => t.cabinFirst,
  _ => t.cabinEconomy,
};

/// "15 dic. · Solo ida · Turista" o "15 dic. – 22 dic. · Turista".
String tripText(BuildContext context, AppLocalizations t, FareRoute r) {
  final String dates = r.returnDate == null
      ? '${dayText(context, r.departure)} · ${t.flightsOneWay}'
      : '${dayText(context, r.departure)} – ${dayText(context, r.returnDate!)}';
  return '$dates · ${cabinText(t, r.cabin)}';
}

/// Porcentaje entero de una bajada (3550 → 35). Nunca "−0 %".
int dropPercent(int basisPoints) => basisPoints ~/ 100;

/// Decimales de una divisa (EUR 2, JPY 0): para leer lo que escribe el usuario.
int currencyDigits(String currency, String locale) =>
    NumberFormat.simpleCurrency(locale: locale, name: currency).decimalDigits ??
    2;

/// "299,99" o "300" (en la divisa) → unidades mínimas. null si no es un número.
int? parseAmount(String raw, String currency, String locale) {
  final String clean = raw.trim().replaceAll(' ', '').replaceAll(',', '.');
  if (clean.isEmpty) return null;
  final double? value = double.tryParse(clean);
  if (value == null || value <= 0 || value > 1000000) return null;
  int factor = 1;
  for (int i = 0; i < currencyDigits(currency, locale); i++) {
    factor *= 10;
  }
  return (value * factor).round();
}
