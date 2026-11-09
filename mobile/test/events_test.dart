// Qué pasa en tus fechas: festivos y eventos reales (con su fuente), días
// del viaje, filtro por día y guardados (solo en el móvil).
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:eclipta/core/router.dart';
import 'package:eclipta/core/settings.dart';
import 'package:eclipta/features/easy/easy_mode.dart';
import 'package:eclipta/features/events/event_reminders.dart';
import 'package:eclipta/features/events/events_api.dart';
import 'package:eclipta/features/events/events_screen.dart';
import 'package:eclipta/features/route/web_scene.dart';
import 'package:eclipta/features/map/geo.dart';
import 'package:eclipta/features/vault/vault.dart';
import 'package:eclipta/features/vault/vault_store.dart';

import 'helpers.dart';
import 'money_test.dart' as m;

/// La huella siempre "coincide".
class _Finger implements Unlocker {
  int asked = 0;

  @override
  Future<UnlockResult> unlock(String reason) async {
    asked++;
    return UnlockResult.ok;
  }
}

String day(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

WebSceneBridge bridge() => EventsScreen.lastBridge!;

/// Como lo empaqueta la página (base64url sin "=").
String pack(Map<String, Object?> v) =>
    base64Url.encode(utf8.encode(jsonEncode(v))).replaceAll('=', '');

void main() {
  final DateTime start = DateUtils.dateOnly(DateTime.now())
      .add(const Duration(days: 20));

  Map<String, Object?> json() => <String, Object?>{
    'iata': 'LIS',
    'city': 'Lisbon',
    'country': 'PT',
    'start': day(start),
    'end': day(start.add(const Duration(days: 4))),
    'sources': <String>['Nager.Date', 'Ticketmaster'],
    'events': <Object?>[
      <String, Object?>{
        'id': 'h-1',
        'kind': 'holiday',
        'name': 'Dia de Portugal',
        'date': day(start),
        'regional': false,
      },
      <String, Object?>{
        'id': 't-a',
        'kind': 'music',
        'name': 'Concierto en el estadio',
        'date': day(start.add(const Duration(days: 1))),
        'time': '21:00',
        'venue': 'Altice Arena',
        'url': 'https://www.ticketmaster.pt/event/a',
        'price_min': 45,
        'currency': 'EUR',
      },
      <String, Object?>{
        'id': 't-b',
        'kind': 'sports',
        'name': 'Benfica - Porto',
        'date': day(start.add(const Duration(days: 2))),
        'url': 'javascript:alert(1)',
      },
    ],
  };

  test('solo enlaces https y precios con moneda', () {
    final CityEvents e = CityEvents.parse(json());
    expect(e.events[1].priceMin, 45);
    expect(e.events[2].url, isNull);
    expect(e.events[2].priceMin, isNull);
  });

  testWidgets('festivo, concierto con precio del organizador y guardar', (
    WidgetTester tester,
  ) async {
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/events');
    final List<Uri> sent = <Uri>[];
    g.services['/v1/events'] = (http.Request r) {
      sent.add(r.url);
      return FakeGateway.json(json());
    };
    final MemorySettingsStore store = MemorySettingsStore('es');
    await saveEasyTrip(
      store,
      EasyTrip(
        departure: start.add(const Duration(hours: 9)),
        from: 'MAD',
        to: 'LIS',
      ),
    );
    final List<Uri> opened = <Uri>[];
    final MemoryEventReminders reminders = MemoryEventReminders();
    final session = newSession()..continueAsGuest();
    final m.PageSpy spy = m.PageSpy();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.events(),
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        eventReminders: reminders,
        openBooking: (Uri u) async {
          opened.add(u);
          return true;
        },
        webScene: spy.build,
      ),
    );
    await spy.wait(
      tester,
      () =>
          spy.pages.isNotEmpty &&
          (spy.data(bridge())['events']! as List<Object?>).isNotEmpty,
    );

    // Tus fechas del Modo fácil: 5 días desde la salida.
    expect(sent.single.queryParameters, <String, String>{
      'iata': 'LIS',
      'from': day(start),
      'to': day(start.add(const Duration(days: 4))),
    });
    final Map<String, Object?> d = spy.data(bridge());
    expect(d['sub'], startsWith('Lisbon · '));
    expect(d['src'], 'TICKETMASTER');
    expect(d['days'], hasLength(5));
    final List<Object?> ev = d['events']! as List<Object?>;
    Map<String, Object?> at(int i) => ev[i]! as Map<String, Object?>;
    // 1 festivo + 2 eventos = 3 cosas en tus fechas.
    expect(ev, hasLength(3));
    expect(at(0)['price'], 'Festivo: algunas tiendas y museos pueden cerrar');
    expect(at(0)['stTxt'], 'FESTIVO');
    // (Entre el número y el € va un espacio que no se parte.)
    expect(at(1)['price'], matches(r'^Entradas desde 45\s€ en Ticketmaster$'));
    expect(at(1)['when'], contains('21:00 · Altice Arena'));
    // El enlace raro no se enseña.
    expect(at(2)['url'], '');

    spy.send!('open:0:${pack(<String, Object?>{'u': at(1)['url']})}');
    // Uno que no es de los eventos no se abre.
    spy.send!(
      'open:0:${pack(<String, Object?>{'u': 'https://evil.example/'})}',
    );
    await tester.pump();
    expect(opened.single.host, 'www.ticketmaster.pt');

    spy.send!('save:1:${pack(<String, Object?>{'id': 't-b'})}');
    await spy.wait(tester, () => reminders.scheduled['t-b'] != null);
    expect(store.readData(LocalData.savedEvents), '["t-b"]');
    // El partido no tiene hora: solo el aviso de la víspera.
    expect(reminders.scheduled['t-b'], hasLength(1));
  });

  testWidgets('mapa de verdad con los puntos y lo lejos que está tu hotel', (
    WidgetTester tester,
  ) async {
    final Map<String, Object?> data = json();
    final List<Object?> events = data['events']! as List<Object?>;
    (events[1]! as Map<String, Object?>).addAll(<String, Object?>{
      'lat': 38.768,
      'lon': -9.094,
    });
    (events[2]! as Map<String, Object?>).addAll(<String, Object?>{
      'lat': 38.7527,
      'lon': -9.1847,
    });
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/events');
    g.services['/v1/events'] = (http.Request r) => FakeGateway.json(data);
    final MemorySettingsStore store = MemorySettingsStore('es');
    // El hotel ya marcado en Lisboa.
    const GeoPoint hotel = GeoPoint(38.76, -9.10);
    await store.writeData(
      LocalData.eventsHotel,
      '{"iata":"LIS","lat":38.76,"lon":-9.1}',
    );
    final session = newSession()..continueAsGuest();
    final m.PageSpy spy = m.PageSpy();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.events(iata: 'LIS'),
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        webScene: spy.build,
      ),
    );
    await spy.wait(
      tester,
      () =>
          spy.pages.isNotEmpty &&
          (spy.data(bridge())['events']! as List<Object?>).isNotEmpty,
    );
    final Map<String, Object?> d = spy.data(bridge());
    final int walk = (hotel.distanceTo(const GeoPoint(38.768, -9.094)) / 80)
        .round();
    final List<Object?> ev = d['events']! as List<Object?>;
    expect(
      (ev[1]! as Map<String, Object?>)['when'],
      endsWith('a $walk min andando de tu hotel'),
    );
    expect(d['hotel'], isTrue);
    expect(d['sub'], endsWith(' · cerca de tu hotel'));
    // Dos pines: el estadio, a la izquierda (oeste) del hotel.
    final List<Object?> pins = d['pins']! as List<Object?>;
    expect(pins, hasLength(2));
    final Map<String, Object?> far = pins.last! as Map<String, Object?>;
    expect(far['id'], 't-b');
    expect(far['x']! as int, lessThan(50));
  });

  testWidgets('el hotel sale de una reserva de la Bóveda y lo eliges tú', (
    WidgetTester tester,
  ) async {
    final Map<String, Object?> data = json();
    final List<Object?> events = data['events']! as List<Object?>;
    (events[1]! as Map<String, Object?>).addAll(<String, Object?>{
      'lat': 38.768,
      'lon': -9.094,
    });
    (events[2]! as Map<String, Object?>).addAll(<String, Object?>{
      'lat': 38.7527,
      'lon': -9.1847,
    });
    final FakeGateway g = FakeGateway()..publicPrefixes.add('/v1/events');
    g.services['/v1/events'] = (http.Request r) => FakeGateway.json(data);
    final List<String> asked = <String>[];
    g.services['/v1/geocode'] = (http.Request r) {
      asked.add(r.url.queryParameters['q']!);
      return FakeGateway.json(<String, Object?>{
        'items': <Object?>[
          <String, Object?>{
            'name': 'Avenida Palace',
            'address': 'Rua 1º de Dezembro 123, Lisboa, Portugal',
            'lat': 38.7146,
            'lon': -9.1408,
          },
        ],
        'source': 'OpenStreetMap (Nominatim)',
      });
    };
    final MemorySettingsStore store = MemorySettingsStore('es');
    final _Finger finger = _Finger();
    final Vault vault = Vault(
      keys: MemoryVaultKeyStore(),
      files: MemoryVaultFiles(),
      unlocker: finger,
    );
    // Una reserva guardada en la Bóveda (el título lo escribió la persona).
    await vault.open('test');
    await vault.add(
      kind: DocKind.booking,
      title: 'Hotel Avenida Palace',
      mime: 'image/jpeg',
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    vault.close();
    final session = await signedInSession(g);
    final m.PageSpy spy = m.PageSpy();
    await pumpApp(
      tester,
      locale: 'es',
      session: session,
      initialLocation: Routes.events(iata: 'LIS'),
      services: fakeServices(
        session,
        gateway: g,
        prefs: store,
        map: FakeMap(),
        vault: vault,
        webScene: spy.build,
      ),
    );
    await spy.wait(
      tester,
      () =>
          spy.pages.isNotEmpty &&
          (spy.data(bridge())['events']! as List<Object?>).isNotEmpty,
    );
    // Tocando la ciudad y las fechas: "Marca tu hotel".
    spy.send!('options');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Marca tu hotel para ver qué te pilla cerca'));
    await tester.pumpAndSettle();
    expect(find.text('¿Dónde está tu hotel?'), findsOneWidget);

    // La Bóveda está cerrada: se abre con la huella y sale la reserva.
    await tester.tap(find.text('Mirar mis reservas de la Bóveda'));
    await tester.pumpAndSettle();
    expect(finger.asked, 2);
    await tester.tap(find.text('Hotel Avenida Palace'));
    await tester.pumpAndSettle();
    // Se busca el título que escribiste, no se lee el documento.
    expect(asked, <String>['Hotel Avenida Palace']);
    expect(find.text('Avenida Palace'), findsOneWidget);
    await tester.tap(find.text('Avenida Palace'));
    await tester.pumpAndSettle();

    expect(store.readData(LocalData.eventsHotel), contains('38.7146'));
    await spy.wait(tester, () => spy.data(bridge())['hotel'] == true);
    vault.close();
  });
}
