// Descifrado de los avisos push en el móvil, con HPKE (RFC 9180).
//
// El notifier (services/notifier/internal/sealbox) cifra cada aviso para UN
// teléfono con su clave PÚBLICA. Solo este móvil tiene la PRIVADA, así que ni
// Google (que transporta el aviso) ni nadie más puede leerlo.
//
// Analogía: el móvil reparte candados abiertos (claves públicas) y se queda
// la única llave (clave privada). El servidor mete el aviso en una caja, la
// cierra con el candado, y solo el móvil puede abrirla.
//
// Misma receta exacta que el servidor (si cambia una pieza, nada se abre):
//   - KEM:  DHKEM(X25519, HKDF-SHA256)  → acordar un secreto con la clave efímera
//   - KDF:  HKDF-SHA256                 → convertir el secreto en clave + nonce
//   - AEAD: AES-256-GCM                 → descifrar y comprobar que nadie tocó nada
//
// No inventamos criptografía: X25519, HMAC y AES-GCM los pone el paquete
// "cryptography"; aquí solo se encadenan los pasos que dicta el RFC 9180.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// El aviso no se pudo abrir (clave equivocada, aviso manipulado o roto).
class HpkeOpenError implements Exception {
  const HpkeOpenError();

  @override
  String toString() => 'HpkeOpenError';
}

/// Un par de claves X25519 del móvil.
class PushKeyPair {
  const PushKeyPair({required this.privateKey, required this.publicKey});

  /// 32 bytes. NUNCA sale del móvil (se guarda en el almacén cifrado).
  final Uint8List privateKey;

  /// 32 bytes. Es lo que se manda al notifier.
  final Uint8List publicKey;

  /// Un par nuevo, con números aleatorios seguros del sistema.
  static Future<PushKeyPair> generate() async {
    final SimpleKeyPair pair = await X25519().newKeyPair();
    return _of(pair);
  }

  /// Rehace el par a partir de la clave privada guardada.
  static Future<PushKeyPair> fromPrivate(List<int> privateKey) async {
    if (privateKey.length != 32) throw const HpkeOpenError();
    return _of(await X25519().newKeyPairFromSeed(privateKey));
  }

  static Future<PushKeyPair> _of(SimpleKeyPair pair) async {
    final SimpleKeyPairData data = await pair.extract();
    final SimplePublicKey pub = await pair.extractPublicKey();
    return PushKeyPair(
      privateKey: Uint8List.fromList(data.bytes),
      publicKey: Uint8List.fromList(pub.bytes),
    );
  }
}

/// Lo mismo que el servidor mezcla en las claves: un mensaje cifrado para
/// otra cosa nunca se podría hacer pasar por un aviso.
final Uint8List pushInfo = ascii.encode('nomadiq push v1');

