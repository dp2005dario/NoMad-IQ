// Ajustes del usuario que la app recuerda entre aperturas (idioma, modo viaje,
// el aeropuerto desde el que buscas vuelos, tu nombre en los viajes en grupo
// y tu conversación con Flyra, que solo vive en este móvil).
//
// ChangeNotifier es un "altavoz": cuando el ajuste cambia, avisa a quien esté
// escuchando (la app entera) y la pantalla se vuelve a dibujar en el idioma nuevo.
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Otros datos pequeños que se guardan en el móvil como texto JSON, cada
/// uno con su nombre fijo (así nadie puede escribir claves inventadas).
enum LocalData {
  /// Los últimos tipos de cambio buenos (Divisas funciona sin red).
  fxRates,

  /// Tus tarjetas (nombre, 4 últimos dígitos y comisiones) y el gasto previsto.
  travelCards,

  /// El presupuesto del viaje (qué bote, límite y fechas).
  tripBudget,
}

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

  /// Tu chat con Flyra (texto JSON); null = vacío. Nunca sale del móvil
  /// salvo los últimos mensajes que se mandan al preguntar.
  String? readFlyraChat();
  Future<void> writeFlyraChat(String? json);

  /// Tus sellos de monumentos (texto JSON) para el Pasaporte; null = ninguno.
  String? readStamps();
  Future<void> writeStamps(String json);

  /// Otros datos del móvil (ver [LocalData]); null = no hay / borrar.
  String? readData(LocalData key);
  Future<void> writeData(LocalData key, String? json);

  /// Borra todo lo personal (al borrar la cuenta). Se quedan el idioma y los
  /// tipos de cambio, que no dicen nada de ti.
  Future<void> wipePersonal();
}

/// Lo que NO se borra con [SettingsStore.wipePersonal].
const Set<LocalData> _notPersonal = <LocalData>{LocalData.fxRates};

/// Versión real: guarda en el almacenamiento del móvil (SharedPreferences).
final class PreferencesSettingsStore implements SettingsStore {
  PreferencesSettingsStore(this._prefs);

  static const String _localeKey = 'locale';
  static const String _travelKey = 'travel_mode';
  static const String _originKey = 'flight_origin';
  static const String _groupNameKey = 'group_name';
  static const String _flyraKey = 'flyra_chat';
  static const String _stampsKey = 'stamps';
  final SharedPreferencesWithCache _prefs;

  static Future<PreferencesSettingsStore> open() async {
    final SharedPreferencesWithCache prefs =
        await SharedPreferencesWithCache.create(
          cacheOptions: SharedPreferencesWithCacheOptions(
            // Solo puede leer/escribir estas claves.
            allowList: <String>{
              _localeKey,
              _travelKey,
              _originKey,
              _groupNameKey,
              _flyraKey,
              _stampsKey,
              for (final LocalData d in LocalData.values) 'data_${d.name}',
            },
          ),
        );
    return PreferencesSettingsStore(prefs);
  }

  @override
  String? readLocale() => _prefs.getString(_localeKey);

  @override
  Future<void> wipePersonal() async {
    for (final String key in <String>[
      _travelKey,
      _originKey,
      _groupNameKey,
      _flyraKey,
      _stampsKey,
    ]) {
      await _prefs.remove(key);
    }
    for (final LocalData d in LocalData.values) {
      if (!_notPersonal.contains(d)) await _prefs.remove('data_${d.name}');
    }
  }

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

  @override
  String? readFlyraChat() => _prefs.getString(_flyraKey);

  @override
  Future<void> writeFlyraChat(String? json) => json == null
      ? _prefs.remove(_flyraKey)
      : _prefs.setString(_flyraKey, json);

  @override
  String? readStamps() => _prefs.getString(_stampsKey);

  @override
  Future<void> writeStamps(String json) => _prefs.setString(_stampsKey, json);

  @override
  String? readData(LocalData key) => _prefs.getString('data_${key.name}');

  @override
  Future<void> writeData(LocalData key, String? json) => json == null
      ? _prefs.remove('data_${key.name}')
      : _prefs.setString('data_${key.name}', json);
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

  String? flyraChat;

  @override
  String? readFlyraChat() => flyraChat;

  @override
  Future<void> writeFlyraChat(String? json) async => flyraChat = json;

  String? stamps;

  @override
  String? readStamps() => stamps;

  @override
  Future<void> writeStamps(String json) async => stamps = json;

  final Map<LocalData, String> data = <LocalData, String>{};

  @override
  String? readData(LocalData key) => data[key];

  @override
  Future<void> writeData(LocalData key, String? json) async =>
      json == null ? data.remove(key) : data[key] = json;

  @override
  Future<void> wipePersonal() async {
    travelMode = false;
    flightOrigin = null;
    groupName = null;
    flyraChat = null;
    stamps = null;
    data.removeWhere((LocalData k, _) => !_notPersonal.contains(k));
  }
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
