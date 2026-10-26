// Antes de salir: datos móviles, huella del vuelo y lista de la maleta.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/flights/climate_api.dart';
import 'package:eclipta/features/route/geo.dart';
import 'package:eclipta/features/trip/before_trip.dart';
import 'package:eclipta/features/trip/co2.dart';
import 'package:eclipta/features/trip/plugs.dart';
import 'package:eclipta/features/vault/vault.dart';

import 'helpers.dart';
import 'vault_test.dart' show FakeUnlocker, newVault;

const LatLon mad = LatLon(40.47, -3.56);
const LatLon bcn = LatLon(41.30, 2.08);
const LatLon nrt = LatLon(35.76, 140.39);

MonthClimate climate(int month, double temp, double max, double rain) =>
    MonthClimate.parse(<String, Object?>{
      'month': month,
      'temp_c': temp,
      'temp_max_c': max,
      'rain_mm': rain,
    })!;

void serveClimate(FakeGateway g, {int status = 200}) {
  g.publicPrefixes.add('/v1/climate');
  g.services['/v1/climate'] = (_) => status == 200
      ? FakeGateway.json(<String, Object?>{
          'lat': 35.5,
          'lon': 140.0,
          // Marzo en Tokio: fresco y con poca lluvia.
          'months': <Object?>[
            <String, Object?>{
              'month': 3,
              'temp_c': 9.0,
              'temp_max_c': 14.0,
              'rain_mm': 110.0,
            },
          ],
        })
      : http.Response('{}', status);
}

