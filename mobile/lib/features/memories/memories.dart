// Recuerdos del viaje (maquetas "Recuerdo" y "Recuerdos"): las fotos y los
// vídeos que haces con la cámara de viaje, y la "historia" que se monta sola
// con ellos, la ruta y los sellos.
//
// Todo vive SOLO en este móvil: los archivos en la carpeta privada de la app
// y la lista en el almacenamiento local. Nada se sube a ningún servidor;
// solo sale lo que tú compartes con el botón "Compartir".
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../core/settings.dart';
import '../camera/stamps.dart';

enum MemoryKind { photo, video }

/// Un recuerdo: el archivo y lo que se sabía al hacerlo.
class Memory {
  const Memory({
    required this.file,
    required this.kind,
    required this.at,
    this.city,
  });

  /// Nombre del archivo dentro de la carpeta de recuerdos ("m_17299….jpg").
  final String file;
  final MemoryKind kind;
  final DateTime at;

  /// La ciudad del aeropuerto más cercano, si había GPS.
  final String? city;

  Map<String, Object?> toJson() => <String, Object?>{
    'file': file,
    'kind': kind.name,
    'at': at.toUtc().toIso8601String(),
    'city': ?city,
  };

  static Memory? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? file = json['file'];
    final DateTime? at = DateTime.tryParse('${json['at']}');
    final Object? city = json['city'];
    // Solo nombres sencillos: nada de "../" para salirse de la carpeta.
    if (file is! String ||
        !RegExp(r'^[A-Za-z0-9_.-]{1,80}$').hasMatch(file) ||
        file.contains('..') ||
        at == null) {
      return null;
    }
    return Memory(
      file: file,
      kind: json['kind'] == 'video' ? MemoryKind.video : MemoryKind.photo,
      at: at,
      city: city is String && city.isNotEmpty ? city : null,
    );
  }
}

/// Como mucho 300 recuerdos (unos 300 MB con vídeos cortos): el móvil no se
/// llena sin que te des cuenta. Al pasar, se avisa en vez de borrar nada.
const int maxMemories = 300;

/// Un vídeo dura como mucho 30 segundos (una historia de Instagram son 60).
const Duration maxVideo = Duration(seconds: 30);

/// Dónde se guardan los archivos. En los tests, en memoria.
abstract interface class MemoryFiles {
  /// Guarda [bytes] como [name] y devuelve la ruta completa.
  Future<String> write(String name, Uint8List bytes);

  /// Mueve un archivo que ya existe (el vídeo que grabó la cámara).
  Future<String> import(String sourcePath, String name);

  Future<String> pathOf(String name);

  Future<void> delete(String name);

  Future<void> deleteAll();
}

class AppMemoryFiles implements MemoryFiles {
  Future<Directory> _dir() async {
    final Directory root = await getApplicationSupportDirectory();
    final Directory dir = Directory('${root.path}/memories');
    await dir.create(recursive: true);
    return dir;
  }

