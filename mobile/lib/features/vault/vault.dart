// La Bóveda (maqueta "Bóveda de documentos"): pasaporte, DNI, tarjetas de
// embarque, seguro y reservas, cifrados en el móvil y abiertos con huella.
//
// Cómo funciona por dentro (ver vault_store.dart para el cifrado):
//   - "index": la lista de documentos (tipo, título, caducidad...).
//   - "<id>.bin": el documento (foto JPEG o PDF).
//   - "<id>.txt": el texto que el móvil leyó del documento (OCR), para
//     poder preguntarle a la póliza del seguro sin que salga del teléfono.
// Todo va cifrado. Al cerrar la Bóveda (a mano, a los 2 minutos o al salir
// de la app) la llave se borra de la memoria.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'vault_store.dart';

/// Los tipos de documento (cada uno con su letra y color en la rejilla).
enum DocKind {
  passport,
  idCard,
  boarding,
  insurance,
  booking,
  visa,
  medical,
  other,
}

/// Como mucho estos documentos y este tamaño cada uno (un PDF de una póliza
/// larga ronda 1-3 MB; una foto, 0,5 MB).
const int maxVaultDocs = 100;
const int maxDocBytes = 15 * 1024 * 1024;

class VaultDoc {
  const VaultDoc({
    required this.id,
    required this.kind,
    required this.title,
    required this.mime,
    required this.added,
    this.detail,
    this.expires,
    this.pages = 1,
  });

  final String id;
  final DocKind kind;

  /// "Pasaporte de Darío", "Seguro Viaje Plus"...
  final String title;

  /// Una línea más ("MAD → HND · 3 de marzo").
  final String? detail;

  /// Cuándo caduca (pasaporte, DNI, seguro). Sirve para avisar a tiempo.
  final DateTime? expires;

  /// "image/jpeg" o "application/pdf".
  final String mime;
  final int pages;
  final DateTime added;

  bool get isPdf => mime == 'application/pdf';

  VaultDoc copyWith({
    DocKind? kind,
    String? title,
    String? detail,
    DateTime? expires,
    bool clearExpires = false,
  }) => VaultDoc(
    id: id,
    kind: kind ?? this.kind,
    title: title ?? this.title,
    detail: detail ?? this.detail,
    expires: clearExpires ? null : expires ?? this.expires,
    mime: mime,
    pages: pages,
    added: added,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'kind': kind.name,
    'title': title,
    if (detail != null) 'detail': detail,
    if (expires != null) 'expires': expires!.toIso8601String(),
    'mime': mime,
    'pages': pages,
    'added': added.toIso8601String(),
  };

  static VaultDoc? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final DocKind? kind = DocKind.values.asNameMap()[json['kind']];
    final Object? title = json['title'];
    final Object? mime = json['mime'];
    final Object? pages = json['pages'];
    final DateTime? added = DateTime.tryParse('${json['added']}');
    if (id is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(id) ||
        kind == null ||
        title is! String ||
        (mime != 'image/jpeg' && mime != 'application/pdf') ||
        added == null) {
      return null;
    }
    final Object? detail = json['detail'];
    final Object? expires = json['expires'];
    return VaultDoc(
      id: id,
      kind: kind,
      title: title,
      detail: detail is String ? detail : null,
      expires: expires is String ? DateTime.tryParse(expires) : null,
      mime: mime! as String,
      pages: pages is int && pages > 0 ? pages : 1,
      added: added,
    );
  }
}

class VaultFull implements Exception {
  const VaultFull();
}

class DocTooBig implements Exception {
  const DocTooBig();
}

class Vault extends ChangeNotifier {
  Vault({
    required VaultKeyStore keys,
    required VaultFiles files,
    required Unlocker unlocker,
    this.autoLock = const Duration(minutes: 2),
    math.Random? random,
  }) : _keys = keys, // ignore: prefer_initializing_formals
       _files = files, // ignore: prefer_initializing_formals
       _unlocker = unlocker, // ignore: prefer_initializing_formals
       _random = random ?? math.Random.secure();

  final VaultKeyStore _keys;
  final VaultFiles _files;
  final Unlocker _unlocker;
  final math.Random _random;

  /// Tiempo sin tocar nada tras el que la Bóveda se cierra sola.
  final Duration autoLock;

  VaultCipher? _cipher;
  List<VaultDoc> _docs = const <VaultDoc>[];
  Timer? _timer;
  DateTime? _closesAt;

  bool get isOpen => _cipher != null;

  /// Los documentos (vacío si está cerrada).
  List<VaultDoc> get docs => List<VaultDoc>.unmodifiable(_docs);

  /// Cuándo se cerrará sola (null = cerrada).
  DateTime? get closesAt => _closesAt;

