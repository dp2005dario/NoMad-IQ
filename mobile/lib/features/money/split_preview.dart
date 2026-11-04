// Cuánto le toca a cada uno, calculado EN EL MÓVIL antes de guardar (para
// verlo mientras marcas platos o eliges la propina).
//
// Es una copia exacta de las cuentas del servidor (expenses/domain.py,
// funciones `divide` y `shares`): el servidor es quien manda, pero así lo que
// ves antes de guardar es lo mismo que verás después.
import 'expenses_api.dart';

/// Reparte [total] céntimos según los pesos, sin perder ni un céntimo
/// (método del "resto mayor"; si empatan, gana el asiento más bajo).
/// Ejemplo: 100 céntimos entre 3 → 34, 33, 33.
Map<int, int> divide(int total, Map<int, int> weights) {
  final Map<int, int> w = <int, int>{
    for (final MapEntry<int, int> e in weights.entries)
      if (e.value > 0) e.key: e.value,
  };
  if (w.isEmpty) return <int, int>{};
  final int sum = w.values.fold(0, (int a, int b) => a + b);
  final Map<int, int> out = <int, int>{
    for (final MapEntry<int, int> e in w.entries) e.key: total * e.value ~/ sum,
  };
  final int left = total - out.values.fold(0, (int a, int b) => a + b);
  final List<int> order = w.keys.toList()
    ..sort((int a, int b) {
      final int byRest = (total * w[b]! % sum).compareTo(total * w[a]! % sum);
      return byRest != 0 ? byRest : a.compareTo(b);
    });
  for (final int seat in order.take(left)) {
    out[seat] = out[seat]! + 1;
  }
  return out;
}

/// Lo que le toca pagar a cada participante de un gasto de [amountMinor].
///
/// Con [SplitMode.items]: cada línea para quien la marcó (si nadie la marcó,
/// entre todos) y luego se escala al total pagado. Por eso la propina, el
/// pan o un descuento se reparten según lo que tomó cada uno.
Map<int, int> previewShares({
  required int amountMinor,
  required SplitMode split,
  required List<int> participants,
  List<TicketItem> items = const <TicketItem>[],
  List<int> weights = const <int>[],
}) {
  final List<int> people = participants.toSet().toList();
  if (people.isEmpty || amountMinor <= 0) return <int, int>{};
  if (split == SplitMode.weights && weights.length == participants.length) {
    return divide(amountMinor, <int, int>{
      for (int i = 0; i < participants.length; i++) participants[i]: weights[i],
    });
  }
  final Map<int, int> equal = <int, int>{for (final int p in people) p: 1};
  if (split != SplitMode.items || items.isEmpty) {
    return divide(amountMinor, equal);
  }
  final Map<int, int> consumed = <int, int>{for (final int p in people) p: 0};
  for (final TicketItem item in items) {
    if (item.priceMinor == 0) continue;
    final List<int> owners = item.claimedBy
        .toSet()
        .where(consumed.containsKey)
        .toList();
    final Map<int, int> parts = divide(item.priceMinor, <int, int>{
      for (final int o in owners.isEmpty ? people : owners) o: 1,
    });
    for (final MapEntry<int, int> e in parts.entries) {
      consumed[e.key] = consumed[e.key]! + e.value;
    }
  }
  if (consumed.values.every((int v) => v == 0)) {
    return divide(amountMinor, equal);
  }
  return divide(amountMinor, consumed);
}

/// La propina de [percent] % sobre [totalMinor], redondeada a la unidad
/// mínima más cercana (10 % de 86,00 € = 8,60 €).
int tipFor(int totalMinor, int percent) => (totalMinor * percent + 50) ~/ 100;
