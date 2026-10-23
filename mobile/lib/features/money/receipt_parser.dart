// Convierte el texto de un ticket (lo que "lee" el móvil en la foto) en las
// líneas de la cuenta: "2 Croquetas 12,00", "1 Pulpo a feira 18,50"... y el
// TOTAL.
//
// No hace falta IA para esto: un ticket casi siempre tiene la misma forma
// (cantidad, nombre, precio al final de la línea) y unas palabras fijas
// (TOTAL, IVA, TARJETA...). Con reglas sencillas sale gratis, al instante y
// sin mandar la foto a ningún servidor. Si algo se lee mal, la persona lo
// corrige en la pantalla antes de guardar: el lector propone, tú decides.
//
// Cómo funciona, paso a paso:
//   1. Cada fila del ticket llega como un texto ("2 Croquetas      12,00").
//   2. Si la fila termina en un precio, es candidata a línea de la cuenta.
//   3. Si además tiene una palabra de "total", es el total (no una línea).
//   4. Si tiene palabras de impuestos o de pago (IVA, TARJETA...), se salta.
//   5. Lo que queda, con al menos un par de letras en el nombre, es un plato.
import 'expenses_api.dart';

/// Lo que se sacó del ticket.
class ParsedReceipt {
  const ParsedReceipt({required this.items, this.totalMinor});

  final List<TicketItem> items;

  /// El TOTAL que pone el ticket (null si no se encontró).
  final int? totalMinor;

  /// La suma de las líneas leídas.
  int get itemsMinor =>
      items.fold(0, (int sum, TicketItem i) => sum + i.priceMinor);

  bool get isEmpty => items.isEmpty && totalMinor == null;
}

// Palabras que marcan el total, en varios idiomas (en mayúsculas y sin
// acentos, porque así se compara).
const List<String> _totalWords = <String>[
  'TOTAL',
  'A PAGAR',
  'IMPORTE TOTAL',
  'AMOUNT DUE',
  'BALANCE DUE',
  'SUMME',
  'GESAMT',
  'TOTALE',
  'MONTANT',
  'NET A PAYER',
  'TOTAAL',
  '合計',
  '合计',
  '总计',
  'المجموع',
  'कुल',
];

// Filas que NO son platos: subtotales, impuestos, propinas sugeridas, cómo
// se pagó, el cambio...
const List<String> _skipWords = <String>[
  'SUBTOTAL',
  'SUB TOTAL',
  'BASE',
  'IVA',
  'VAT',
  'TAX',
  'MWST',
  'TVA',
  'IGIC',
  'TARJETA',
  'CARD',
  'VISA',
  'MASTERCARD',
  'EFECTIVO',
  'CASH',
  'CAMBIO',
  'CHANGE',
  'ENTREGADO',
  'AUTORIZ',
  'NIF',
  'CIF',
  'TEL',
  'FACTURA',
  'INVOICE',
  'MESA',
  'TABLE',
  'CAJA',
  'COMENSALES',
  'DESCUENTO',
  'DISCOUNT',
  'RABATT',
  'SCONTO',
  'REMISE',
];

/// [digits]: cuántos decimales tiene la moneda (EUR 2, JPY 0).
ParsedReceipt parseReceipt(List<String> rows, {int digits = 2}) {
  final List<TicketItem> items = <TicketItem>[];
  int? total;
  for (final String raw in rows) {
    final String row = raw.trim();
    if (row.isEmpty) continue;
    final _Priced? priced = _splitPrice(row, digits);
    if (priced == null) continue;
    final String upper = _plain(priced.label);
    if (_totalWords.any(upper.contains) && !upper.contains('SUBTOTAL')) {
      // Si hay varios "TOTAL" (total, total tarjeta...), vale el mayor.
      if (total == null || priced.minor > total) total = priced.minor;
      continue;
    }
    if (_skipWords.any((String w) => _hasWord(upper, w))) continue;
    if (priced.minor <= 0) continue;
    final _Named? named = _splitQty(priced.label);
    if (named == null) continue;
    if (items.length >= maxTicketItems) break;
    items.add(
      TicketItem(name: named.name, qty: named.qty, priceMinor: priced.minor),
    );
  }
  return ParsedReceipt(items: items, totalMinor: total);
}

class _Priced {
  const _Priced(this.label, this.minor);

  final String label;
  final int minor;
}

class _Named {
  const _Named(this.name, this.qty);

  final String name;
  final int qty;
}