  /// Pide la huella y abre. [reason] es el texto de la ventana del sistema.
  Future<UnlockResult> open(String reason) async {
    if (isOpen) {
      touch();
      return UnlockResult.ok;
    }
    final UnlockResult r = await _unlocker.unlock(reason);
    if (r != UnlockResult.ok) return r;
    Uint8List? key = await _keys.read();
    if (key == null) {
      // Primera vez: se crea la llave y una Bóveda vacía.
      key = await VaultCipher.newKey();
      await _keys.write(key);
    }
    _cipher = VaultCipher(key);
    try {
      _docs = await _readIndex();
    } on VaultCorrupt {
      // La llave no abre el índice (por ejemplo, se restauró el móvil):
      // se empieza de cero en vez de quedarse bloqueado para siempre.
      _docs = const <VaultDoc>[];
    }
    _changed();
    return UnlockResult.ok;
  }

  /// Cierra y olvida la llave de la memoria.
  void close() {
    _timer?.cancel();
    _timer = null;
    _cipher = null;
    _docs = const <VaultDoc>[];
    _closesAt = null;
    notifyListeners();
  }

  /// "Sigo aquí": vuelve a contar los 2 minutos. No avisa a las pantallas
  /// (no cambia nada visible), así se puede llamar mientras se dibujan.
  void touch() {
    if (!isOpen) return;
    _timer?.cancel();
    _timer = Timer(autoLock, close);
    _closesAt = DateTime.now().add(autoLock);
  }

  /// Algo visible cambió (se abrió o cambió la lista).
  void _changed() {
    touch();
    notifyListeners();
  }

  VaultCipher get _open {
    final VaultCipher? c = _cipher;
    if (c == null) throw StateError('la Bóveda está cerrada');
    return c;
  }

  Future<List<VaultDoc>> _readIndex() async {
    final Uint8List? sealed = await _files.read('index');
    if (sealed == null) return const <VaultDoc>[];
    final Object? json = jsonDecode(
      utf8.decode(await _open.open('index', sealed)),
    );
    final Object? docs = json is Map<String, Object?> ? json['docs'] : null;
    return <VaultDoc>[
      if (docs is List<Object?>)
        for (final Object? d in docs)
          if (VaultDoc.parse(d) case final VaultDoc doc) doc,
    ];
  }

  Future<void> _writeIndex() async {
    await _files.write(
      'index',
      await _open.seal(
        'index',
        utf8.encode(
          jsonEncode(<String, Object?>{
            'docs': <Object?>[for (final VaultDoc d in _docs) d.toJson()],
          }),
        ),
      ),
    );
  }

  String _newId() => List<String>.generate(
    32,
    (_) => _random.nextInt(16).toRadixString(16),
  ).join();

  /// Guarda un documento nuevo (y el texto leído de cada página).
  Future<VaultDoc> add({
    required DocKind kind,
    required String title,
    required String mime,
    required Uint8List bytes,
    String? detail,
    DateTime? expires,
    List<String> text = const <String>[],
    int pages = 1,
  }) async {
    if (_docs.length >= maxVaultDocs) throw const VaultFull();
    if (bytes.isEmpty || bytes.length > maxDocBytes) throw const DocTooBig();
    final VaultDoc doc = VaultDoc(
      id: _newId(),
      kind: kind,
      title: title,
      detail: detail,
      expires: expires,
      mime: mime,
      pages: pages,
      added: DateTime.now(),
    );
    await _files.write(
      '${doc.id}.bin',
      await _open.seal('${doc.id}.bin', bytes),
    );
    await _files.write(
      '${doc.id}.txt',
      await _open.seal('${doc.id}.txt', utf8.encode(jsonEncode(text))),
    );
    _docs = <VaultDoc>[..._docs, doc];
    await _writeIndex();
    _changed();
    return doc;
  }

  /// El documento descifrado (solo en memoria).
  Future<Uint8List> content(String id) async {
    touch();
    final Uint8List? sealed = await _files.read('$id.bin');
    if (sealed == null) throw const VaultCorrupt();
    return _open.open('$id.bin', sealed);
  }

  /// El texto de cada página (vacío si no se pudo leer).
  Future<List<String>> text(String id) async {
    final Uint8List? sealed = await _files.read('$id.txt');
    if (sealed == null) return const <String>[];
    final Object? json = jsonDecode(
      utf8.decode(await _open.open('$id.txt', sealed)),
    );
    return <String>[
      if (json is List<Object?>)
        for (final Object? p in json) p is String ? p : '',
    ];
  }

  Future<void> update(VaultDoc doc) async {
    _docs = <VaultDoc>[
      for (final VaultDoc d in _docs) d.id == doc.id ? doc : d,
    ];
    await _writeIndex();
    touch();
  }

  Future<void> delete(String id) async {
    _docs = <VaultDoc>[
      for (final VaultDoc d in _docs)
        if (d.id != id) d,
    ];
    await _writeIndex();
    await _files.delete('$id.bin');
    await _files.delete('$id.txt');
    _changed();
  }

  /// Borra la Bóveda y su llave para siempre ("Olvidar este teléfono").
  Future<void> forget() async {
    close();
    await _files.clear();
    await _keys.delete();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
