// Qué avisos quieres recibir (Privacidad). Se decide EN EL MÓVIL: el aviso
// llega cifrado, el móvil lo abre y, si es de un tipo que has apagado, no lo
// enseña. Así no hace falta contarle al servidor tus gustos.
import 'dart:convert';

import '../../core/settings.dart';
import 'push_notice.dart';

/// Los de seguridad no se pueden apagar: pueden salvarte de un mal rato.
const Set<PushKind> alwaysOn = <PushKind>{PushKind.zoneSafety};

Set<PushKind> mutedKinds(SettingsStore prefs) {
  final String? raw = prefs.readData(LocalData.mutedNotices);
  if (raw == null) return <PushKind>{};
  try {
    final Map<String, PushKind> byName = PushKind.values.asNameMap();
    return <PushKind>{
      for (final Object? name in jsonDecode(raw) as List<Object?>)
        if (byName[name] case final PushKind kind when !alwaysOn.contains(kind))
          kind,
    };
  } on Object {
    return <PushKind>{}; // guardado roto: mejor recibirlo todo
  }
}

Future<void> setMuted(SettingsStore prefs, Set<PushKind> kinds, bool muted) {
  final Set<PushKind> now = mutedKinds(prefs);
  muted ? now.addAll(kinds.difference(alwaysOn)) : now.removeAll(kinds);
  return prefs.writeData(
    LocalData.mutedNotices,
    now.isEmpty
        ? null
        : jsonEncode(<String>[for (final PushKind k in now) k.name]..sort()),
  );
}
