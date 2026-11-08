// Modo fácil (maqueta "Facil"): la maqueta tal cual (assets/easy/facil.html)
// con letras grandes, botones enormes y solo lo importante:
//   1. La fecha, "Hola, <nombre>" y el botón "Modo normal".
//   2. La tarjeta del vuelo: "TU VUELO · MAÑANA", la hora en grande, de qué
//      ciudad a qué ciudad, la puerta y a qué hora salir de casa. Tocándola
//      se pone o se cambia el viaje.
//   3. Cuatro cuadrados grandes: "Llévame al hotel" (ir andando o la tarjeta
//      para el taxista en el idioma de allí), "Ver a la familia" (tus
//      contactos del SOS: llamar o WhatsApp), "Ayuda en el aeropuerto" (el
//      mensaje listo para tu aerolínea) y "Mis papeles" (la Bóveda).
//   4. "Pregunta a Flyra": escucha con el micro del móvil y contesta con tu
//      viaje (lo mismo que "Habla con Flyra", ver voice_answer.dart).
// Todo sale de lo que tú (o alguien de tu familia) pones en tu viaje y de
// tus contactos del SOS: nada inventado.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../auth/session.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../l10n/generated/app_localizations.dart';
import '../home/home_screen.dart';
import '../route/flight3d.dart' show CountryCodes;
import '../route/web_scene.dart';
import '../route/world_data.dart';
import '../sos/sos_store.dart';
import '../trip/country_facts.dart';
import '../voice/voice_answer.dart';
import 'easy_mode.dart';
import 'easy_page.dart';

/// Inicio normal o Modo fácil, según lo que hayas elegido en Ajustes.
class HomeOrEasy extends StatelessWidget {
  const HomeOrEasy({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: ServicesScope.of(context).easyMode,
    builder: (BuildContext context, bool easy, _) =>
        easy ? const EasyHomeScreen() : const HomeScreen(),
  );
}

class EasyHomeScreen extends StatefulWidget {
  const EasyHomeScreen({super.key});

  /// La última conexión con la página (para las pruebas).
  static WebSceneBridge? lastBridge;

  @override
  State<EasyHomeScreen> createState() => _EasyHomeScreenState();
}

class _EasyHomeScreenState extends State<EasyHomeScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = EasyHomeScreen.lastBridge = WebSceneBridge();
  late EasyTrip _trip = loadEasyTrip(_services.prefs);

  // La página se lee una vez y se guarda (como String, no como Future).
  static String? _pageCache;
  String? _html;
  String? _sent;

  // Los aeropuertos del mundo: para poner "Madrid → Lisboa" en vez de
  // "MAD → LIS" y saber en qué idioma hablarle al taxista. Si no cargan, se
  // enseñan las letras del aeropuerto y la frase en tu idioma.
  Airports? _airports;
  CountryCodes? _codes;
  CountryFacts? _facts;

