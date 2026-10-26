// "Descargar mis datos" y "Borrar mi cuenta y mis datos" (Ajustes).
//
// Google Play obliga a que cualquier app con cuentas deje borrarlas DESDE la
// propia app, y el RGPD europeo da derecho a llevarte una copia de tus datos.
// Este archivo hace las dos cosas sin saber nada de pantallas: así se prueba
// solo, sin dibujar nada.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/settings.dart';
import '../family/family.dart';
import '../memories/memories.dart';
import '../widgets/home_widgets.dart';
import '../vault/vault.dart';

/// Dónde se guarda la copia (en el móvil: el selector "Guardar como" de
/// Android; en los tests, una lista en memoria).
abstract interface class DataSaver {
  /// true = guardado; false = la persona canceló.
  Future<bool> save(String fileName, Uint8List bytes);
}

class DeviceDataSaver implements DataSaver {
  const DeviceDataSaver();

  @override
  Future<bool> save(String fileName, Uint8List bytes) async =>
      await FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/json',
      ) !=
      null;
}

/// Sin dónde guardar (tests que no lo necesitan).
class NoDataSaver implements DataSaver {
  const NoDataSaver();

  @override
  Future<bool> save(String fileName, Uint8List bytes) async => false;
}

/// Lo que se pide a cada servicio para la copia. Si uno falla, la copia
/// sale igual y ese apartado dice "no disponible" (mejor algo que nada).
const Map<String, String> exportSources = <String, String>{
  'fare_watches': '/v1/fares/watches',
  'fare_alerts': '/v1/fares/alerts?limit=100',
  'recommendations': '/v1/recommendations?limit=50',
  'expense_groups': '/v1/expense-groups',
  'group_trips': '/v1/group-negotiations',
};

/// Reúne TODO lo que ECLIPTA sabe de ti: lo de los servidores y lo que solo
/// está en este móvil. Los documentos de la Bóveda no van: están cifrados y
/// se ven en la propia Bóveda (sacarlos en claro a un archivo sería un riesgo).
Future<Map<String, Object?>> collectMyData({
  required ApiClient api,
  required SessionController session,
  required SettingsStore prefs,
  DateTime Function() now = DateTime.now,
}) async {
  final Map<String, Object?> server = <String, Object?>{};
  for (final MapEntry<String, String> source in exportSources.entries) {
    server[source.key] = await _fetch(api, source.value);
  }
  // Cada bote con sus gastos (la lista solo trae el resumen).
  final Object? groups = server['expense_groups'];
  if (groups is Map<String, Object?> && groups['items'] is List<Object?>) {
    final List<Object?> full = <Object?>[];
    for (final Object? g in groups['items']! as List<Object?>) {
      final Object? id = g is Map<String, Object?> ? g['group_id'] : null;
      full.add(
        id is String
            ? await _fetch(api, '/v1/expense-groups/${Uri.encodeComponent(id)}')
            : g,
      );
    }
    server['expense_groups'] = full;
  }

  final Map<String, Object?> phone = <String, Object?>{
    'language': prefs.readLocale(),
    'group_name': prefs.readGroupName(),
    'flight_origin': prefs.readFlightOrigin(),
    'travel_mode': prefs.readTravelMode(),
    'flyra_chat': _json(prefs.readFlyraChat()),
    'stamps': _json(prefs.readStamps()),
    for (final LocalData d in LocalData.values)
      if (d != LocalData.fxRates) d.name: _json(prefs.readData(d)),
  };

  return <String, Object?>{
    'app': 'ECLIPTA',
    'format': 1,
    'exported_at': now().toUtc().toIso8601String(),
    'account': <String, Object?>{
      'id': session.user?.id,
      'email': session.user?.email,
    },
    'server': server,
    'this_phone': phone,
  };
}

/// La copia como archivo JSON bonito (con sangría, para leerlo a mano).
Uint8List encodeExport(Map<String, Object?> data) => Uint8List.fromList(
  utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
);

/// "nomadiq-mis-datos-2026-10-23.json"
String exportFileName(DateTime when) {
  final String day = when.toIso8601String().substring(0, 10);
  return 'nomadiq-mis-datos-$day.json';
}

Future<Object?> _fetch(ApiClient api, String pathAndQuery) async {
  final Uri uri = Uri.parse(pathAndQuery);
  try {
    return await api.getJson(
      uri.path,
      query: uri.queryParameters.isEmpty ? null : uri.queryParameters,
    );
  } on ApiException catch (e) {
    return <String, Object?>{'unavailable': e.error.name};
  }
}

Object? _json(String? raw) {
  if (raw == null) return null;
  try {
    return jsonDecode(raw);
  } on FormatException {
    return raw;
  }
}

/// En qué paso se quedó un borrado que falló (para el mensaje).
enum EraseStep { password, serverData, account }

class EraseFailed implements Exception {
  const EraseFailed(this.step, this.cause);

  final EraseStep step;
  final Object cause;

  @override
  String toString() => 'EraseFailed($step)';
}

/// Borra la cuenta y todo lo tuyo, en este orden (importa):
///
/// 1. comprueba tu contraseña (si está mal, no se toca NADA);
/// 2. borra tus datos en cada servicio (gastos, vuelos...) mientras el pase
///    aún vale;
/// 3. borra la cuenta en el auth-gateway (desde aquí ya no hay pase);
/// 4. borra lo de este móvil: la Bóveda (y su llave), tus ajustes y los
///    perfiles de familia.
///
/// Si el paso 2 o 3 falla (sin red), la cuenta sigue viva y se puede
/// repetir: borrar dos veces no hace daño.
class AccountEraser {
  AccountEraser({
    required this.session,
    required this.api,
    required this.vault,
    required this.prefs,
    this.family,
    this.memories,
    this.homeWidgets,
    this.liveFlight,
  });

  final SessionController session;

  /// Los perfiles de familia (cifrados aparte, en el Keystore).
  final FamilyStore? family;

  /// Las fotos y vídeos de Recuerdos (solo en el móvil): también fuera.
  final MemoryBook? memories;

  /// Los widgets del escritorio enseñan tu vuelo y tu presupuesto: se vacían.
  final HomeWidgets? homeWidgets;
  final LiveFlight? liveFlight;
  final ApiClient api;
  final Vault vault;
  final SettingsStore prefs;

  /// Servicios que guardan cosas tuyas y cómo se les pide borrarlas.
  static const List<String> serverErasers = <String>[
    '/v1/me/data', // ai-orchestrator: botes, viajes en grupo, recomendaciones
    '/v1/fares/me', // price-consumer: rutas vigiladas y avisos de precio
  ];

  Future<void> erase(String password) async {
    try {
      await session.confirmPassword(password);
    } on Object catch (e) {
      throw EraseFailed(EraseStep.password, e);
    }
    try {
      for (final String path in serverErasers) {
        await api.delete(path);
      }
    } on Object catch (e) {
      throw EraseFailed(EraseStep.serverData, e);
    }
    try {
      await session.deleteAccount(password);
    } on Object catch (e) {
      throw EraseFailed(EraseStep.account, e);
    }
    // La cuenta ya no existe: lo del móvil se borra pase lo que pase.
    await vault.forget();
    await prefs.wipePersonal();
    await family?.save(<FamilyMember>[]);
    await memories?.clear();
    await homeWidgets?.clear();
    await liveFlight?.cancel();
  }
}
