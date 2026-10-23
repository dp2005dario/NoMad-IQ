// Tests de los avisos push: abrir el aviso, guardar las claves y el registro
// del móvil en el notifier (con un servidor y un Firebase falsos).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:nomadiq/auth/session.dart';
import 'package:nomadiq/core/api_client.dart';
import 'package:nomadiq/core/money.dart';
import 'package:nomadiq/core/router.dart';
import 'package:nomadiq/features/push/hpke.dart';
import 'package:nomadiq/features/push/notices.dart' show noticeTexts;
import 'package:nomadiq/features/push/push_notice.dart';
import 'package:nomadiq/features/push/push_registrar.dart';
import 'package:nomadiq/features/push/push_state.dart';
import 'package:nomadiq/l10n/generated/app_localizations.dart';

import 'helpers.dart';

// El mismo aviso que en hpke_test.dart, cifrado por el notifier (Go).
Uint8List b64(String s) => base64Url.decode(base64Url.normalize(s));
final Uint8List sk = b64('iWYVFh1cTatr6Zu2mxgPIshusKwbiRLpWO1d0IgTVzs');
const String envelope =
    '3okjpnXQIYDN19AJe6QEueHikw1WZculjRdlAGNheTtNif1tqEBhMLXtrRqUIcgPeMjeEYLH'
    'rbrHIE7hx0oj_JvU36G0lqApKaa6PjzpdvjttjNJeBbuXijtt2dI_avMmCYJd86-pQoM5kiR'
    'yGcIEWmpMF6RrTYYufm16jb39kPHD1q6p2hRMBIZF8nd3pDOjaNOdSFr_c4dthFBr1bTt2YV'
    '7spoEy6uC_Lhs72I0hKcoqFN84AMMjqjMyELGBeEHB07WA';
const String deviceId = '3b241101-e2bb-4255-8caf-4136c566a962';
const String zoneId = '6f1c2a10-0000-4000-8000-000000000001';

PushState stateWith(Uint8List current, {Uint8List? previous}) => PushState(
  deviceId: deviceId,
  currentKey: current,
  keyCreatedAt: DateTime.utc(2026, 10, 1),
  previousKey: previous,
  confirmed: true,
);

/// Firebase falso.
class FakeTransport implements PushTransport {
  String? current = 'fcm-token-1';
  int deleted = 0;
  final StreamController<String> refresh = StreamController<String>.broadcast();

  @override
  Future<String?> token() async => current;

  @override
  Stream<String> get tokenRefresh => refresh.stream;

  @override
  Future<void> deleteToken() async {
    deleted++;
    current = null;
  }
}

/// El notifier falso: guarda los móviles registrados (y de quién son).
class FakeNotifier {
  FakeNotifier(this.g);

  final FakeGateway g;
  final Map<String, Map<String, Object?>> devices =
      <String, Map<String, Object?>>{};

  /// Ids que "ya son de otra cuenta" (responden 409).
  final Set<String> taken = <String>{};

  void route(String id) {
    g.services['/v1/devices/$id'] = (http.Request r) {
      if (r.method == 'DELETE') {
        devices.remove(id);
        return http.Response('', 204);
      }
      if (taken.contains(id)) return http.Response('{}', 409);
      devices[id] = jsonDecode(r.body) as Map<String, Object?>;
      return http.Response('', 204);
    };
  }
}