/// Abre un aviso: [envelope] = clave efímera (32 bytes) + texto cifrado.
/// [aad] es el device_id: un aviso copiado a otro móvil no se abre.
Future<Uint8List> hpkeOpen({
  required Uint8List privateKey,
  required Uint8List envelope,
  required Uint8List aad,
  Uint8List? info,
}) async {
  if (envelope.length <= _nEnc + _nTag || privateKey.length != 32) {
    throw const HpkeOpenError();
  }
  try {
    final Uint8List enc = envelope.sublist(0, _nEnc);
    final Uint8List ct = envelope.sublist(_nEnc);
    final PushKeyPair me = await PushKeyPair.fromPrivate(privateKey);

    // 1) KEM: secreto compartido = DH(mi privada, su efímera), "estirado".
    final SecretKey dhKey = await X25519().sharedSecretKey(
      keyPair: SimpleKeyPairData(
        privateKey,
        publicKey: SimplePublicKey(me.publicKey, type: KeyPairType.x25519),
        type: KeyPairType.x25519,
      ),
      remotePublicKey: SimplePublicKey(enc, type: KeyPairType.x25519),
    );
    final Uint8List dh = Uint8List.fromList(await dhKey.extractBytes());
    if (dh.every((int b) => b == 0)) throw const HpkeOpenError();
    final Uint8List kemContext = _concat(<List<int>>[enc, me.publicKey]);
    final Uint8List eaePrk = await _labeledExtract(
      _kemSuite,
      Uint8List(0),
      'eae_prk',
      dh,
    );
    final Uint8List shared = await _labeledExpand(
      _kemSuite,
      eaePrk,
      'shared_secret',
      kemContext,
      32,
    );

    // 2) Calendario de claves (modo "base", sin contraseña previa).
    final Uint8List pskIdHash = await _labeledExtract(
      _hpkeSuite,
      Uint8List(0),
      'psk_id_hash',
      Uint8List(0),
    );
    final Uint8List infoHash = await _labeledExtract(
      _hpkeSuite,
      Uint8List(0),
      'info_hash',
      info ?? pushInfo,
    );
    final Uint8List context = _concat(<List<int>>[
      <int>[0], // modo base
      pskIdHash,
      infoHash,
    ]);
    final Uint8List secret = await _labeledExtract(
      _hpkeSuite,
      shared,
      'secret',
      Uint8List(0),
    );
    final Uint8List key = await _labeledExpand(
      _hpkeSuite,
      secret,
      'key',
      context,
      32,
    );
    final Uint8List nonce = await _labeledExpand(
      _hpkeSuite,
      secret,
      'base_nonce',
      context,
      12,
    );

    // 3) AES-256-GCM. El primer (y único) mensaje usa el nonce tal cual.
    final List<int> clear = await AesGcm.with256bits().decrypt(
      SecretBox(
        ct.sublist(0, ct.length - _nTag),
        nonce: nonce,
        mac: Mac(ct.sublist(ct.length - _nTag)),
      ),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(clear);
  } on HpkeOpenError {
    rethrow;
  } on Object {
    // Cualquier fallo (etiqueta GCM incorrecta, clave rara...) es lo mismo
    // para quien llama: el aviso no se puede abrir.
    throw const HpkeOpenError();
  }
}

// --- Piezas del RFC 9180 ------------------------------------------------------

const int _nEnc = 32; // tamaño de la clave efímera X25519
const int _nTag = 16; // etiqueta de AES-GCM

// Identificadores de la suite: KEM 0x0020, KDF 0x0001, AEAD 0x0002.
final Uint8List _kemSuite = _concat(<List<int>>[
  ascii.encode('KEM'),
  <int>[0x00, 0x20],
]);
final Uint8List _hpkeSuite = _concat(<List<int>>[
  ascii.encode('HPKE'),
  <int>[0x00, 0x20, 0x00, 0x01, 0x00, 0x02],
]);
final Uint8List _version = ascii.encode('HPKE-v1');

Future<Uint8List> _labeledExtract(
  Uint8List suite,
  Uint8List salt,
  String label,
  List<int> ikm,
) => _extract(
  salt,
  _concat(<List<int>>[_version, suite, ascii.encode(label), ikm]),
);

Future<Uint8List> _labeledExpand(
  Uint8List suite,
  Uint8List prk,
  String label,
  List<int> info,
  int length,
) => _expand(
  prk,
  _concat(<List<int>>[
    <int>[length >> 8, length & 0xff],
    _version,
    suite,
    ascii.encode(label),
    info,
  ]),
  length,
);

/// HKDF-Extract = HMAC-SHA256(sal, material). Sal vacía = 32 ceros.
Future<Uint8List> _extract(Uint8List salt, Uint8List ikm) async {
  final Mac mac = await Hmac.sha256().calculateMac(
    ikm,
    secretKey: SecretKey(salt.isEmpty ? Uint8List(32) : salt),
  );
  return Uint8List.fromList(mac.bytes);
}

/// HKDF-Expand: encadena HMACs hasta tener [length] bytes.
Future<Uint8List> _expand(Uint8List prk, Uint8List info, int length) async {
  final BytesBuilder out = BytesBuilder();
  List<int> previous = const <int>[];
  for (int i = 1; out.length < length; i++) {
    final Mac mac = await Hmac.sha256().calculateMac(
      _concat(<List<int>>[
        previous,
        info,
        <int>[i],
      ]),
      secretKey: SecretKey(prk),
    );
    previous = mac.bytes;
    out.add(previous);
  }
  return Uint8List.fromList(out.toBytes().sublist(0, length));
}

Uint8List _concat(List<List<int>> parts) {
  final BytesBuilder b = BytesBuilder(copy: false);
  for (final List<int> p in parts) {
    b.add(p);
  }
  return b.toBytes();
}
