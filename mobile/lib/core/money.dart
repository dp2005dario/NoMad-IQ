// Dinero en pantalla, en el formato de cada país.
//
// El servidor manda los precios en "unidades mínimas" y como número entero
// (31500 EUR = 315,00 €) para no perder céntimos con decimales. Aquí se
// convierte al texto que espera cada idioma: "315,00 €" en España,
// "€315.00" en inglés, "¥31,500" para yenes (que no tienen céntimos)...
import 'package:intl/intl.dart';

/// [amountMinor] en la [currency] (ISO 4217, como "EUR") escrito para [locale].
/// [compact] quita los decimales cuando son ",00" (queda mejor en avisos).
String formatMoney(
  int amountMinor,
  String currency,
  String locale, {
  bool compact = false,
}) {
  final NumberFormat probe = NumberFormat.simpleCurrency(
    locale: locale,
    name: currency,
  );
  // Cuántos decimales tiene la divisa (EUR 2, JPY 0, KWD 3).
  final int digits = probe.decimalDigits ?? 2;
  final num amount = amountMinor / _pow10(digits);
  final bool whole = amountMinor % _pow10(digits) == 0;
  final NumberFormat format = compact && whole
      ? NumberFormat.simpleCurrency(
          locale: locale,
          name: currency,
          decimalDigits: 0,
        )
      : probe;
  return format.format(amount);
}

int _pow10(int n) {
  int out = 1;
  for (int i = 0; i < n; i++) {
    out *= 10;
  }
  return out;
}