void main() {
  group('aviso', () {
    test('se abre con la clave actual o con la anterior', () async {
      // La fecha del aviso va dentro: la sacamos para fijar el "ahora".
      final Uint8List clear = await hpkeOpen(
        privateKey: sk,
        envelope: b64(envelope),
        aad: ascii.encode(deviceId),
      );
      final DateTime at = DateTime.parse(
        (jsonDecode(utf8.decode(clear)) as Map<String, Object?>)['at']!
            as String,
      );
      final Map<String, Object?> data = <String, Object?>{
        'v': '1',
        'p': envelope,
      };

      final PushNotice? n = await PushNotice.open(
        data,
        stateWith(sk),
        now: at.add(const Duration(minutes: 1)),
      );
      expect(n?.kind, PushKind.zoneAudioguide);
      expect(n?.zoneId, zoneId);
      expect(n?.route, Routes.audioguide(zoneId, ''));
      expect(n?.urgent, isFalse);

      // Recién cambiada la clave: el aviso viene con la anterior.
      final PushKeyPair fresh = await PushKeyPair.generate();
      final PushNotice? old = await PushNotice.open(
        data,
        stateWith(fresh.privateKey, previous: sk),
        now: at,
      );
      expect(old?.zoneId, zoneId);

      // Con otras claves, de hace horas o con otro formato: nada.
      expect(
        await PushNotice.open(data, stateWith(fresh.privateKey), now: at),
        isNull,
      );
      expect(
        await PushNotice.open(
          data,
          stateWith(sk),
          now: at.add(const Duration(hours: 2)),
        ),
        isNull,
      );
      expect(
        await PushNotice.open(<String, Object?>{
          'v': '2',
          'p': envelope,
        }, stateWith(sk)),
        isNull,
      );
      expect(
        await PushNotice.open(<String, Object?>{
          'v': '1',
          'p': '%%%',
        }, stateWith(sk)),
        isNull,
      );
    });

    test('solo entiende tipos y zonas conocidos', () {
      Map<String, Object?> json(String type, String zone) => <String, Object?>{
        'v': 1,
        'type': type,
        'zone_id': zone,
        'zone_kind': 'ZONE_KIND_RESTRICTED',
        'lang': 'es',
        'at': '2026-10-23T10:00:00Z',
      };
      final PushNotice? safety = PushNotice.fromJson(
        json('zone_safety', zoneId),
      );
      expect(safety?.urgent, isTrue);
      expect(safety?.route, Routes.map);
      expect(
        PushNotice.fromJson(json('airport_arrival', zoneId))?.route,
        startsWith('/soon/'),
      );
      expect(PushNotice.fromJson(json('flash_sale', zoneId)), isNull);
      // Un zone_id raro nunca llega a formar una ruta.
      expect(PushNotice.fromJson(json('zone_safety', '../signin')), isNull);
      expect(PushNotice.fromJson('hola'), isNull);
    });

    test('las claves guardadas se leen igual; si están rotas, se ignoran', () {
      final PushState s = stateWith(
        sk,
        previous: Uint8List(32),
      ).copyWith(token: 't', registeredAt: DateTime.utc(2026, 10, 2));
      final PushState back = PushState.fromJson(
        jsonDecode(jsonEncode(s.toJson())),
      )!;
      expect(back.deviceId, deviceId);
      expect(back.currentKey, sk);
      expect(back.previousKey, Uint8List(32));
      expect(back.confirmed, isTrue);
      expect(back.token, 't');
      expect(PushState.fromJson(<String, Object?>{'device_id': 1}), isNull);
    });
  });

  group('alerta de precio', () {
    const String alertId = '5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d';
    Map<String, Object?> fare([Map<String, Object?> change = const {}]) =>
        <String, Object?>{
          'v': 1,
          'type': 'fare_alert',
          'alert_id': alertId,
          'alert_type': 'error_fare',
          'origin': 'MAD',
          'destination': 'NRT',
          'departure': '2027-03-15',
          'cabin': 'ECONOMY',
          'price': <String, Object?>{'amount_minor': 31500, 'currency': 'EUR'},
          'drop_bp': 6500,
          'at': '2026-10-23T10:00:00Z',
          ...change,
        };

    test('se entiende y lleva a tus alertas de precio', () {
      final PushNotice? n = PushNotice.fromJson(fare());
      expect(n?.kind, PushKind.fareAlert);
      expect(n?.fare?.kind, FareAlertKind.errorFare);
      expect(n?.fare?.origin, 'MAD');
      expect(n?.fare?.departure, DateTime(2027, 3, 15));
      expect(n?.fare?.amountMinor, 31500);
      expect(n?.route, Routes.fareAlerts);
      // Dos alertas distintas no se pisan en la barra de notificaciones.
      final PushNotice? other = PushNotice.fromJson(
        fare(<String, Object?>{
          'alert_id': '6b5c4d3e-2f10-4b0c-9d8e-7f6a5b4c3d2e',
        }),
      );
      expect(other?.notificationId, isNot(n?.notificationId));
    });

    test('con datos raros no se avisa', () {
      for (final Map<String, Object?> bad in <Map<String, Object?>>[
        <String, Object?>{'alert_type': 'flash_sale'},
        <String, Object?>{'alert_id': '../signin'},
        <String, Object?>{'origin': 'mad'},
        <String, Object?>{'departure': '2027-03-15T10:00:00Z'},
        <String, Object?>{'drop_bp': 20000},
        <String, Object?>{
          'price': <String, Object?>{'amount_minor': 0, 'currency': 'EUR'},
        },
        <String, Object?>{
          'price': <String, Object?>{'amount_minor': 100, 'currency': 'euro'},
        },
      ]) {
        expect(PushNotice.fromJson(fare(bad)), isNull, reason: '$bad');
      }
    });

    test('el texto sale en el idioma del usuario', () async {
      final PushNotice n = PushNotice.fromJson(fare())!;
      final (String title, String body) = await noticeTexts(
        n,
        lookupAppLocalizations(const Locale('es')),
      );
      expect(title, 'Posible tarifa error');
      expect(body, startsWith('MAD → NRT · 15 mar'));
      expect(body, contains('315'));
      expect(body, contains('€'));
      expect(body, endsWith('(−65 %)'));
      final (String enTitle, String enBody) = await noticeTexts(
        n,
        lookupAppLocalizations(const Locale('en')),
      );
      expect(enTitle, 'Possible error fare');
      expect(enBody, 'MAD → NRT · Mar 15: €315 (−65%)');
      // Sin bajada (precio objetivo): sin porcentaje.
      final PushNotice target = PushNotice.fromJson(
        fare(<String, Object?>{'alert_type': 'target_reached', 'drop_bp': 0}),
      )!;
      final (_, String plain) = await noticeTexts(
        target,
        lookupAppLocalizations(const Locale('en')),
      );
      expect(plain, 'MAD → NRT · Mar 15: €315');
    });

    test('los precios se escriben como en cada país', () {
      expect(formatMoney(31500, 'EUR', 'en', compact: true), '€315');
      expect(formatMoney(3999, 'EUR', 'en'), '€39.99');
      expect(formatMoney(3999, 'EUR', 'es'), contains('39,99'));
      // El yen no tiene céntimos: 31500 JPY son 31.500 yenes.
      expect(formatMoney(31500, 'JPY', 'en'), '¥31,500');
    });
  });

  group('registro del móvil', () {
    late FakeGateway g;
    late FakeNotifier notifier;
    late FakeTransport fcm;
    late MemoryPushStateStore store;
    late SessionController session;
    late DateTime now;
    late List<String> ids;

    PushRegistrar registrar() => PushRegistrar(
      devices: DevicesApi(
        ApiClient(
          baseUrl: Uri.parse('http://gateway.test'),
          session: session,
          client: g.client,
        ),
      ),
      store: store,
      transport: fcm,
      session: session,
      clock: () => now,
      newDeviceId: () => ids.removeAt(0),
    );

    setUp(() async {
      g = FakeGateway();
      notifier = FakeNotifier(g);
      fcm = FakeTransport();
      store = MemoryPushStateStore();
      now = DateTime.utc(2026, 10, 23, 10);
      ids = <String>[
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
      ];
      ids.forEach(notifier.route);
      session = await signedInSession(g);
    });

    int puts() => g.calls.where((String c) => c.startsWith('PUT')).length;

    test('se registra una vez, con su clave pública, y no repite', () async {
      final PushRegistrar r = registrar()..start();
      await r.sync();
      final PushState s = store.state!;
      expect(s.confirmed, isTrue);
      expect(s.token, 'fcm-token-1');
      final Map<String, Object?> body = notifier.devices[s.deviceId]!;
      expect(body['platform'], 'android');
      expect(body['fcm_token'], 'fcm-token-1');
      // La pública que tiene el servidor es la de NUESTRA privada.
      final PushKeyPair pair = await PushKeyPair.fromPrivate(s.currentKey);
      expect(
        body['public_key'],
        base64Url.encode(pair.publicKey).replaceAll('=', ''),
      );

      await r.sync();
      expect(puts(), 1); // nada cambió: ninguna petición más

      // Firebase cambia el token: se registra otra vez con el nuevo.
      fcm.current = 'fcm-token-2';
      fcm.refresh.add('fcm-token-2');
      await pumpEventQueue();
      await r.sync();
      expect(notifier.devices[s.deviceId]!['fcm_token'], 'fcm-token-2');
      expect(puts(), 2);
      r.dispose();
    });

    test('a los 30 días cambia de clave y guarda la anterior', () async {
      final PushRegistrar r = registrar();
      await r.sync();
      final Uint8List first = store.state!.currentKey;
      now = now.add(const Duration(days: 31));
      await r.sync();
      final PushState s = store.state!;
      expect(s.currentKey, isNot(first));
      expect(s.previousKey, first);
      expect(s.confirmed, isTrue);
      expect(puts(), 2);
    });

    test('si el número ya es de otra cuenta, usa otro', () async {
      notifier.taken.add(ids.first);
      final PushRegistrar r = registrar();
      await r.sync();
      expect(store.state!.deviceId, '22222222-2222-4222-8222-222222222222');
      expect(store.state!.confirmed, isTrue);
    });

    test('sin servidor no se da por registrado (se reintenta)', () async {
      g.failWith = 503;
      final PushRegistrar r = registrar();
      await r.sync();
      expect(store.state!.confirmed, isFalse);
    });

    test('al cerrar sesión: baja, fuera claves y fuera token', () async {
      final PushRegistrar r = registrar()..start();
      await r.sync();
      final String id = store.state!.deviceId;
      await session.signOut();
      expect(g.calls, contains('DELETE /v1/devices/$id'));
      expect(notifier.devices, isEmpty);
      expect(store.state, isNull);
      expect(fcm.deleted, greaterThan(0));
      // Y la baja se hizo ANTES de olvidar los pases (si no, sería un 401).
      expect(
        g.calls.indexOf('DELETE /v1/devices/$id'),
        lessThan(g.calls.indexOf('POST /v1/auth/logout')),
      );
      r.dispose();
    });

    test('un invitado no se registra', () async {
      session = newSession(g)..continueAsGuest();
      final PushRegistrar r = registrar()..start();
      await r.sync();
      expect(store.state, isNull);
      expect(puts(), 0);
      r.dispose();
    });
  });
}
