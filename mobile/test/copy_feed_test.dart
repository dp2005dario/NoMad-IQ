// Copia este viaje (el muro): la página de la maqueta con los viajes que la gente
// publica en el muro, sus estrellas de verdad y "Copiar este viaje".
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/copy_trip/copied_trips.dart';
import 'package:eclipta/features/copy_trip/copy_page.dart';
import 'package:eclipta/features/copy_trip/shared_trip_api.dart';
import 'package:eclipta/l10n/generated/app_localizations.dart';

import 'helpers.dart';

Map<String, Object?> tripJson({
  String code = '7K2M9QXD',
  bool mine = false,
  int? myRating,
}) => <String, Object?>{
  'code': code,
  'author': 'laura.viaja',
  'title': 'París en 4 días',
  'destination': 'París',
  'days': 4,
  'currency': 'EUR',
  'items': <Object?>[
    <String, Object?>{'kind': 'flight', 'title': 'Vuelo', 'price_minor': 12000},
    <String, Object?>{
      'kind': 'stay',
      'title': 'Hotel Marne',
      'price_minor': 21000,
    },
    <String, Object?>{
      'kind': 'activity',
      'title': 'Louvre',
      'price_minor': 2260,
    },
  ],
  'total_minor': 35260,
  'copies': 3,
  'mine': mine,
  'created_at': '2026-11-04T08:00:00Z',
  'public': true,
  'note': 'Dormimos lejos y fuimos en RER.',
  'rating_avg': 4.5,
  'rating_count': 2,
  'my_rating': myRating,
};

void main() {
  test('dibujo, cara, "hace" y la página sin datos de ejemplo', () {
    final AppLocalizations t = lookupAppLocalizations(const Locale('es'));
    expect(illustrationFor('París, Francia'), 'eiffel');
    expect(illustrationFor('Roma'), 'coliseo');
    expect(illustrationFor('Romania'), 'generic');
    expect(illustrationFor('Disneyland Paris'), 'disney');
    expect(illustrationFor('Lisboa'), 'generic');
    expect(authorSeed('laura.viaja'), authorSeed('laura.viaja'));
    for (final String a in <String>['a', 'b', 'Álex', 'noa']) {
      expect(authorSeed(a), isNot(7)); // el 7 es el logo de ECLIPTA
    }
    final DateTime now = DateTime.utc(2026, 11, 4, 10);
    expect(agoText(t, DateTime.utc(2026, 11, 4, 8), now), 'hace 2 h');
    expect(agoText(t, DateTime.utc(2026, 11, 1, 10), now), 'hace 3 días');

    final SharedTrip trip = SharedTrip.parse(tripJson());
    expect(trip.ratingAvg, 4.5);
    expect(trip.note, 'Dormimos lejos y fuimos en RER.');
    final Map<String, Object?> data = copyPageData(
      t: t,
      language: 'es',
      locale: 'es',
      now: now,
      trips: <SharedTrip>[trip],
      copied: <String>{'7K2M9QXD'},
    );
    final Map<String, Object?> one =
        (data['trips']! as List<Object?>).single! as Map<String, Object?>;
    expect(one['ill'], 'eiffel');
    expect(one['daysT'], '4 días');
    expect(one['cost'], '353 €'); // 352,60 € redondeado
    expect(one['perDay'], '88 €');
    // Las paradas: todo menos el vuelo, con lo que costó cada cosa.
    expect(one['stops'], <Object?>[
      <String, Object?>{'n': 'Hotel Marne', 'p': '210 €'},
      <String, Object?>{'n': 'Louvre', 'p': '23 €'},
    ]);
    expect(one['copied'], isTrue);
    expect(one['votes'], 2);
    final Map<String, Object?> tx = data['t']! as Map<String, Object?>;
    expect(tx['votesN'], '{n} votos');

    final String page = File(copyPage).readAsStringSync();
    expect(page, isNot(contains('Datos de ejemplo')));
    expect(page, isNot(contains('lucia.viaja')));
    expect(page, isNot(contains('Calle Mayor')));
    expect(page, contains(copyMarker));
    final String html = copyPageWith(page, <String, Object?>{
      ...data,
      'msg': '</script>',
    });
    expect(html, isNot(contains('"</script>"')));
  });

  testWidgets('el muro: puntuar y copiar', (WidgetTester tester) async {
    final FakeGateway g = FakeGateway();
    final List<Object?> rated = <Object?>[];
    int copies = 0;
    g.services['/v1/shared-trips/feed'] = (http.Request r) => FakeGateway.json(
      <String, Object?>{
        'items': <Object?>[tripJson(), tripJson(code: 'ABCDEFGH', mine: true)],
      },
    );
    g.services['/v1/shared-trips/7K2M9QXD/rate'] = (http.Request r) {
      rated.add(jsonDecode(r.body));
      return FakeGateway.json(tripJson(myRating: 4));
    };
    g.services['/v1/shared-trips/7K2M9QXD/copy'] = (http.Request r) {
      copies++;
      return FakeGateway.json(tripJson());
    };
    final List<String> pages = <String>[];
    void Function(String)? send;
    final session = await signedInSession(g);
    final services = fakeServices(
      session,
      gateway: g,
      webScene: (String html, void Function(String) onMessage) {
        pages.add(html);
        send = onMessage;
        return const SizedBox.expand();
      },
    );
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.copyTrip(),
      services: services,
    );
    Future<void> wait(bool Function() done) async {
      for (int i = 0; i < 50 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done(), isTrue);
    }

    await wait(
      () =>
          pages.isNotEmpty &&
          (pageData(pages.last)['trips']! as List<Object?>).isNotEmpty,
    );
    final List<Object?> trips = pageData(pages.last)['trips']! as List<Object?>;
    expect(trips, hasLength(2));
    expect((trips[1]! as Map<String, Object?>)['own'], isTrue);

    send!('rate:0:4');
    send!('rate:1:5'); // el tuyo: no se manda
    send!('rate:0:9'); // fuera de 1-5: no se manda
    await wait(() => rated.isNotEmpty);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    expect(rated, <Object?>[
      <String, Object?>{'stars': 4},
    ]);

    send!('copy:0');
    await wait(() => copies == 1);
    final CopiedTrips copied = CopiedTrips(services.prefs);
    expect(copied.all().single.code, '7K2M9QXD');
    expect(copied.all().single.lines, hasLength(3));
  });
}

Map<String, Object?> pageData(String html) => jsonDecode(
  html.substring(html.indexOf('var ECL=') + 8, html.indexOf(';\nvar T=ECL.t')),
) as Map<String, Object?>;
