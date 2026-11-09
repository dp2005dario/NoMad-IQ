// "Viajo con mi perro": cabina o bodega, lo que hace falta para la UE, su
// nombre y foto, y los veterinarios/parques/hoteles de alrededor.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/nearby/nearby_api.dart';
import 'package:eclipta/features/travel_with/travel_with.dart';
import 'package:eclipta/features/travel_with/travel_with_page.dart';
import 'package:eclipta/features/travel_with/travel_with_screen.dart';

import 'helpers.dart';
import 'money_test.dart' as m;
import 'nearby_test.dart' show SolLocation;

const Map<String, Object?> dogJson = <String, Object?>{
  'lat': 40.42,
  'lon': -3.7,
  'attribution': '© OpenStreetMap contributors (ODbL)',
  'spots': <Object?>[
    <String, Object?>{
      'id': 'n1',
      'kind': 'vet',
      'lat': 40.4179,
      'lon': -3.7035,
      'name': 'Clínica Veterinaria Sol',
      'phone': '+34 911 22 33 44',
    },
    <String, Object?>{
      'id': 'n2',
      'kind': 'dog_park',
      'lat': 40.4150,
      'lon': -3.7035,
      'name': 'Parque canino',
    },
    <String, Object?>{
      'id': 'w3',
      'kind': 'pet_stay',
      'lat': 40.4170,
      'lon': -3.7040,
      'name': 'Hotel Can',
      'website': 'https://can.example',
    },
  ],
};

