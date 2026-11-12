// "¿No ves tu vuelo?": la misma búsqueda ya puesta en otros buscadores.
import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/flights/fares_api.dart';
import 'package:eclipta/features/flights/other_searches.dart';

void main() {
  test('Madrid → Varsovia el 26 de diciembre, ida y vuelta, 2 adultos', () {
    final List<OtherSearch> l = otherSearches(
      FareRoute(
        key: 'MAD-WAW',
        origin: 'MAD',
        destination: 'WAW',
        departure: DateTime(2026, 12, 26),
        returnDate: DateTime(2027, 1, 2),
        cabin: 'ECONOMY',
      ),
      2,
    );
    expect(l.map((OtherSearch o) => o.name), <String>[
      'Google Flights',
      'Skyscanner',
      'Kayak',
      'Trip.com',
    ]);
    expect(
      l[0].url.queryParameters['q'],
      'Flights from MAD to WAW on 2026-12-26 returning 2027-01-02 for 2 adults',
    );
    expect(l[1].url.path, '/transport/flights/mad/waw/261226/270102/');
    expect(l[2].url.path, '/flights/MAD-WAW/2026-12-26/2027-01-02/2adults');
    expect(l[3].url.queryParameters['triptype'], 'rt');
    expect(l.every((OtherSearch o) => o.url.scheme == 'https'), isTrue);
  });

  test('solo ida', () {
    final List<OtherSearch> l = otherSearches(
      FareRoute(
        key: 'MAD-WAW',
        origin: 'MAD',
        destination: 'WAW',
        departure: DateTime(2026, 12, 26),
        cabin: 'ECONOMY',
      ),
      1,
    );
    expect(l[0].url.queryParameters['q'], contains('one way'));
    expect(l[3].url.queryParameters.containsKey('rdate'), isFalse);
  });
}
