// "Viajo con mi perro": cabina o bodega, lo que hace falta para la UE, su
// nombre y foto, y los veterinarios/parques/hoteles de alrededor.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/auth/session.dart';
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/nearby/nearby_api.dart';
import 'package:eclipta/features/travel_with/travel_with.dart';

import 'helpers.dart';
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

  testWidgets('pantalla: nombre, peso y veterinarios cerca', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/nearby');
    g.services['/v1/nearby'] = (http.Request r) => FakeGateway.json(dogJson);
    final SessionController session = await signedInSession(g);
    final MemorySettingsStore store = MemorySettingsStore();
    final List<Uri> links = <Uri>[];
    final List<Uri> maps = <Uri>[];
    tester.view.physicalSize = const Size(1200, 5200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
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
    await tester.pumpAndSettle();
    expect(find.text('Viajo con mi perro'), findsOneWidget);
    // Sin nombre todavía: "tu perro". Con nombre, se guarda en el móvil.
    expect(find.text('Para tu perro, cerca de ti'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Nombre de tu perro'),
      'Luna',
    );
    await tester.pumpAndSettle();
    expect(find.text('Para Luna, cerca de ti'), findsOneWidget);
    expect(DogProfile.load(store).name, 'Luna');

    // 7 kg + 2 de transportín = 9 → bodega. Con 5,5 cabe.
    await tester.enterText(
      find.widgetWithText(TextField, 'Peso de tu mascota (kg)'),
      '7',
    );
    await tester.pumpAndSettle();
    expect(find.text('Tendrá que ir en bodega'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Peso de tu mascota (kg)'),
      '5,5',
    );
    await tester.pumpAndSettle();
    expect(find.text('Puede ir contigo en cabina'), findsOneWidget);

    await tester.tap(find.text('Microchip'));
    await tester.pumpAndSettle();
    expect(store.readData(LocalData.petChecks), contains('microchip'));

    // Veterinarios: el de Sol, con su teléfono para llamar.
    expect(find.text('Clínica Veterinaria Sol'), findsOneWidget);
    await tester.tap(find.byTooltip('Llamar'));
    expect(links.single.toString(), 'tel:+34911223344');
    await tester.tap(find.byTooltip('Ir'));
    expect(maps.single.queryParameters['travelmode'], 'walking');

    await tester.tap(find.widgetWithText(ChoiceChip, 'Parques para perros'));
    await tester.pumpAndSettle();
    expect(find.text('Parque canino'), findsOneWidget);
    expect(find.text('Clínica Veterinaria Sol'), findsNothing);

    await tester.tap(
      find.widgetWithText(ChoiceChip, 'Hoteles que admiten perros'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Web'));
    expect(links.last.host, 'can.example');
  });
}