void main() {
  group('mascota', () {
    test('8 kg contando el transportín', () {
      expect(petPlace(petKg: 6, carrierKg: 2), PetPlace.cabin);
      expect(petPlace(petKg: 6.5, carrierKg: 2), PetPlace.hold);
      expect(petPlace(petKg: 30, carrierKg: 0), PetPlace.hold);
    });

    test('la vacuna de la rabia necesita 21 días', () {
      final DateTime puesta = DateTime(2026, 11);
      expect(
        rabiesReady(vaccinated: puesta, flight: DateTime(2026, 11, 21)),
        isFalse,
      );
      expect(
        rabiesReady(vaccinated: puesta, flight: DateTime(2026, 11, 22)),
        isTrue,
      );
    });

    test('las casillas se guardan en el móvil', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      final PetChecks checks = PetChecks(store);
      expect(checks.done(), isEmpty);
      await checks.set(PetCheck.microchip, ready: true);
      await checks.set(PetCheck.passport, ready: true);
      await checks.set(PetCheck.passport, ready: false);
      expect(PetChecks(store).done(), <PetCheck>{PetCheck.microchip});
      // Algo raro guardado no rompe nada.
      await store.writeData(LocalData.petChecks, 'basura');
      expect(PetChecks(store).done(), isEmpty);
    });

    test('nombre y foto del perro: solo en el móvil y sin romperse', () async {
      final MemorySettingsStore store = MemorySettingsStore();
      expect(DogProfile.load(store).name, isNull);
      await const DogProfile().withName('  Luna   la  Bonita ').save(store);
      expect(DogProfile.load(store).name, 'Luna la Bonita');
      expect(DogProfile.cleanName('x' * 50)!.length, DogProfile.maxName);
      expect(DogProfile.cleanName('   '), isNull);
      await DogProfile.load(store).withPhoto('/datos/perro.jpg').save(store);
      final DogProfile back = DogProfile.load(store);
      expect(
        (back.name, back.photoPath),
        ('Luna la Bonita', '/datos/perro.jpg'),
      );
      await store.writeData(LocalData.dogProfile, 'basura');
      expect(DogProfile.load(store).name, isNull);
    });

    test('el servidor dice dog_park y pet_stay', () {
      expect(NearbyKind.parse('dog_park'), NearbyKind.dogPark);
      expect(NearbyKind.parse('pet_stay'), NearbyKind.petStay);
      expect(NearbyKind.parse('vet'), NearbyKind.vet);
      expect(NearbyKind.parse('dogPark'), isNull);
    });
  });

  testWidgets('pantalla: nombre, peso, pasaporte, maleta y veterinarios', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/nearby');
    g.services['/v1/nearby'] = (http.Request r) => FakeGateway.json(dogJson);
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    final List<Uri> links = <Uri>[];
    final List<Uri> maps = <Uri>[];
    final m.PageSpy spy = m.PageSpy();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.travelWith,
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        location: SolLocation(),
        webScene: spy.build,
        openLink: (Uri u) async {
          links.add(u);
          return true;
        },
        openBooking: (Uri u) async {
          maps.add(u);
          return true;
        },
      ),
    );
    Map<String, Object?> data() => spy.data(TravelWithScreen.lastBridge!);
    List<Map<String, Object?>> rows(String key) =>
        (data()[key]! as List<Object?>).cast<Map<String, Object?>>();
    await spy.wait(
      tester,
      () => spy.pages.isNotEmpty && rows('spots').isNotEmpty,
    );
    expect(spy.pages.first, contains('ECLIPTA · Viajo con mi perro'));
    // Sin nombre todavía: "tu perro". Con nombre, se guarda en el móvil.
    final Map<String, Object?> t = data()['t']! as Map<String, Object?>;
    expect(t['mapLabel'], 'Para tu perro, cerca de ti');
    spy.send!('name:Luna');
    await tester.pump();
    expect(DogProfile.load(store).name, 'Luna');
    expect(data()['petH'], 'Pasaporte de Luna para la UE');
    expect(
      (data()['t']! as Map<String, Object?>)['mapLabel'],
      'Para Luna, cerca de ti',
    );

    // 7 kg + 2 de transportín = 9 → bodega. Con 5,5 cabe.
    spy.send!('petKg:7');
    await tester.pump();
    expect(
      (data()['verdict']! as Map<String, Object?>)['h'],
      'Tendrá que ir en bodega',
    );
    expect(rows('chips')[1]['t'], '9 kg con transportín');
    spy.send!('petKg:5,5');
    await tester.pump();
    expect(
      (data()['verdict']! as Map<String, Object?>)['h'],
      'Puede ir contigo en cabina',
    );
    expect(rows('chips').last['t'], 'Va en cabina');

    spy.send!('check:0');
    await spy.wait(tester, () => rows('checks').first['on'] == true);
    expect(store.readData(LocalData.petChecks), contains('microchip'));

    // La maleta se guarda en el móvil.
    spy.send!('bag:2');
    await spy.wait(tester, () => rows('bag')[2]['on'] == true);
    expect(DogBag(store).packed(), <int>{2});

    // Veterinarios: el de Sol, con su teléfono para llamar, y en el mapa.
    expect(rows('spots').first['name'], 'Clínica Veterinaria Sol');
    expect(rows('pins').map((Map<String, Object?> p) => p['k']), <String>[
      'vet',
      'dogPark',
      'petStay',
    ]);
    spy.send!('spot:0:call');
    expect(links.single.toString(), 'tel:+34911223344');
    spy.send!('spot:0:go');
    expect(maps.single.queryParameters['travelmode'], 'walking');
    spy.send!('goNear');
    expect(maps, hasLength(2));

    spy.send!('kind:dogPark');
    await tester.pump();
    expect(rows('spots').single['name'], 'Parque canino');

    spy.send!('kind:petStay');
    await tester.pump();
    spy.send!('spot:0:web');
    expect(links.last.host, 'can.example');
  });

  test('los kilos como se escriben y ningún dato cierra el script', () {
    expect(kgLabel(9), '9');
    expect(kgLabel(7.5), '7,5');
    expect(
      travelWithPageWith('window.ECL=$travelWithMarker;', <String, Object?>{
        'x': '</script>',
      }),
      isNot(contains('</script>')),
    );
    expect(
      travelWithPushScript(<String, Object?>{'x': '<b>'}),
      isNot(contains('<b>')),
    );
  });
}