// Un precio al FINAL de la fila: "12,00", "1.234,50", "12.00 €", "EUR 8,5"...
// Con 0 decimales (yenes) vale "1,200" o "1200".
final RegExp _price2 = RegExp(
  r'(-?\d{1,3}(?:[.\s]\d{3})*,\d{1,2}|-?\d{1,3}(?:[,\s]\d{3})*\.\d{1,2}|-?\d+[.,]\d{1,2})'
  r'\s*(?:€|EUR|E|\$|USD|£|GBP)?\s*[A-Z]?$',
);
final RegExp _price0 = RegExp(
  r'(-?\d{1,3}(?:[.,\s]\d{3})+|-?\d+)\s*(?:¥|円|JPY|원|KRW)?\s*$',
);

_Priced? _splitPrice(String row, int digits) {
  final RegExp pattern = digits == 0 ? _price0 : _price2;
  final RegExpMatch? m = pattern.firstMatch(row);
  if (m == null) return null;
  final int? minor = _toMinor(m.group(1)!, digits);
  if (minor == null) return null;
  final String label = row.substring(0, m.start).trim();
  return _Priced(label, minor);
}

/// "1.234,50" o "1,234.50" → 123450 (con [digits] decimales).
int? _toMinor(String text, int digits) {
  final bool negative = text.startsWith('-');
  final String clean = text.replaceAll(RegExp(r'[\s-]'), '');
  if (digits == 0) {
    final int? whole = int.tryParse(clean.replaceAll(RegExp(r'[.,]'), ''));
    return whole == null ? null : (negative ? -whole : whole);
  }
  // El ÚLTIMO separador es el de los decimales; los anteriores, de miles.
  final int cut = clean.lastIndexOf(RegExp(r'[.,]'));
  if (cut < 0) return null;
  final String whole = clean.substring(0, cut).replaceAll(RegExp(r'[.,]'), '');
  String fraction = clean.substring(cut + 1);
  if (fraction.length > digits) return null;
  fraction = fraction.padRight(digits, '0');
  final int? value = int.tryParse('${whole.isEmpty ? '0' : whole}$fraction');
  if (value == null) return null;
  return negative ? -value : value;
}

// "2 Croquetas", "2x Croquetas", "2 x Croquetas", "Croquetas" (qty 1).
final RegExp _qty = RegExp(r'^(\d{1,3})\s*[xX×]?\s+(.+)$');

_Named? _splitQty(String label) {
  String name = label;
  int qty = 1;
  final RegExpMatch? m = _qty.firstMatch(label);
  if (m != null) {
    qty = int.parse(m.group(1)!);
    name = m.group(2)!;
  }
  // Quita un precio por unidad que a veces va en medio ("Caña 2,35").
  name = name.replaceAll(RegExp(r'\s+\d+[.,]\d{1,2}$'), '').trim();
  // Un plato necesita al menos dos letras (de cualquier alfabeto).
  if (RegExp(r'\p{L}', unicode: true).allMatches(name).length < 2) return null;
  if (qty < 1) qty = 1;
  if (name.length > maxItemName) name = name.substring(0, maxItemName).trim();
  return _Named(name, qty);
}

/// Mayúsculas y sin acentos: "Propina sugérée" → "PROPINA SUGEREE".
String _plain(String text) {
  const String from = 'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ';
  const String to = 'AAAAAEEEEIIIIOOOOOUUUUNC';
  final StringBuffer out = StringBuffer();
  for (final int rune in text.toUpperCase().runes) {
    final String c = String.fromCharCode(rune);
    final int i = from.indexOf(c);
    out.write(i < 0 ? c : to[i]);
  }
  return out.toString();
}

/// ¿Está [word] como palabra suelta (no dentro de otra)? Así "TEL" no salta
/// en "PASTEL".
bool _hasWord(String text, String word) =>
    RegExp('(^|[^A-Z])${RegExp.escape(word)}([^A-Z]|\$)').hasMatch(text);

/// Lo que escribe la persona en la caja del importe ("12,50", "12.5", "1.200")
/// en unidades mínimas. null si no es un importe válido y positivo.
int? parseAmount(String text, {int digits = 2}) {
  final String clean = text.trim().replaceAll(RegExp(r'[^\d.,]'), '');
  if (clean.isEmpty) return null;
  int? minor;
  if (digits == 0) {
    minor = _toMinor(clean, 0);
  } else {
    // Sin separador o con uno de miles ("1.200"): son unidades enteras.
    final int cut = clean.lastIndexOf(RegExp(r'[.,]'));
    final bool hasDecimals = cut >= 0 && clean.length - cut - 1 <= digits;
    minor = hasDecimals
        ? _toMinor(clean, digits)
        : _toMinor('${clean.replaceAll(RegExp(r'[.,]'), '')},0', digits);
  }
  return minor != null && minor > 0 ? minor : null;
}