  @override
  Future<String> write(String name, Uint8List bytes) async {
    final File f = File('${(await _dir()).path}/$name');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  @override
  Future<String> import(String sourcePath, String name) async {
    final String to = '${(await _dir()).path}/$name';
    final File src = File(sourcePath);
    try {
      await src.rename(to);
    } on FileSystemException {
      // Otra partición: se copia y se borra el original.
      await src.copy(to);
      await src.delete();
    }
    return to;
  }

  @override
  Future<String> pathOf(String name) async => '${(await _dir()).path}/$name';

  @override
  Future<void> delete(String name) async {
    final File f = File('${(await _dir()).path}/$name');
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> deleteAll() async {
    final Directory dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

class MemoryMemoryFiles implements MemoryFiles {
  final Map<String, Uint8List> files = <String, Uint8List>{};

  @override
  Future<String> write(String name, Uint8List bytes) async {
    files[name] = bytes;
    return '/memories/$name';
  }

  @override
  Future<String> import(String sourcePath, String name) async {
    files[name] = Uint8List(0);
    return '/memories/$name';
  }

  @override
  Future<String> pathOf(String name) async => '/memories/$name';

  @override
  Future<void> delete(String name) async => files.remove(name);

  @override
  Future<void> deleteAll() async => files.clear();
}

/// La lista de recuerdos (el más nuevo primero) y el día en que empezó el
/// viaje (para la pegatina "DÍA 2").
class MemoryBook {
  MemoryBook(this._store, this.files);

  final SettingsStore _store;
  final MemoryFiles files;

  Map<String, Object?> _raw() {
    try {
      final Object? j = jsonDecode(_store.readData(LocalData.memories) ?? '{}');
      return j is Map<String, Object?> ? j : <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    }
  }

  List<Memory> all() {
    final Object? list = _raw()['items'];
    if (list is! List<Object?>) return <Memory>[];
    return <Memory>[for (final Object? m in list) ?Memory.parse(m)]
      ..sort((Memory a, Memory b) => b.at.compareTo(a.at));
  }

  /// El primer día del viaje (a medianoche). Si no lo has elegido, el del
  /// recuerdo más antiguo de los últimos 30 días, o hoy.
  DateTime tripStart(DateTime now) {
    final DateTime? set = DateTime.tryParse('${_raw()['trip_start']}');
    if (set != null) return DateTime(set.year, set.month, set.day);
    final DateTime month = now.subtract(const Duration(days: 30));
    final List<Memory> recent = <Memory>[
      for (final Memory m in all())
        if (m.at.isAfter(month)) m,
    ];
    final DateTime first = recent.isEmpty ? now : recent.last.at.toLocal();
    return DateTime(first.year, first.month, first.day);
  }

  Future<void> setTripStart(DateTime day) =>
      _write(all(), DateTime(day.year, day.month, day.day));

  bool get full => all().length >= maxMemories;

  Future<void> add(Memory m) async {
    final List<Memory> list = all();
    if (list.length >= maxMemories) return;
    await _write(<Memory>[m, ...list], _start());
  }

  Future<void> remove(Memory m) async {
    await files.delete(m.file);
    await _write(<Memory>[
      for (final Memory x in all())
        if (x.file != m.file) x,
    ], _start());
  }

  /// "Borrar mi cuenta": fuera los archivos y la lista.
  Future<void> clear() async {
    await files.deleteAll();
    await _store.writeData(LocalData.memories, null);
  }

  DateTime? _start() => DateTime.tryParse('${_raw()['trip_start']}');

  Future<void> _write(List<Memory> list, DateTime? start) => _store.writeData(
    LocalData.memories,
    jsonEncode(<String, Object?>{
      'items': <Object?>[for (final Memory m in list) m.toJson()],
      if (start != null)
        'trip_start':
            '${start.year.toString().padLeft(4, '0')}-'
            '${start.month.toString().padLeft(2, '0')}-'
            '${start.day.toString().padLeft(2, '0')}',
    }),
  );
}

/// El día del viaje (1 = el primero).
int tripDay(DateTime start, DateTime at) {
  final DateTime d = DateTime(at.year, at.month, at.day);
  return d.difference(start).inDays + 1;
}

/// La parte del día, para la pegatina ("atardecer").
enum DayPart { morning, afternoon, sunset, night }

DayPart dayPartOf(DateTime local) => switch (local.hour) {
  >= 6 && < 13 => DayPart.morning,
  >= 13 && < 18 => DayPart.afternoon,
  >= 18 && < 21 => DayPart.sunset,
  _ => DayPart.night,
};

/// Las cifras del final de la historia.
class TripStats {
  const TripStats({
    required this.days,
    required this.cities,
    required this.media,
    required this.stamps,
  });

  final int days;
  final List<String> cities;
  final int media;
  final int stamps;
}

/// Lo que cuenta la historia: desde [start] hasta hoy.
TripStats statsOf(
  List<Memory> memories,
  List<Stamp> stamps,
  DateTime start,
  DateTime now,
) {
  final List<Memory> inTrip = <Memory>[
    for (final Memory m in memories)
      if (!m.at.toLocal().isBefore(start)) m,
  ]..sort((Memory a, Memory b) => a.at.compareTo(b.at));
  final List<String> cities = <String>[];
  for (final Memory m in inTrip) {
    final String? c = m.city;
    if (c != null && !cities.contains(c)) cities.add(c);
  }
  return TripStats(
    days: tripDay(start, now).clamp(1, 366),
    cities: cities,
    media: inTrip.length,
    stamps: stamps.where((Stamp s) => !s.date.toLocal().isBefore(start)).length,
  );
}

/// Las fotos que salen en la historia: hasta 6, repartidas por el viaje
/// (no las 6 últimas del mismo sitio).
List<Memory> storyPhotos(List<Memory> memories, DateTime start) {
  final List<Memory> photos = <Memory>[
    for (final Memory m in memories)
      if (m.kind == MemoryKind.photo && !m.at.toLocal().isBefore(start)) m,
  ]..sort((Memory a, Memory b) => a.at.compareTo(b.at));
  if (photos.length <= 6) return photos;
  return <Memory>[
    for (int i = 0; i < 6; i++) photos[(i * (photos.length - 1) / 5).round()],
  ];
}