  // Lo último que contestó Flyra (y cuántas veces ha contestado ya).
  int _flyN = 0;
  String _flyQ = '';
  String _flyA = '';
  VoiceAnswer? _answer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_start()));
  }

  @override
  void dispose() {
    unawaited(_services.speechInput.stop());
    unawaited(_services.speaker.stop());
    super.dispose();
  }

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(easyPage, cache: false);
    } on Object {
      return;
    }
    if (mounted) setState(() {});
    if (_trip.hasFlight) await _loadWorld();
  }

  Future<void> _loadWorld() async {
    try {
      final WorldData world = await WorldData.load();
      final CountryCodes codes = await CountryCodes.load();
      final CountryFacts facts = await CountryFacts.load();
      if (mounted) {
        setState(() {
          _airports = world.airports;
          _codes = codes;
          _facts = facts;
        });
      }
    } on Object {
      // Sin los datos se queda con las letras del aeropuerto.
    }
  }

  String get _lang => Localizations.localeOf(context).languageCode;

  /// "Lisboa" para "LIS" (o "LIS" si no lo conocemos).
  String _city(String? iata) {
    if (iata == null) return '';
    final Airports? all = _airports;
    return (all == null ? null : all[iata])?.city ?? iata;
  }

  /// La frase para el taxista en el idioma del país del hotel, si la app
  /// habla ese idioma. null = no lo sabemos (se enseña solo en el tuyo).
  String? _taxiPhrase() {
    final String? to = _trip.to;
    final Airports? all = _airports;
    final Airport? a = to == null || all == null ? null : all[to];
    final String? iso = a == null ? null : _codes?[a.country];
    final CountryFact? fact = iso == null ? null : _facts?[iso];
    if (fact == null) return null;
    for (final String lang in fact.languages) {
      final bool spoken = AppLocalizations.supportedLocales.any(
        (Locale l) => l.languageCode == lang,
      );
      if (spoken) return lookupAppLocalizations(Locale(lang)).easyTaxiPhrase;
    }
    return null;
  }

  Future<void> _editTrip() async {
    final EasyTrip? trip = await showModalBottomSheet<EasyTrip>(
      context: context,
      isScrollControlled: true,
      // Por encima de la barra de abajo (si no, tapa el botón Guardar).
      useRootNavigator: true,
      builder: (_) => EasyTripSheet(trip: _trip),
    );
    if (trip == null) return;
    await _save(trip);
    if (trip.hasFlight && _airports == null) unawaited(_loadWorld());
  }

  Future<void> _save(EasyTrip trip) async {
    await saveEasyTrip(_services.prefs, trip);
    if (mounted) setState(() => _trip = trip);
  }

  /// "Pregunta a Flyra": escucha, contesta con tu viaje y lo lee en alto.
  Future<void> _listen() async {
    final AppLocalizations t = AppLocalizations.of(context);
    await _services.speaker.stop();
    final String? heard = await _services.speechInput.listen(_lang);
    if (!mounted) return;
    final String text = heard?.trim() ?? '';
    if (text.isEmpty) {
      setState(() {
        _flyN++;
        _flyQ = '';
        _flyA = t.voiceNotHeard;
        _answer = null;
      });
      return;
    }
    final VoiceAnswer answer = voiceAnswer(
      text,
      t: t,
      lang: _lang,
      trip: _trip,
      go: (String route) => unawaited(context.push(route)),
      editTrip: _editTrip,
      openLink: _services.openLink,
    );
    setState(() {
      _flyN++;
      _flyQ = text;
      _flyA = answer.text;
      _answer = answer;
    });
    // Leerlo en alto es un extra: si el móvil no tiene voz, se queda escrito.
    try {
      await _services.speaker.speak(answer.text, _lang);
    } on Exception {
      // Sin voz instalada: no pasa nada.
    }
  }

  /// El mensaje para la aerolínea con la ayuda que pediste.
  void _sendHelp(AppLocalizations t) {
    final int? help = _trip.help;
    if (help == null) return;
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final DateTime? dep = _trip.departure;
    final String msg = t.easyHelpMessage(
      _trip.hasFlight ? '${_city(_trip.from)} → ${_city(_trip.to)}' : '',
      dep == null ? '' : DateFormat.yMMMd(tag).format(dep),
      easyHelpLabel(t, help).toLowerCase(),
    );
    unawaited(_services.share(<String>[], text: msg));
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final List<SosContact> family = loadContacts(_services.prefs);
    final String? address = _trip.hotelAddress;
    switch (p.first) {
      case 'normal':
        unawaited(_services.easyMode.set(false));
      case 'edit':
        unawaited(_editTrip());
      case 'papers':
        unawaited(context.push(Routes.vault));
      case 'walk' when address != null:
        unawaited(_services.openLink(directionsTo(address, walking: true)));
      case 'call' when n != null && n < family.length:
        unawaited(_services.openLink(telUri(family[n].phone)));
      case 'video' when n != null && n < family.length:
        // WhatsApp abre el chat de esa persona: ahí está el botón de
        // videollamada (WhatsApp no deja empezarla desde otra app).
        unawaited(
          _services.openLink(
            Uri.https('wa.me', '/${family[n].dial.replaceAll('+', '')}'),
          ),
        );
      case 'family':
        unawaited(context.push(Routes.sos));
      case 'help' when n != null && n >= -1 && n <= 2:
        unawaited(_save(_trip.withHelp(n < 0 ? null : n)));
      case 'send':
        _sendHelp(t);
      case 'listen':
        unawaited(_listen());
      case 'stop':
        unawaited(_services.speechInput.stop());
        unawaited(_services.speaker.stop());
      case 'act':
        _answer?.onAction?.call();
    }
  }

  Map<String, Object?> _data(AppLocalizations t) {
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final String? name = displayName(SessionScope.of(context).user?.email);
    final List<SosContact> family = loadContacts(_services.prefs);
    final int? help = _trip.help;
    return <String, Object?>{
      'day': easyDay(DateTime.now(), tag),
      'hello': name == null ? t.easyHelloGuest : t.easyHello(name),
      'flight': easyFlightJson(
        _trip,
        t,
        tag,
        DateTime.now(),
        from: _city(_trip.from),
        to: _city(_trip.to),
      ),
      'hotel': <String, Object?>{
        'name': _trip.hotelName ?? '',
        'address': _trip.hotelAddress ?? '',
        'phrase': _taxiPhrase() ?? t.easyTaxiPhrase,
      },
      'family': <Object?>[
        for (int i = 0; i < family.length; i++)
          <String, Object?>{
            'name': family[i].name,
            'rel': family[i].phone,
            'c': easyFamilyColors[i % easyFamilyColors.length],
          },
      ],
      'helpOpts': <String>[for (int i = 0; i < 3; i++) easyHelpLabel(t, i)],
      'help': help,
      'helpDone': help == null
          ? ''
          : t.easyHelpDone(easyHelpLabel(t, help).toLowerCase()),
      'flyN': _flyN,
      'flyQ': _flyQ,
      'flyA': _flyA,
      'flyAct': _answer?.action ?? '',
      't': <String, String>{
        'normal': t.easyNormal,
        'noTrip': t.easyNoTrip,
        'setTrip': t.easySetTrip,
        'toHotel': t.easyToHotel,
        'family': t.easySeeFamily,
        'papers': t.easyPapers,
        'fly': t.easyAskFlyra,
        'flySub': t.easyAskFlyraTalk,
        'noHotel': t.easyNoHotel,
        'yourHotel': t.easyYourHotel,
        'walk': t.easyWalk,
        'showTaxi': t.easyShowTaxi,
        'taxiTitle': t.easyTaxiTitle,
        'back': t.easyBack,
        'listening': t.voiceListening,
        'listenSub': 'Habla con normalidad, como por teléfono',
        'again': '🎤 Preguntar otra cosa',
        'noFamily': t.easyNoFamily,
        'addFamily': t.easyAddFamily,
        'whoCall': t.easyWhoCall,
        'callHint': t.easyCallHint,
        'help': t.easyAirportHelp,
        'helpWhy': t.easyAirportHelpWhy,
        'helpAsk': t.easyHelpAsk,
        'helpSend': t.easyHelpSend,
        'helpChange': t.easyHelpChange,
        'helpAsked': t.easyHelpAsked,
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    final String? page = _pageCache;
    if (page == null) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B1217),
        body: SizedBox.expand(),
      );
    }
    final Map<String, Object?> data = _data(AppLocalizations.of(context));
    final String push = easyPushScript(data);
    if (_html == null) {
      _html = easyPageWith(page, data);
      _sent = push;
    } else if (push != _sent) {
      _sent = push;
      unawaited(_bridge.run(push));
    }
    final String html = _html!;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1217),
      body: SafeArea(
        bottom: false,
        child:
            _services.webScene?.call(html, _onMessage) ??
            WebScene(html: html, onMessage: _onMessage, bridge: _bridge),
      ),
    );
  }
}

