// El descifrado de avisos debe abrir EXACTAMENTE lo que cifra el notifier
// (Go). El vector de abajo lo generó services/notifier/internal/sealbox con
// una clave y un azar fijos: si alguno de los dos lados cambia, esto falla.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:eclipta/features/push/hpke.dart';

Uint8List b64(String s) => base64Url.decode(base64Url.normalize(s));

const String sk = 'iWYVFh1cTatr6Zu2mxgPIshusKwbiRLpWO1d0IgTVzs';
const String pk = 'X9R2M7XkP8p7rRv75CT-rLF12dTUow8Wbb0wY28LRGs';
const String env =
    '3okjpnXQIYDN19AJe6QEueHikw1WZculjRdlAGNheTtNif1tqEBhMLXtrRqUIcgPeMjeEYLH'
    'rbrHIE7hx0oj_JvU36G0lqApKaa6PjzpdvjttjNJeBbuXijtt2dI_avMmCYJd86-pQoM5kiR'
    'yGcIEWmpMF6RrTYYufm16jb39kPHD1q6p2hRMBIZF8nd3pDOjaNOdSFr_c4dthFBr1bTt2YV'
    '7spoEy6uC_Lhs72I0hKcoqFN84AMMjqjMyELGBeEHB07WA';
final Uint8List deviceId = ascii.encode('3b241101-e2bb-4255-8caf-4136c566a962');

void main() {
  test('abre un aviso cifrado por el notifier (vector de Go)', () async {
    final Uint8List clear = await hpkeOpen(
      privateKey: b64(sk),
      envelope: b64(env),
      aad: deviceId,
    );
    final Map<String, Object?> json =
        jsonDecode(utf8.decode(clear)) as Map<String, Object?>;
    expect(json['type'], 'zone_audioguide');
    expect(json['zone_id'], '6f1c2a10-0000-4000-8000-000000000001');
    expect(json['lang'], 'es');
  });

  test('la clave pública sale de la privada', () async {
    final PushKeyPair pair = await PushKeyPair.fromPrivate(b64(sk));
    expect(base64Url.encode(pair.publicKey).replaceAll('=', ''), pk);
  });

  test('otro móvil, otra clave o un byte cambiado: no se abre', () async {
    final Uint8List envelope = b64(env);
    await expectLater(
      hpkeOpen(
        privateKey: b64(sk),
        envelope: envelope,
        aad: ascii.encode('otro-movil'),
      ),
      throwsA(isA<HpkeOpenError>()),
    );
    final PushKeyPair other = await PushKeyPair.generate();
    await expectLater(
      hpkeOpen(privateKey: other.privateKey, envelope: envelope, aad: deviceId),
      throwsA(isA<HpkeOpenError>()),
    );
    final Uint8List tampered = Uint8List.fromList(envelope);
    tampered[40] ^= 1;
    await expectLater(
      hpkeOpen(privateKey: b64(sk), envelope: tampered, aad: deviceId),
      throwsA(isA<HpkeOpenError>()),
    );
    await expectLater(
      hpkeOpen(privateKey: b64(sk), envelope: Uint8List(10), aad: deviceId),
      throwsA(isA<HpkeOpenError>()),
    );
  });
}
