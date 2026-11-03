// Billetes: las formas de juntar una cantidad, y banderas de las monedas.
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/money/banknotes.dart';
import 'package:eclipta/features/money/currency_info.dart';

void main() {
  test('50 € = 1 de 50, o 2 de 20 y 1 de 10, o 5 de 10', () {
    final List<NoteMix> m = noteMixes(50, 'EUR');
    expect(m.map((NoteMix x) => x.piles.toString()).toList(), <String>[
      '[1×50]',
      '[2×20, 1×10]',
      '[5×10]',
    ]);
    expect(m.every((NoteMix x) => x.rest == 0), isTrue);
  });

  test('lo que no llega a billete va en monedas', () {
    final NoteMix m = noteMixes(8161, 'JPY').first;
    expect(m.piles.toString(), '[1×5000, 1×2000, 1×1000]');
    expect(m.rest, 161);
    // Una moneda sin tabla oficial: no se inventan billetes.
    expect(noteMixes(100, 'XXX'), isEmpty);
    expect(noteMixes(3, 'EUR'), isEmpty);
  });

  test('banderas sin imágenes', () {
    expect(currencyFlag('GBP'), '🇬🇧');
    expect(currencyFlag('EUR'), '🇪🇺');
    expect(currencyFlag('XXX'), '');
    // Todas las de la tabla de billetes tienen una fuente https.
    for (final BanknoteSet s in banknotes.values) {
      expect(s.source, startsWith('https://'));
    }
  });

  test('monedas: las más grandes primero, y nada si no las conocemos', () {
    // 1,88 € = 1 € + 50 + 20 + 10 + 5 + 2 + 1 céntimos.
    expect(coinPiles(188, 'EUR'), const <NotePile>[
      NotePile(100, 1),
      NotePile(50, 1),
      NotePile(20, 1),
      NotePile(10, 1),
      NotePile(5, 1),
      NotePile(2, 1),
      NotePile(1, 1),
    ]);
    expect(coinPiles(161, 'JPY'), const <NotePile>[
      NotePile(100, 1),
      NotePile(50, 1),
      NotePile(10, 1),
      NotePile(1, 1),
    ]);
    expect(coinPiles(100, 'XXX'), isEmpty);
    expect(coinPiles(0, 'EUR'), isEmpty);
  });
}
