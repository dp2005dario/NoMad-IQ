// El historial de avisos (maqueta "Avisos"). Cada aviso que se enseña se
// apunta aquí con su texto ya traducido. Vive SOLO en este teléfono: el
// servidor no guarda qué avisos te llegaron.
import 'dart:convert';

import '../../core/settings.dart';
import 'push_notice.dart';

/// Un aviso apuntado.
class NoticeEntry {
  const NoticeEntry({
    required this.kind,
    required this.title,
    required this.body,
    required this.at,
    this.route,
  });

  final PushKind kind;
  final String title;
  final String body;
  final DateTime at;

  /// A qué pantalla lleva tocarlo (solo rutas internas, "/...").
  final String? route;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'title': title,
    'body': body,
    'at': at.toUtc().toIso8601String(),
    'route': ?route,
  };

  static NoticeEntry? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final PushKind? kind = PushKind.values
        .where((PushKind k) => k.name == json['kind'])
        .firstOrNull;
    final Object? title = json['title'];
    final Object? body = json['body'];
    final DateTime? at = DateTime.tryParse('${json['at']}');
    final Object? route = json['route'];
    if (kind == null || title is! String || body is! String || at == null) {
      return null;
    }
    return NoticeEntry(
      kind: kind,
      title: title,
      body: body,
      at: at,
      // Una ruta rara (una web de fuera...) se descarta.
      route: route is String && route.startsWith('/') && !route.startsWith('//')
          ? route
          : null,
    );
  }
}

class NoticeLog {
  const NoticeLog(this._store);

  /// Más que esto no hace falta y así el archivo sigue pequeño.
  static const int max = 100;

  final SettingsStore _store;

  /// Del más nuevo al más viejo.
  List<NoticeEntry> all() {
    try {
      final Object? list = jsonDecode(
        _store.readData(LocalData.noticeLog) ?? '[]',
      );
      if (list is! List<Object?>) return <NoticeEntry>[];
      return list.map(NoticeEntry.tryParse).whereType<NoticeEntry>().toList()
        ..sort((NoticeEntry a, NoticeEntry b) => b.at.compareTo(a.at));
    } on FormatException {
      return <NoticeEntry>[];
    }
  }

  Future<void> add(NoticeEntry entry) async {
    final List<NoticeEntry> list = <NoticeEntry>[entry, ...all()];
    await _store.writeData(
      LocalData.noticeLog,
      jsonEncode(<Object?>[
        for (final NoticeEntry e in list.take(max)) e.toJson(),
      ]),
    );
  }

  Future<void> clear() => _store.writeData(LocalData.noticeLog, null);
}
