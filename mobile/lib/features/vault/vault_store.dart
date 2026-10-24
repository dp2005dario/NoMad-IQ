// Dónde y cómo se guardan los documentos de la Bóveda.
//
// La idea, con una analogía: los papeles van dentro de sobres cerrados con
// un candado (cifrado AES-256-GCM). La llave del candado vive en la caja
// fuerte del propio chip del móvil (Android Keystore, a través de
// flutter_secure_storage). Para sacar la llave hace falta tu huella o el
// PIN del móvil (local_auth). Nada de esto sale nunca del teléfono: ni a
// nuestro servidor ni a ninguna nube.
//
// Tres "enchufes" (interfaces) para poder probarlo sin un móvil de verdad:
//   VaultKeyStore → dónde se guarda la llave
//   VaultFiles    → dónde se guardan los sobres cifrados
//   Unlocker      → quién comprueba tu huella
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';

/// La llave (32 bytes al azar) en la caja fuerte del móvil.
abstract interface class VaultKeyStore {
  Future<Uint8List?> read();
  Future<void> write(Uint8List key);
  Future<void> delete();
}

class SecureVaultKeyStore implements VaultKeyStore {
  SecureVaultKeyStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  static const String _name = 'vault_key_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read() async {
    final String? hex = await _storage.read(key: _name);
    if (hex == null || hex.length != 64) return null;
    return Uint8List.fromList(<int>[
      for (int i = 0; i < 64; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  @override
  Future<void> write(Uint8List key) => _storage.write(
    key: _name,
    value: key.map((int b) => b.toRadixString(16).padLeft(2, '0')).join(),
  );

  @override
  Future<void> delete() => _storage.delete(key: _name);
}

class MemoryVaultKeyStore implements VaultKeyStore {
  Uint8List? key;

  @override
  Future<Uint8List?> read() async => key;

  @override
  Future<void> write(Uint8List key) async => this.key = key;

  @override
  Future<void> delete() async => key = null;
}

/// Los sobres cifrados, por nombre (`index`, `<id>.bin`, `<id>.txt`).
abstract interface class VaultFiles {
  Future<Uint8List?> read(String name);
  Future<void> write(String name, Uint8List bytes);
  Future<void> delete(String name);

  /// Borra la Bóveda entera ("Olvidar este teléfono").
  Future<void> clear();
}

/// En la carpeta privada de la app (otras apps no pueden leerla y
/// allowBackup="false" impide que se copie a la nube).
class DirVaultFiles implements VaultFiles {
  Future<Directory>? _dir;

  Future<Directory> _folder() => _dir ??= () async {
    final Directory base = await getApplicationSupportDirectory();
    return Directory('${base.path}/vault').create(recursive: true);
  }();

  @override
  Future<Uint8List?> read(String name) async {
    final File f = File('${(await _folder()).path}/$name');
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    final String dir = (await _folder()).path;
    // Primero a un fichero temporal y luego se renombra: si el móvil se
    // apaga a mitad, nunca queda un sobre a medio escribir.
    final File tmp = File('$dir/$name.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename('$dir/$name');
  }

  @override
  Future<void> delete(String name) async {
    final File f = File('${(await _folder()).path}/$name');
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> clear() async {
    final Directory dir = await _folder();
    if (await dir.exists()) await dir.delete(recursive: true);
    _dir = null;
  }
}

class MemoryVaultFiles implements VaultFiles {
  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  Future<Uint8List?> read(String name) async => files[name];

  @override
  Future<void> write(String name, Uint8List bytes) async => files[name] = bytes;

  @override
  Future<void> delete(String name) async => files.remove(name);

  @override
  Future<void> clear() async => files.clear();
}

/// Cómo fue la huella.
enum UnlockResult {
  ok,
  cancelled, // el usuario cerró la ventana o la huella no coincidió
  unavailable, // el móvil no tiene ni huella ni PIN: no se puede proteger
}

abstract interface class Unlocker {
  Future<UnlockResult> unlock(String reason);
}

/// La huella (o la cara, o el PIN del móvil) de verdad.
class DeviceUnlocker implements Unlocker {
  DeviceUnlocker([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<UnlockResult> unlock(String reason) async {
    try {
      if (!await _auth.isDeviceSupported()) return UnlockResult.unavailable;
      // biometricOnly: false → si no hay huella, vale el PIN del móvil.
      final bool ok = await _auth.authenticate(localizedReason: reason);
      return ok ? UnlockResult.ok : UnlockResult.cancelled;
    } on LocalAuthException catch (e) {
      return e.code == LocalAuthExceptionCode.noCredentialsSet ||
              e.code == LocalAuthExceptionCode.noBiometricHardware
          ? UnlockResult.unavailable
          : UnlockResult.cancelled;
    } on PlatformException {
      return UnlockResult.cancelled;
    }
  }
}

/// El candado: AES-256-GCM. Cada sobre lleva su propio "nonce" (un número
/// al azar que no se repite) y va "atado" a su nombre: si alguien cambia un
/// sobre de sitio, al abrirlo se nota y se rechaza.
class VaultCipher {
  VaultCipher(List<int> key) : _key = SecretKey(key);

  static const int version = 1;
  static final AesGcm _aes = AesGcm.with256bits();
  final SecretKey _key;

  /// 32 bytes al azar con el generador seguro del sistema.
  static Future<Uint8List> newKey() async =>
      Uint8List.fromList(await (await _aes.newSecretKey()).extractBytes());

  Future<Uint8List> seal(String name, List<int> clear) async {
    final SecretBox box = await _aes.encrypt(
      clear,
      secretKey: _key,
      aad: name.codeUnits,
    );
    return Uint8List.fromList(<int>[
      version,
      ...box.nonce,
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
  }

  /// Abre un sobre. Lanza [VaultCorrupt] si alguien lo ha tocado.
  Future<Uint8List> open(String name, Uint8List sealed) async {
    const int nonce = 12;
    const int mac = 16;
    if (sealed.length < 1 + nonce + mac || sealed[0] != version) {
      throw const VaultCorrupt();
    }
    try {
      final List<int> clear = await _aes.decrypt(
        SecretBox(
          sealed.sublist(1 + nonce, sealed.length - mac),
          nonce: sealed.sublist(1, 1 + nonce),
          mac: Mac(sealed.sublist(sealed.length - mac)),
        ),
        secretKey: _key,
        aad: name.codeUnits,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const VaultCorrupt();
    }
  }
}

class VaultCorrupt implements Exception {
  const VaultCorrupt();
}
