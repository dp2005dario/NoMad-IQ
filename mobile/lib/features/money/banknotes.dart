// "¿Qué billetes son?": 50 € = 1 de 50, o 2 de 20 y 1 de 10.
//
// Los valores de los billetes que se emiten hoy en cada moneda, con la web
// del banco central que los publica (para comprobarlos). Solo están las
// monedas cuyos billetes conocemos con seguridad: si una no está, la app no
// enseña billetes (mejor nada que un billete que no existe).
//
// Los billetes se DIBUJAN (un rectángulo con su valor): no se usan fotos de
// billetes reales porque muchos bancos centrales no permiten reproducirlos.

class BanknoteSet {
  const BanknoteSet(this.notes, this.source);

  /// Los valores, de menor a mayor.
  final List<int> notes;

  /// La web oficial del banco central.
  final String source;
}

const Map<String, BanknoteSet> banknotes = <String, BanknoteSet>{
  'EUR': BanknoteSet(<int>[
    5,
    10,
    20,
    50,
    100,
    200,
  ], 'https://www.ecb.europa.eu/euro/banknotes/'),
  'USD': BanknoteSet(<int>[
    1,
    2,
    5,
    10,
    20,
    50,
    100,
  ], 'https://www.uscurrency.gov/denominations'),
  'GBP': BanknoteSet(<int>[
    5,
    10,
    20,
    50,
  ], 'https://www.bankofengland.co.uk/banknotes'),
  'JPY': BanknoteSet(<int>[
    1000,
    2000,
    5000,
    10000,
  ], 'https://www.boj.or.jp/en/note_tfjgs/note/'),
  'CHF': BanknoteSet(<int>[
    10,
    20,
    50,
    100,
    200,
    1000,
  ], 'https://www.snb.ch/en/the-snb/mandates-goals/cash/banknotes'),
  'CAD': BanknoteSet(<int>[
    5,
    10,
    20,
    50,
    100,
  ], 'https://www.bankofcanada.ca/banknotes/'),
  'AUD': BanknoteSet(<int>[
    5,
    10,
    20,
    50,
    100,
  ], 'https://banknotes.rba.gov.au/'),
  'NZD': BanknoteSet(<int>[
    5,
    10,
    20,
    50,
    100,
  ], 'https://www.rbnz.govt.nz/money-and-cash/notes-and-coins'),
  'CNY': BanknoteSet(<int>[
    1,
    5,
    10,
    20,
    50,
    100,
  ], 'https://www.pbc.gov.cn/en/'),
  'MXN': BanknoteSet(<int>[
    20,
    50,
    100,
    200,
    500,
    1000,
  ], 'https://www.banxico.org.mx/banknotes-and-coins/'),
  'SEK': BanknoteSet(<int>[
    20,
    50,
    100,
    200,
    500,
    1000,
  ], 'https://www.riksbank.se/en-gb/payments--cash/notes--coins/'),
  'NOK': BanknoteSet(<int>[
    50,
    100,
    200,
    500,
    1000,
  ], 'https://www.norges-bank.no/en/topics/notes-and-coins/'),
  // El billete de 1000 coronas dejó de valer el 31-05-2025.
  'DKK': BanknoteSet(<int>[
    50,
    100,
    200,
    500,
  ], 'https://www.nationalbanken.dk/en/banknotes-and-coins'),
  'PLN': BanknoteSet(<int>[
    10,
    20,
    50,
    100,
    200,
    500,
  ], 'https://nbp.pl/en/banknotes-and-coins/'),
  'CZK': BanknoteSet(<int>[
    100,
    200,
    500,
    1000,
    2000,
    5000,
  ], 'https://www.cnb.cz/en/banknotes-and-coins/'),
  'HUF': BanknoteSet(<int>[
    500,
    1000,
    2000,
    5000,
    10000,
    20000,
  ], 'https://www.mnb.hu/en/banknotes-and-coins'),
  'KRW': BanknoteSet(<int>[
    1000,
    5000,
    10000,
    50000,
  ], 'https://www.bok.or.kr/eng/main/contents.do?menuNo=400223'),
  'THB': BanknoteSet(<int>[
    20,
    50,
    100,
    500,
    1000,
  ], 'https://www.bot.or.th/en/our-roles/banknotes.html'),
  'HKD': BanknoteSet(<int>[
    10,
    20,
    50,
    100,
    500,
    1000,
  ], 'https://www.hkma.gov.hk/eng/key-functions/money/banknotes-and-coins/'),
  'ZAR': BanknoteSet(<int>[
    10,
    20,
    50,
    100,
    200,
  ], 'https://www.resbank.co.za/en/home/what-we-do/currency'),
  'BRL': BanknoteSet(<int>[
    2,
    5,
    10,
    20,
    50,
    100,
    200,
  ], 'https://www.bcb.gov.br/en/banknotesandcoins'),
};

/// Un montón de billetes iguales ("2 de 20").
class NotePile {
  const NotePile(this.value, this.count);

  final int value;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is NotePile && other.value == value && other.count == count;

  @override
  int get hashCode => Object.hash(value, count);

  @override
  String toString() => '$count×$value';
}

/// Una forma de juntar la cantidad con billetes, y lo que falta en monedas.
class NoteMix {
  const NoteMix(this.piles, this.rest);

  final List<NotePile> piles;

  /// Lo que no llega al billete más pequeño (va en monedas).
  final int rest;

  int get notes => piles.fold(0, (int a, NotePile p) => a + p.count);
}

/// Con los billetes más grandes primero (los menos billetes posibles), y
/// sin pasar de [maxNote] si se da.
NoteMix greedyMix(int amount, List<int> notes, {int? maxNote}) {
  int left = amount;
  final List<NotePile> piles = <NotePile>[];
  for (final int note in notes.reversed) {
    if (maxNote != null && note > maxNote) continue;
    final int n = left ~/ note;
    if (n > 0) {
      piles.add(NotePile(note, n));
      left -= n * note;
    }
  }
  return NoteMix(piles, left);
}

/// Hasta tres maneras distintas: la de menos billetes y, después, sin los
/// billetes más grandes (más fáciles de usar en tiendas pequeñas).
List<NoteMix> noteMixes(int amount, String currency) {
  final BanknoteSet? set = banknotes[currency];
  if (set == null || amount <= 0) return const <NoteMix>[];
  final List<NoteMix> out = <NoteMix>[];
  int? cap;
  while (out.length < 3) {
    final NoteMix mix = greedyMix(amount, set.notes, maxNote: cap);
    if (mix.piles.isEmpty) break;
    // Demasiados billetes ya no ayudan a nadie.
    if (mix.notes > 20) break;
    if (out.every((NoteMix m) => !_same(m, mix))) out.add(mix);
    final int biggest = mix.piles.first.value;
    final int i = set.notes.indexOf(biggest);
    if (i <= 0) break;
    cap = set.notes[i - 1];
  }
  return out;
}

bool _same(NoteMix a, NoteMix b) =>
    a.piles.length == b.piles.length &&
    <int>[for (int i = 0; i < a.piles.length; i++) i]
        .every((int i) => a.piles[i] == b.piles[i]);