/// Para poner o cambiar el viaje (lo puede hacer alguien de la familia).
class EasyTripSheet extends StatefulWidget {
  const EasyTripSheet({super.key, required this.trip});

  final EasyTrip trip;

  @override
  State<EasyTripSheet> createState() => _EasyTripSheetState();
}

class _EasyTripSheetState extends State<EasyTripSheet> {
  late final TextEditingController _from = TextEditingController(
    text: widget.trip.from,
  );
  late final TextEditingController _to = TextEditingController(
    text: widget.trip.to,
  );
  late final TextEditingController _gate = TextEditingController(
    text: widget.trip.gate,
  );
  late final TextEditingController _hotel = TextEditingController(
    text: widget.trip.hotelName,
  );
  late final TextEditingController _address = TextEditingController(
    text: widget.trip.hotelAddress,
  );
  late DateTime? _departure = widget.trip.departure;

  @override
  void dispose() {
    for (final TextEditingController c in <TextEditingController>[
      _from,
      _to,
      _gate,
      _hotel,
      _address,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick() async {
    final DateTime now = DateTime.now();
    final DateTime? day = await showDatePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
      initialDate: _departure ?? now,
    );
    if (day == null || !mounted) return;
    final TimeOfDay? time = await showTimePicker(
      context: context,
      initialTime: _departure == null
          ? const TimeOfDay(hour: 10, minute: 0)
          : TimeOfDay.fromDateTime(_departure!),
    );
    if (time == null || !mounted) return;
    setState(
      () => _departure = DateTime(
        day.year,
        day.month,
        day.day,
        time.hour,
        time.minute,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final String tag = Localizations.localeOf(context).toLanguageTag();
    final DateTime? dep = _departure;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t.easyDeparture,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.event_rounded),
              label: Text(
                dep == null
                    ? t.easyPickDay
                    : DateFormat.yMMMEd(tag).add_Hm().format(dep),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _from,
                    maxLength: 3,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: t.easyFrom,
                      counterText: '',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _to,
                    maxLength: 3,
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      labelText: t.easyTo,
                      counterText: '',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _gate,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: t.easyGateField,
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _hotel,
              decoration: InputDecoration(labelText: t.easyHotelName),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _address,
              decoration: InputDecoration(labelText: t.easyHotelAddress),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(
                EasyTrip.parse(<String, Object?>{
                  if (dep != null) 'departure': dep.toIso8601String(),
                  'from': _from.text,
                  'to': _to.text,
                  'gate': _gate.text,
                  'hotel_name': _hotel.text,
                  'hotel_address': _address.text,
                  // La ayuda del aeropuerto ya pedida se conserva.
                  'help': ?widget.trip.help,
                }),
              ),
              child: Text(t.easySave),
            ),
          ],
        ),
      ),
    );
  }
}