void main() {
  group('datos móviles', () {
    test('la UE entre sí es gratis, fuera no', () {
      expect(
        roamingFor(homeCountry: 'ES', destination: 'FR'),
        RoamingStatus.free,
      );
      expect(
        roamingFor(homeCountry: 'ES', destination: 'JP'),
        RoamingStatus.abroad,
      );
      // Saliendo de fuera de la UE no hay "roaming como en casa".
      expect(
        roamingFor(homeCountry: 'US', destination: 'ES'),
        RoamingStatus.abroad,
      );
      expect(roamingFor(destination: 'ES'), RoamingStatus.unknown);
      expect(roamingFor(homeCountry: 'ES'), RoamingStatus.unknown);
    });
  });

  group('enchufes', () {
    test('adaptador y transformador según el país', () {
      final Power es = powerOf('ES')!;
      final Power jp = powerOf('JP')!;
      final Power fr = powerOf('FR')!;
      // Japón: otro enchufe (A/B frente a C/F) y 100 V frente a 230 V.
      expect(jp.needsAdapterFrom(es), isTrue);
      expect(jp.needsTransformerFrom(es), isTrue);
      // Francia comparte la clavija C con España: nada que llevar.
      expect(fr.needsAdapterFrom(es), isFalse);
      expect(fr.needsTransformerFrom(es), isFalse);
      // Un país que no está en la tabla: no se inventa.
      expect(powerOf('ZZ'), isNull);
      expect(powerOf(null), isNull);
    });
  });

  group('huella del vuelo', () {
    test('más kilómetros, más kilos; y la escala suma', () {
      final double corto = flightKgCo2(mad, bcn);
      final double largo = flightKgCo2(mad, nrt);
      expect(corto, lessThan(largo));
      // Ida y vuelta es el doble que solo la ida.
      expect(
        flightKgCo2(mad, nrt, roundTrip: false) * 2,
        closeTo(largo, 0.001),
      );
      // Una escala añade un 15 %.
      expect(flightKgCo2(mad, nrt, stops: 1), closeTo(largo * 1.15, 0.001));
      // El mismo sitio no contamina nada.
      expect(flightKgCo2(mad, mad), 0);
    });

    test('el factor por kilómetro baja con la distancia', () {
      expect(gramsPerKm(500), 156);
      expect(gramsPerKm(2000), 130);
      expect(gramsPerKm(9000), 110);
      expect(treesForAYear(220), 10);
    });
  });

  group('la maleta', () {
    test('sale lo que toca por el enchufe, el clima y el roaming', () {
      final List<PackItem> items = packingFor(
        homePower: powerOf('ES'),
        therePower: powerOf('JP'),
        climate: climate(3, 9, 14, 110),
        roaming: RoamingStatus.abroad,
        passportSoon: true,
        noInsurance: true,
      );
      final List<String> ids = items.map((PackItem i) => i.id).toList();
      expect(ids, containsAll(<String>['passport', 'insurance']));
      expect(ids, containsAll(<String>['adapter', 'transformer']));
      // 110 mm de lluvia ≈ 22 días: paraguas. Y 9° de media: abrigo.
      expect(ids, containsAll(<String>['umbrella', 'coat', 'esim', 'offline']));
      expect(ids, isNot(contains('sunscreen')));
    });

    test('un mes caluroso pide crema, y sin datos no se inventa nada', () {
      final List<String> verano = packingFor(climate: climate(8, 26, 33, 10))
          .map((PackItem i) => i.id)
          .toList();
      expect(verano, contains('sunscreen'));
      expect(verano, isNot(contains('coat')));
      expect(verano, isNot(contains('umbrella')));
      // Sin país ni clima solo queda el consejo que vale siempre.
      expect(packingFor().map((PackItem i) => i.id).toList(), <String>[
        'offline',
      ]);
    });

    test('lo marcado se guarda en el móvil y mueve el porcentaje', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      final PackList list = PackList(store);
      expect(list.done(), isEmpty);
      await list.setDone('offline', ready: true);
      await list.setDone('esim', ready: true);
      await list.setDone('esim', ready: false);
      expect(list.done(), <String>{'offline'});
      // Otro PackList sobre el mismo móvil ve lo mismo.
      expect(PackList(store).done(), <String>{'offline'});

      final List<PackItem> items = <PackItem>[
        const PackItem('offline', PackKind.offline),
        const PackItem('esim', PackKind.esim),
      ];
      expect(readiness(items, list.done()), 0.5);
      expect(readiness(items, <String>{}), 0);
      expect(readiness(<PackItem>[], <String>{}), 1);
    });

    test('una lista guardada rota no rompe la pantalla', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      await store.writeData(LocalData.packing, 'no es json');
      expect(PackList(store).done(), isEmpty);
      await store.writeData(LocalData.packing, '{"a":1}');
      expect(PackList(store).done(), isEmpty);
      await store.writeData(LocalData.packing, '["offline", 7]');
      expect(PackList(store).done(), <String>{'offline'});
    });
  });

  testWidgets('pantalla: se pone el viaje y sale la lista con la Bóveda', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway();
    serveClimate(g);
    final SessionController session = await signedInSession(g);
    final FakeUnlocker unlocker = FakeUnlocker();
    final Vault vault = newVault(unlocker);
    await vault.open('x');
    // Un pasaporte que caduca enseguida: tiene que avisar.
    await vault.add(
      kind: DocKind.passport,
      title: 'Pasaporte',
      mime: 'image/jpeg',
      bytes: Uint8List.fromList(<int>[1]),
      expires: DateTime(2027, 1, 1),
    );
    vault.close();
    tester.view.physicalSize = const Size(1200, 5000);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.before,
      services: fakeServices(session, gateway: g, vault: vault),
    );
    // Los aeropuertos de verdad (assets/geo) tardan un poco en cargarse.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 2)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Antes de salir'), findsOneWidget);
    expect(find.textContaining('Dinos a dónde vas'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextField, 'Origen'), 'MAD');
    await tester.enterText(find.widgetWithText(TextField, 'Destino'), 'NRT');
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.event_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ACEPTAR'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    await tester.pumpAndSettle();

    // La Bóveda se abrió (además de la vez que la abrió el propio test).
    expect(unlocker.asked, 2);
    expect(find.textContaining('Tokyo'), findsWidgets);
    // Fuera de la UE: avisa de la eSIM, y pide adaptador para Japón.
    expect(find.textContaining('eSIM'), findsWidgets);
    expect(find.textContaining('Adaptador de enchufe'), findsOneWidget);
    // La sección de enchufes: el dibujo de los de Japón y qué comprar.
    expect(find.text('Tipo A'), findsOneWidget);
    expect(find.text('Tipo B'), findsOneWidget);
    expect(
      find.text('Compra un adaptador para enchufes tipo A, B'),
      findsOneWidget,
    );
    expect(find.text('Seguro de viaje'), findsOneWidget);
    // La huella: el vuelo, la escala y el coche, con el aviso de estimación.
    expect(find.textContaining('kg CO₂'), findsNWidgets(3));
    expect(find.textContaining('Estimación aproximada'), findsOneWidget);

    // Al marcar algo, sube el porcentaje de arriba.
    expect(find.text('0%'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('0%'), findsNothing);
    vault.close(); // que no quede el reloj del cierre automático
  });
}
