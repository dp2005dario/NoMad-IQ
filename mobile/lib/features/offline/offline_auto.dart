// "Actualizar solas" (maqueta de Sin conexión): si lo activas, las ciudades
// descargadas se ponen al día SOLAS cuando:
//   - hay wifi (nunca con datos del móvil),
//   - el móvil está cargando (no gasta batería),
//   - y hace falta: OpenFreeMap ha publicado un mapa más nuevo que el tuyo,
//     o la ciudad se bajó hace más de 30 días.
// Se mira como mucho una vez al día, al abrir la app o al volver a ella.
//
// Límite honesto: funciona con la app ABIERTA (o al volver a ella). Con la
// app cerrada del todo no se actualiza: eso necesitaría tareas de Android en
// segundo plano (WorkManager) y no se ha podido probar en un móvil.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flyra/flyra_mini.dart';
import '../route/geo.dart' show LatLon;
import '../route/world_data.dart';
import 'city_downloader.dart';
import 'city_pack.dart';

/// Dónde está el aeropuerto de una ciudad (para centrar la descarga).
typedef CenterOf = Future<LatLon?> Function(String iata);

Future<LatLon?> worldCenterOf(String iata) async {
  try {
    return (await WorldData.load()).airports[iata]?.position;
  } on Object {
    return null;
  }
}

class OfflineAutoUpdate {
  OfflineAutoUpdate(this._s, {CenterOf? centerOf})
    : _centerOf = centerOf ?? worldCenterOf;

  final AppServices _s;
  final CenterOf _centerOf;

  /// Una ciudad con más de estos días se vuelve a bajar.
  static const Duration maxAge = Duration(days: 30);

  /// Se mira como mucho cada 20 horas.
  static const Duration every = Duration(hours: 20);

  bool get enabled => _s.prefs.readData(LocalData.offlineAutoUpdate) == '1';

  Future<void> setEnabled(bool on) =>
      _s.prefs.writeData(LocalData.offlineAutoUpdate, on ? '1' : null);

  /// ¿Le toca a esta ciudad? (mapa más nuevo o demasiado vieja)
  static bool due(CityPack p, String? latest, DateTime now) =>
      hasNewerMap(p, latest) || now.difference(p.savedAt) > maxAge;

  /// Mira y, si toca, actualiza. Devuelve las ciudades que se pusieron al día.
  Future<List<CityPack>> run({required String language, DateTime? now}) async {
    final DateTime at = now ?? DateTime.now();
    if (!enabled || _s.offlineBusy.value != null) return <CityPack>[];
    final List<CityPack> all = _s.offlineCities.all();
    if (all.isEmpty) return <CityPack>[];
    final DateTime? last = DateTime.tryParse(
      _s.prefs.readData(LocalData.offlineAutoChecked) ?? '',
    );
    if (last != null && at.difference(last) < every) return <CityPack>[];
    // Sin wifi o sin cargar: no se marca como mirado, se prueba al volver.
    if (await _s.net.now() != NetKind.wifi) return <CityPack>[];
    if (!await _s.power.charging()) return <CityPack>[];
    await _s.prefs.writeData(
      LocalData.offlineAutoChecked,
      at.toUtc().toIso8601String(),
    );
    final String? latest = await _s.mapVersion.latest();
    final List<CityPack> done = <CityPack>[];
    for (final CityPack p in all) {
      if (!due(p, latest, at) || _s.offlineBusy.value != null) continue;
      final LatLon? center = await _centerOf(p.iata);
      if (center == null) continue;
      _s.offlineBusy.value = p.iata;
      try {
        done.add(
          await _s.downloads.run(
            iata: p.iata,
            city: p.city,
            center: center,
            // Las voces, en el idioma en que las bajaste.
            language: p.language,
            wifiOnly: true,
            onProgress: (_) {},
            area: p.area,
            withAudio: p.withAudio,
          ),
        );
      } on DownloadException {
        // Se fue el wifi o falló el servidor: la ciudad vieja sigue valiendo
        // y se probará otro día.
        break;
      } finally {
        _s.offlineBusy.value = null;
      }
    }
    return done;
  }
}

/// Lanza la actualización al abrir la app y cada vez que vuelves a ella, y
/// la mini Flyra avisa de lo que se puso al día.
class OfflineAutoRunner extends StatefulWidget {
  const OfflineAutoRunner({super.key, required this.child});

  final Widget child;

  @override
  State<OfflineAutoRunner> createState() => _OfflineAutoRunnerState();
}

class _OfflineAutoRunnerState extends State<OfflineAutoRunner> {
  AppLifecycleListener? _life;
  OfflineAutoUpdate? _auto;
  bool _running = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_auto != null) return;
    _auto = OfflineAutoUpdate(ServicesScope.of(context));
    _life = AppLifecycleListener(onResume: () => unawaited(_check()));
    // Después del primer dibujo, para no frenar el arranque.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  Future<void> _check() async {
    final OfflineAutoUpdate? auto = _auto;
    if (auto == null || _running || !mounted || !auto.enabled) return;
    _running = true;
    try {
      final String language = Localizations.localeOf(context).languageCode;
      final AppLocalizations t = AppLocalizations.of(context);
      final List<CityPack> done = await auto.run(language: language);
      for (final CityPack p in done) {
        FlyraNotes.instance.say(
          FlyraNote(FlyraNoteKind.ok, t.offlineAutoDone(p.city)),
        );
      }
    } on Object {
      // Nunca debe romper la app: se probará la próxima vez.
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
