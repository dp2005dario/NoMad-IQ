// Las audioguías que ya están guardadas en el móvil (pantalla "Sin conexión").
//
// Sirven para dos cosas: en modo avión o sin datos, la audioguía se abre
// igual; y si la red va mal, se usa la copia en vez de dejarte sin nada.
import '../audioguide/audioguide_api.dart';
import 'city_pack.dart';

/// Lo guardado de una zona: el guion y, si se descargó, el audio.
class SavedGuide {
  const SavedGuide({required this.script, this.audio});

  final GuideScript script;
  final AudioManifest? audio;
}

/// De dónde salen las audioguías guardadas.
abstract interface class SavedGuides {
  Future<SavedGuide?> of(String zoneId, String language);
}

/// En los tests y en las compilaciones sin almacenamiento: nunca hay nada.
class NoSavedGuides implements SavedGuides {
  const NoSavedGuides();

  @override
  Future<SavedGuide?> of(String zoneId, String language) async => null;
}

/// Lo guardado por "Sin conexión": busca la zona en las ciudades descargadas.
class OfflineSavedGuides implements SavedGuides {
  const OfflineSavedGuides({required this.library, required this.fileUri});

  final OfflineLibrary library;

  /// Convierte la ruta relativa guardada en la dirección del archivo real.
  final Future<Uri> Function(String path) fileUri;

  @override
  Future<SavedGuide?> of(String zoneId, String language) async {
    for (final CityPack pack in library.all()) {
      for (final PackZone zone in pack.zones) {
        if (zone.id != zoneId) continue;
        // Si descargaste la ciudad en otro idioma, el texto está en ese
        // idioma: se devuelve igual y la pantalla avisa (es mejor que nada).
        final GuideScript script = GuideScript(
          zoneName: zone.name,
          title: zone.title,
          contentLanguage: pack.language,
          segments: <GuideSegment>[
            for (final String t in zone.texts) GuideSegment(t),
          ],
        );
        if (zone.texts.isEmpty) return null;
        if (zone.audio.isEmpty) return SavedGuide(script: script);
        final List<AudioPart> parts = <AudioPart>[];
        for (final PackAudio a in zone.audio) {
          parts.add(
            AudioPart(
              index: a.index,
              url: await fileUri(a.file),
              duration: Duration(seconds: a.seconds),
              text: a.index < zone.texts.length ? zone.texts[a.index] : '',
            ),
          );
        }
        return SavedGuide(
          script: script,
          audio: AudioManifest(
            parts: parts,
            stale: false,
            contentLanguage: pack.language,
          ),
        );
      }
    }
    return null;
  }
}
