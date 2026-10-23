// Ajustes del usuario que la app recuerda entre aperturas (idioma, modo viaje,
// el aeropuerto desde el que buscas vuelos y tu nombre en los viajes en grupo).
//
// ChangeNotifier es un "altavoz": cuando el ajuste cambia, avisa a quien esté
// escuchando (la app entera) y la pantalla se vuelve a dibujar en el idioma nuevo.
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Dónde se guardan los ajustes. Es una interfaz (un "enchufe"): en la app real
/// se conecta SharedPreferences y en los tests una versión en memoria.
abstract interface class SettingsStore {
  String? readLocale();
  Future<void> writeLocale(String? tag);
  bool readTravelMode();
  Future<void> writeTravelMode(bool on);

  /// Aeropuerto de salida de los chollos (código IATA, "MAD"); null = no elegido.
  String? readFlightOrigin();
  Future<void> writeFlightOrigin(String iata);

  /// Cómo te llamas para tus grupos ("Noelia"); null = aún no lo dijiste.
  String? readGroupName();
  Future<void> writeGroupName(String name);
}

/// Versión real: guarda en el almacenamiento del móvil (SharedPreferences).
final class PreferencesSettingsStore implements SettingsStore {
  PreferencesSettingsStore(this._prefs);

  static const String _localeKey = 'locale';
  static const String _travelKey = 'travel_mode';
  static const String _originKey = 'flight_origin';
  static const String _groupNameKey = 'group_name';
  final SharedPreferencesWithCache _prefs;

  static Future<PreferencesSettingsStore> open() async {
    final SharedPreferencesWithCache prefs =
        await SharedPreferencesWithCache.create(
          cacheOptions: const SharedPreferencesWithCacheOptions(
            // Solo puede leer/escribir estas claves.
            allowList: <String>{
              _localeKey,
              _travelKey,
              _originKey,
              _groupNameKey,
            },
          ),
        );
    return PreferencesSettingsStore(prefs);
  }

  @override
  String? readLocale() => _prefs.getString(_localeKey);

  @override
  Future<void> writeLocale(String? tag) => tag == null
      ? _prefs.remove(_localeKey)
      : _prefs.setString(_localeKey, tag);

  @override
  bool readTravelMode() => _prefs.getBool(_travelKey) ?? false;

  @override
  Future<void> writeTravelMode(bool on) => _prefs.setBool(_travelKey, on);

  @override
  String? readFlightOrigin() => _prefs.getString(_originKey);

  @override
  Future<void> writeFlightOrigin(String iata) =>
      _prefs.setString(_originKey, iata);

  @override
  String? readGroupName() => _prefs.getString(_groupNameKey);

  @override
  Future<void> writeGroupName(String name) =>
      _prefs.setString(_groupNameKey, name);
}

/// Versión en memoria para los tests (no toca el disco).
final class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this._locale]);

  String? _locale;

  @override
  String? readLocale() => _locale;

  @override
  Future<void> writeLocale(String? tag) async => _locale = tag;

  bool travelMode = false;

  @override
  bool readTravelMode() => travelMode;

  @override
  Future<void> writeTravelMode(bool on) async => travelMode = on;

  String? flightOrigin;

  @override
  String? readFlightOrigin() => flightOrigin;

  @override
  Future<void> writeFlightOrigin(String iata) async => flightOrigin = iata;

  String? groupName;

  @override
  String? readGroupName() => groupName;

  @override
  Future<void> writeGroupName(String name) async => groupName = name;
}

class SettingsController extends ChangeNotifier {
  SettingsController(this._store) : _locale = _parse(_store.readLocale());

  final SettingsStore _store;
  Locale? _locale;

  /// null = "usa el idioma del móvil". Es lo normal: la mayoría no lo cambia.
  Locale? get locale => _locale;

  Future<void> setLocale(Locale? locale) async {
    if (locale == _locale) return;
    _locale = locale;
    notifyListeners(); // primero se ve el cambio...
    await _store.writeLocale(locale?.toLanguageTag()); // ...y luego se guarda
  }

  /// "pt-BR" -> Locale('pt', 'BR'). Si lo guardado está roto, se ignora.
  static Locale? _parse(String? tag) {
    if (tag == null || tag.isEmpty) return null;
    final List<String> parts = tag.split('-');
    return switch (parts.length) {
      1 => Locale(parts[0]),
      _ => Locale.fromSubtags(
        languageCode: parts[0],
        scriptCode: parts.length == 3 ? parts[1] : null,
        countryCode: parts.last.length == 2 ? parts.last : null,
      ),
    };
  }
}

/// Hace que el SettingsController llegue a cualquier pantalla sin pasarlo a mano
/// de una a otra: `SettingsScope.of(context)`.
class SettingsScope extends InheritedNotifier<SettingsController> {
  const SettingsScope({
    super.key,
    required SettingsController controller,
    required super.child,
  }) : super(notifier: controller);

  static SettingsController of(BuildContext context) {
    final SettingsScope? scope = context
        .dependOnInheritedWidgetOfExactType<SettingsScope>();
    assert(scope != null, 'Falta SettingsScope encima de este widget');
    return scope!.notifier!;
  }
}
