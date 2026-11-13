// Explorar: la página de la maqueta con el clima real de cada país.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/features/flights/climate_api.dart';
import 'package:eclipta/features/flights/explore_screen.dart';
import 'package:eclipta/l10n/generated/app_localizations.dart';

import 'helpers.dart';

List<Object?> year(double temp, double rain) => <Object?>[
  for (int m = 0; m < 12; m++) <Object?>[temp + m, rain],
];

void main() {
  test(
    'datos de los países (Banco Mundial): se leen, se guardan y se juntan',
    () {
      final CountryClimate c = CountryClimate.parse(<String, Object?>{
        'complete': false,
        'countries': <String, Object?>{'ES': year(10, 40)},
        'facts': <String, Object?>{
          'ES': <String, Object?>{
            'arrivals': 83700000,
            'price': 0.62,
            'homicides': 0.6,
            'population': 48000000,
            'capital': 'Madrid',
          },
          'FR': <String, Object?>{'price': -1, 'capital': 7}, // todo raro
          'xx': <String, Object?>{'arrivals': 1},
        },
      });
      expect(c.facts.keys, <String>['ES']);
      expect(c.facts['ES']!.capital, 'Madrid');
      // Lo guardado en el móvil se vuelve a leer igual.
      final CountryClimate again = CountryClimate.parse(
        jsonDecode(jsonEncode(c.toJson())),
      );
      expect(again.byCountry['ES'], c.byCountry['ES']);
      expect(again.facts['ES']!.arrivals, 83700000);
      // Lo nuevo del servidor se suma a lo guardado.
      final CountryClimate merged = again.merge(
        CountryClimate.parse(<String, Object?>{
          'complete': true,
          'countries': <String, Object?>{'JP': year(5, 90)},
        }),
      );
      expect(merged.byCountry.keys, containsAll(<String>['ES', 'JP']));
      expect(merged.complete, isTrue);
      expect(merged.facts['ES']!.price, 0.62);
    },
  );

  test('el clima de los países: solo lo que está bien formado', () {
    final CountryClimate c = CountryClimate.parse(<String, Object?>{
      'complete': true,
      'countries': <String, Object?>{
        'ES': year(10, 40),
        'JP': <Object?>[
          <Object?>[1, 2],
        ], // le faltan meses
        'xx': year(1, 1), // código raro
        'FR': <Object?>[for (int m = 0; m < 12; m++) 'nada'],
      },
    });
    expect(c.complete, isTrue);
    expect(c.byCountry.keys, <String>['ES']);
    expect(c.byCountry['ES']![3], <double>[13, 40]);
    expect(CountryClimate.parse('nada').byCountry, isEmpty);
  });

  test(
    'la página lleva los textos y el clima, y nada puede cerrar el script',
    () {
      final String page = File('assets/explore/explorar.html')
          .readAsStringSync();
      // La maqueta ya no trae datos de ejemplo ni sus notas.
      expect(page, isNot(contains('Datos de ejemplo')));
      expect(page, isNot(contains('datos de ejemplo')));
      expect(page, contains(exploreMarker));
      final String html = explorePageWith(
        page,
        language: 'es',
        texts: <String, String>{'title': 'Explorar </script>'},
        climate: CountryClimate.parse(<String, Object?>{
          'countries': <String, Object?>{'ES': year(10, 40)},
        }),
      );
      expect(html, isNot(contains(exploreMarker)));
      expect(html, contains(r'"title":"Explorar <\/script>"'));
      expect(html, contains('"ES":[[10.0,40.0]'));
    },
  );

  testWidgets('abre la maqueta con el clima del servidor y en tu idioma', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    int asked = 0;
    g.publicPrefixes.add('/v1/climate');
    g.services['/v1/climate/countries'] = (http.Request r) {
      asked++;
      return FakeGateway.json(<String, Object?>{
        'complete': true,
        'countries': <String, Object?>{'ES': year(10, 40)},
      });
    };
    final List<String> pages = <String>[];
    final SessionController session = await signedInSession(g);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.explore(),
      services: fakeServices(
        session,
        gateway: g,
        webScene: (String html, void Function(String) _) {
          pages.add(html);
          return const SizedBox.expand();
        },
      ),
    );
    // La página (casi 1 MB) se lee de los assets de verdad.
    for (int i = 0; i < 10 && pages.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
    }
    expect(asked, 1);
    expect(pages, isNotEmpty);
    final String html = pages.last;
    final Map<String, Object?> data = jsonDecode(
      html.substring(
        html.indexOf('var ECL=') + 8,
        html.indexOf(';\nvar T=ECL.t'),
      ),
    ) as Map<String, Object?>;
    expect(data['lang'], 'es');
    final AppLocalizations t = lookupAppLocalizations(const Locale('es'));
    expect((data['t']! as Map<String, Object?>)['title'], t.exwTitle);
    expect((data['t']! as Map<String, Object?>)['count'], '{n} de {total}');
    expect((data['climate']! as Map<String, Object?>).keys, <String>['ES']);
  });
}
