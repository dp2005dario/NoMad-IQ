// Asistente (maqueta "Asistente"), igual que la maqueta, con dos pestañas
// arriba:
//
//   - Intérprete: el móvil entre los dos. La parte de arriba está girada
//     para la otra persona y le sale, en SU idioma, lo que tú dices. Abajo,
//     tus frases y las suyas traducidas, "Habla la otra persona" y "Hablo
//     yo". Todo dentro del móvil (ver interpreter.dart): con los dos idiomas
//     descargados, funciona en modo avión. Si la otra persona habla otro
//     idioma, Flyra lo detecta y cambia sola.
//   - Pregunta: la cámara de fondo. Tocas el botón de las ondas y
//     preguntas lo que ves ("¿qué es este edificio rojo?"): la app mira qué
//     monumento tienes delante (foto + GPS) y Flyra te lo cuenta en voz alta.
//
// Mantener pulsado "Hablo yo" o "Habla la otra persona" deja escribir en
// vez de hablar (con ruido, o si el micro no va).
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/api_client.dart';
import '../../core/motion.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../camera/camera_device.dart';
import '../camera/landmarks_api.dart';
import '../flyra/flyra_api.dart';
import '../map/geo.dart' show PositionFix;
import '../map/location.dart';
import 'assistant_texts.dart';
import 'interpreter.dart';

enum _Tab { ask, talk }

/// Una frase de la conversación.
class _Line {
  const _Line({
    required this.mine,
    required this.original,
    required this.translated,
  });

  /// La dije yo (si no, la otra persona).
  final bool mine;
  final String original;
  final String translated;
}

const Color _bg = Color(0xFF0B1217);
const Color _ink = Color(0xFFF2F5F3);
const Color _accent = Color(0xFF3DDC97);
const Color _muted = Color(0xFF9FB0B8);
const Color _lilac = Color(0xFFB9AEDB);

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen>
    with TickerProviderStateMixin {
  late final AppServices _services = ServicesScope.of(context);
  _Tab _tab = _Tab.talk;

  late final String _mine = () {
    final String code = Localizations.localeOf(context).languageCode;
    return interpreterLanguages.containsKey(code) ? code : 'en';
  }();
  late String _theirs = () {
    final String? saved = _services.prefs.readData(LocalData.interpreterLang);
    if (saved != null && interpreterLanguages.containsKey(saved)) return saved;
    return _mine == 'en' ? 'es' : 'en';
  }();

  final List<_Line> _lines = <_Line>[];
  final ScrollController _scroll = ScrollController();

  /// null = nadie habla; true = yo; false = la otra persona.
  bool? _listening;
  bool _busy = false;

  /// Flyra está mirando en qué idioma habló la otra persona.
  bool _detecting = false;

  /// Ya se oyó a la otra persona: su idioma está confirmado.
  bool _known = false;

  /// Leer en voz alta (apagado al empezar, como en la maqueta).
  bool _voice = false;

  /// Faltan modelos por descargar (null = aún no se sabe).
  List<String>? _missing;
  bool _downloading = false;

  // Pregunta: la cámara, lo que preguntaste y lo que contestó Flyra.
  CameraDevice? _camera;
  bool _cameraStarting = false;
  String? _question;
  String? _place;
  String? _answer;
  bool _asking = false;
  bool _askListening = false;

  /// Lo que va entendiendo mientras hablas (se ve en directo).
  String _partial = '';

  // Las ondas de los botones y las banderas que giran al detectar.
  late final AnimationController _wave = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final AnimationController _roll = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final AnimationController _fly = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void initState() {
    super.initState();
    Motion.loop(_fly, reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  @override
  void dispose() {
    unawaited(_services.speechInput.stop());
    unawaited(_services.speaker.stop());
    unawaited(_camera?.dispose());
    _wave.dispose();
    _roll.dispose();
    _fly.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Las ondas solo se mueven mientras alguien habla o Flyra piensa.
  void _syncWaves() {
    final bool on = _listening != null || _askListening || _asking;
    if (on && !_wave.isAnimating) {
      Motion.loop(_wave, reverse: true);
    } else if (!on) {
      _wave
        ..stop()
        ..value = 0;
    }
    if (_detecting && !_roll.isAnimating) {
      Motion.loop(_roll);
    } else if (!_detecting) {
      _roll.stop();
    }
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _syncWaves();
  }

  Future<void> _check() async {
    final List<String> missing = <String>[
      for (final String l in <String>{_mine, _theirs})
        if (!await _services.translator.hasModel(l)) l,
    ];
    if (mounted) setState(() => _missing = missing);
  }

  Future<void> _download() async {
    final List<String> missing = _missing ?? const <String>[];
    setState(() => _downloading = true);
    bool ok = true;
    for (final String l in missing) {
      ok = await _services.translator.download(l) && ok;
    }
    if (!mounted) return;
    setState(() => _downloading = false);
    if (!ok) _snack(AppLocalizations.of(context).assistantDownloadFailed);
    await _check();
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  String _name(String code) => languageNameFor(
    code,
    Localizations.localeOf(context).languageCode,
    interpreterLanguages,
  );

  Future<void> _setTheirs(String code) async {
    if (code == _theirs) return;
    setState(() => (_theirs = code, _missing = null, _known = false));
    await _services.prefs.writeData(LocalData.interpreterLang, code);
    await _check();
  }

  Future<void> _pickTheirs() async {
    final String? code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF16212A),
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final MapEntry<String, String> e
                in interpreterLanguages.entries)
              if (e.key != _mine)
                ListTile(
                  leading: Text(
                    languageFlags[e.key] ?? '🌐',
                    style: const TextStyle(fontSize: 22),
                  ),
                  title: Text(e.value),
                  subtitle: Text(_name(e.key)),
                  selected: e.key == _theirs,
                  onTap: () => Navigator.of(context).pop(e.key),
                ),
          ],
        ),
      ),
    );
    if (code == null || !mounted) return;
    await _setTheirs(code);
  }

  /// Lo que dijo o escribió la otra persona: si Flyra ve que está en otro
  /// idioma (ni el tuyo ni el elegido), cambia solo el idioma de su lado y
  /// lo avisa.
  Future<void> _detect(String text) async {
    setState(() => _detecting = true);
    final String? found = await _services.languageGuesser.guess(text);
    if (!mounted) return;
    setState(() => _detecting = false);
    if (found == null || found == _theirs || found == _mine) return;
    setState(() => (_theirs = found, _missing = null));
    await _services.prefs.writeData(LocalData.interpreterLang, found);
    if (!mounted) return;
    _snack(
      AppLocalizations.of(context)
          .assistantDetected(interpreterLanguages[found] ?? found),
    );
    await _check();
  }

  /// Traduce y lo añade a la conversación (y lo lee en alto si quieres).
  Future<void> _say(String text, {required bool mine}) async {
    if (!mine) await _detect(text);
    if (!mounted) return;
    final String from = mine ? _mine : _theirs;
    final String to = mine ? _theirs : _mine;
    setState(() => _busy = true);
    try {
      final String translated = await _services.translator.translate(
        text,
        from: from,
        to: to,
      );
      if (!mounted) return;
      setState(() {
        _lines.add(_Line(mine: mine, original: text, translated: translated));
        if (!mine) _known = true;
      });
      _toBottom();
      if (_voice) unawaited(_services.speaker.speak(translated, to));
    } on TranslationUnavailable {
      if (mounted) _snack(AppLocalizations.of(context).assistantNeedModels);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      unawaited(
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        ),
      );
    }
  });

  Future<void> _listen({required bool mine}) async {
    if (_listening != null) {
      await _services.speechInput.stop();
      return;
    }
    if (_busy) return;
    setState(() {
      _listening = mine;
      _partial = '';
    });
    final String? heard = await _services.speechInput.listen(
      mine ? _mine : _theirs,
      onPartial: (String p) {
        if (mounted) setState(() => _partial = p);
      },
    );
    if (!mounted) return;
    setState(() {
      _listening = null;
      _partial = '';
    });
    if (heard == null) {
      _snack(AppLocalizations.of(context).assistantDidntHear);
      return;
    }
    await _say(heard, mine: mine);
  }

  /// Escribir en vez de hablar (mantener pulsado el botón).
  Future<void> _type({required bool mine}) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final TextEditingController text = TextEditingController();
    final String? typed = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          mine ? t.assistantType : interpreterLanguages[_theirs] ?? '',
        ),
        content: TextField(
          controller: text,
          autofocus: true,
          maxLength: 500,
          maxLines: 3,
          minLines: 1,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(text.text.trim()),
            child: Text(t.assistantTranslate),
          ),
        ],
      ),
    );
    text.dispose();
    if (typed == null || typed.isEmpty || !mounted) return;
    await _say(typed, mine: mine);
  }

  // ---- Pregunta -----------------------------------------------------------

  void _pick(_Tab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    if (tab == _Tab.ask) unawaited(_startCamera());
  }

  /// La cámara de fondo de "Pregunta". Sin cámara (o sin permiso), el fondo
  /// es oscuro y se puede preguntar igual.
  Future<void> _startCamera() async {
    final CameraFactory? make = _services.newCamera;
    if (make == null || _camera != null || _cameraStarting) return;
    _cameraStarting = true;
    final CameraDevice camera = make();
    final CameraStart started = await camera.start();
    _cameraStarting = false;
    if (!mounted || started != CameraStart.ready) {
      await camera.dispose();
      return;
    }
    setState(() => _camera = camera);
  }

  Future<PositionFix?> _position() async {
    final LocationSource gps = _services.location;
    try {
      if (await gps.check() != LocationAccess.granted) return null;
      return await positionNow(gps, wait: const Duration(seconds: 8));
    } on Object {
      return null;
    }
  }

  /// ¿Qué tengo delante? Foto + GPS; si no se sabe, null (Flyra contesta
  /// igual, sin el sitio).
  Future<String?> _whatIsHere(String language) async {
    final CameraDevice? camera = _camera;
    final Future<Uint8List?> photo = camera == null
        ? Future<Uint8List?>.value()
        : camera.takePhoto().then<Uint8List?>(
            (Uint8List b) => b,
            onError: (Object _) => null,
          );
    final PositionFix? fix = await _position();
    final Uint8List? jpeg = await photo;
    if (fix == null) return null;
    try {
      final Recognition found = await _services.landmarks.recognize(
        lat: fix.point.lat,
        lon: fix.point.lon,
        accuracyM: fix.accuracyM,
        language: language,
        jpeg: jpeg,
      );
      return found.status == RecognitionStatus.recognized
          ? found.landmark?.name
          : null;
    } on ApiException {
      return null;
    }
  }

  /// Preguntar a Flyra: [typed] es un botón de sugerencia; sin él, se
  /// escucha la pregunta.
  Future<void> _ask([String? typed]) async {
    if (_asking || _askListening) {
      await _services.speechInput.stop();
      return;
    }
    final AppLocalizations t = AppLocalizations.of(context);
    final String language = Localizations.localeOf(context).languageCode;
    String? q = typed;
    if (q == null) {
      setState(() {
        _askListening = true;
        _partial = '';
        _question = null;
        _answer = null;
      });
      q = await _services.speechInput.listen(
        language,
        onPartial: (String p) {
          if (mounted) setState(() => _partial = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _askListening = false;
        _partial = '';
      });
      if (q == null || q.trim().isEmpty) {
        _snack(t.assistantDidntHear);
        return;
      }
    }
    final String question = q.trim();
    setState(() {
      _question = question;
      _asking = true;
      _answer = null;
    });
    unawaited(_services.speaker.stop());
    final String? place = await _whatIsHere(language);
    if (!mounted) return;
    if (place != null) setState(() => _place = place);
    String answer;
    try {
      // Si la conexión falla un momento (pasa al soltar el micro), se
      // vuelve a intentar una vez antes de decir "sin conexión".
      Future<FlyraReply> once() => _services.flyra.ask(
        <ChatTurn>[ChatTurn(ChatRole.user, question)],
        language: language,
        // El servidor acepta como mucho 80 letras de sitio.
        place: _place == null || _place!.length <= 80
            ? _place
            : _place!.substring(0, 80),
      );
      FlyraReply reply;
      try {
        reply = await once();
      } on ApiException catch (e) {
        if (e.error != ApiError.network) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        reply = await once();
      }
      answer = reply.text;
      unawaited(_services.speaker.speak(answer, language));
    } on ApiException catch (e) {
      answer = switch (e.error) {
        ApiError.network => 'Sin conexión: ahora no puedo preguntarlo.',
        ApiError.rateLimited =>
          'Hoy ya no quedan preguntas. Mañana te cuento más.',
        _ => 'Ahora no puedo contestar. Prueba otra vez en un momento.',
      };
    }
    if (!mounted) return;
    setState(() {
      _answer = answer;
      _asking = false;
    });
  }

  // ---- Pantalla -----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (_tab == _Tab.ask) _askBody(t) else _talkBody(t),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                // Alto fijo: sin él, el Center de las pestañas ocupaba toda
                // la pantalla y "Pregunta | Intérprete" salía en medio,
                // tapando lo de debajo.
                child: SizedBox(
                  height: 44,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: <Widget>[
                      _Round(
                        tooltip: MaterialLocalizations.of(context)
                            .closeButtonTooltip,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Center(
                            child: _Tabs(
                              labels: <String>[t.assistantAsk, 'Intérprete'],
                              selected: _tab.index,
                              onPick: (int i) => _pick(_Tab.values[i]),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 44),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _talkBody(AppLocalizations t) {
    final (String head, String hello) = otherSide(_theirs);
    final _Line? lastMine = _lines.where((_Line l) => l.mine).lastOrNull;
    final bool meListening = _listening == true;
    final bool themListening = _listening == false || _detecting;
    final String theirName = _name(_theirs);
    final String myName = _name(_mine);
    final List<String>? missing = _missing;
    final double top = MediaQuery.of(context).padding.top + 290 - 44;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // La parte de la otra persona, girada para que la lea de frente.
        SizedBox(
          height: top,
          child: RotatedBox(
            quarterTurns: 2,
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: <Color>[Color(0xFF1B1A2E), Color(0xFF221F3A)],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(16, 18, 16, 70),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          _known
                              ? '${interpreterLanguages[_theirs]} · $head'
                              : head,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'Manrope',
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.9,
                            color: _lilac,
                          ),
                        ),
                      ),
                      if (themListening)
                        _Waves(
                          animation: _wave,
                          on: true,
                          color: _lilac,
                          height: 16,
                          width: 3,
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: _In(
                      key: ValueKey<int>(_lines.length),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0x0FFFFFFF),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF3A3466)),
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                meListening
                                    ? (_partial.isEmpty ? '…' : '$_partial…')
                                    : lastMine == null
                                    ? hello
                                    : lastMine.translated,
                                textDirection: rtlLanguages.contains(_theirs)
                                    ? TextDirection.rtl
                                    : TextDirection.ltr,
                                style: const TextStyle(
                                  fontSize: 22,
                                  fontWeight: FontWeight.w700,
                                  height: 1.4,
                                  color: _ink,
                                ),
                              ),
                              if (lastMine != null && !meListening && _voice)
                                const Padding(
                                  padding: EdgeInsets.only(top: 6),
                                  child: Text(
                                    '🔊',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _lilac,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Container(
          height: 2,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[Color(0x003DDC97), _accent, Color(0x003DDC97)],
            ),
          ),
        ),
        Expanded(
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _Detect(
                          detecting: _detecting,
                          known: _known,
                          roll: _roll,
                          flag: languageFlags[_theirs] ?? '🌐',
                          title: _detecting
                              ? 'DETECTANDO IDIOMA…'
                              : _listening == false && !_known
                              ? 'ESCUCHANDO…'
                              : _known
                              ? 'IDIOMA DETECTADO'
                              : 'IDIOMA DE LA OTRA PERSONA',
                          text: _detecting
                              ? 'Comparando con ${interpreterLanguages.length} idiomas'
                              : _known
                              ? '$theirName → $myName'
                              : '$theirName · toca para cambiar',
                          tooltip: t.assistantTheirLanguage,
                          onTap: _pickTheirs,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _VoiceButton(
                        on: _voice,
                        tooltip: _voice ? t.driveVoiceOff : t.driveVoiceOn,
                        onTap: () {
                          setState(() => _voice = !_voice);
                          if (!_voice) unawaited(_services.speaker.stop());
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _lines.isEmpty && (missing?.isEmpty ?? true)
                        ? _Empty(fly: _fly, myName: myName)
                        : ListView(
                            controller: _scroll,
                            padding: const EdgeInsets.only(bottom: 4),
                            children: <Widget>[
                              if (missing != null && missing.isNotEmpty)
                                _Download(
                                  fly: _fly,
                                  text: t.assistantDownload(
                                    missing
                                        .map(
                                          (String l) =>
                                              interpreterLanguages[l] ?? l,
                                        )
                                        .join(', '),
                                  ),
                                  busy: _downloading,
                                  button: t.assistantDownloadButton,
                                  onTap: _download,
                                ),
                              for (int i = 0; i < _lines.length; i++)
                                _Bubble(
                                  key: ValueKey<int>(i),
                                  line: _lines[i],
                                  flag: languageFlags[_theirs] ?? '🌐',
                                  type: i == _lines.length - 1,
                                ),
                            ],
                          ),
                  ),
                  // Lo que va entendiendo, en directo, mientras alguien habla.
                  AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    child: _listening == null
                        ? const SizedBox(width: double.infinity)
                        : Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: _LiveCaption(
                              text: _partial,
                              hint: t.assistantTapWhenDone,
                              mine: meListening,
                              level: _services.speechInput.level,
                              wave: _wave,
                            ),
                          ),
                  ),
                  const SizedBox(height: 10),
                  _LangChips(
                    selected: _theirs,
                    mine: _mine,
                    name: _name,
                    onPick: (String c) => unawaited(_setTheirs(c)),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: _TalkButton(
                          tooltip: interpreterLanguages[_theirs] ?? _theirs,
                          label: themListening
                              ? 'Escuchando…'
                              : 'Habla la otra persona',
                          hint: themListening && _listening == false
                              ? t.assistantTapWhenDone
                              : _known
                              ? 'En ${theirName.toLowerCase()}'
                              : 'Detecto su idioma',
                          on: themListening,
                          background: const Color(0xFF2E2A4A),
                          foreground: _ink,
                          micBg: const Color(0xFF4A4380),
                          waveColor: const Color(0xFFE5DBFF),
                          wave: _wave,
                          onTap: () => unawaited(_listen(mine: false)),
                          onLong: () => unawaited(_type(mine: false)),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _TalkButton(
                          tooltip: t.assistantSpeak,
                          label: meListening ? 'Te escucho…' : 'Hablo yo',
                          hint: meListening
                              ? t.assistantTapWhenDone
                              : 'En ${myName.toLowerCase()}',
                          on: meListening,
                          background: _accent,
                          foreground: _bg,
                          micBg: _bg,
                          waveColor: _accent,
                          wave: _wave,
                          onTap: () => unawaited(_listen(mine: true)),
                          onLong: () => unawaited(_type(mine: true)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _askBody(AppLocalizations t) {
    // Mientras hablas se ve lo que va entendiendo; luego, tu pregunta.
    final String? q = _askListening
        ? (_partial.isEmpty ? null : _partial)
        : _question;
    final double bottom = MediaQuery.of(context).padding.bottom;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        _camera?.preview() ??
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[Color(0xFF1C2A33), _bg],
                ),
              ),
            ),
        // Abajo se oscurece para que se lea bien la respuesta.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: <double>[0.45, 1],
                colors: <Color>[Color(0x000B1217), Color(0xE60B1217)],
              ),
            ),
          ),
        ),
        // El marco de rayas: apunta ahí.
        const SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(56, 80, 56, 260),
            child: CustomPaint(painter: _DashedFrame()),
          ),
        ),
        if (q != null)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(40, 96, 40, 0),
              child: Align(
                alignment: Alignment.topLeft,
                child: _In(
                  key: ValueKey<bool>(_askListening),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xD90B1217),
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(18),
                        topRight: Radius.circular(18),
                        bottomRight: Radius.circular(18),
                        bottomLeft: Radius.circular(4),
                      ),
                      border: Border.all(
                        color: _askListening
                            ? _accent
                            : const Color(0x33FFFFFF),
                      ),
                    ),
                    child: Text(
                      _askListening ? '$q…' : '«$q»',
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: _ink,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 16 + bottom,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _In(
                delay: 300,
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[Color(0xF21A2233), Color(0xF2141E25)],
                    ),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: const Color(0xFF2C3A48)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          SizedBox(
                            width: 40,
                            height: 40,
                            child: ClipOval(
                              child: Image.asset(
                                'assets/map/flyra.webp',
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    const ColoredBox(color: _accent),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                const Text(
                                  'FLYRA TE LO CUENTA',
                                  style: TextStyle(
                                    fontFamily: 'Manrope',
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.66,
                                    color: _muted,
                                  ),
                                ),
                                Text(
                                  _place ?? t.assistantAskTitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'BricolageGrotesque',
                                    fontSize: 19,
                                    fontWeight: FontWeight.w800,
                                    color: _ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (_asking)
                            _Waves(
                              animation: _wave,
                              on: true,
                              color: _accent,
                              height: 18,
                              width: 3,
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: SingleChildScrollView(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 350),
                            child: Text(
                              _asking
                                  ? 'Flyra está mirando…'
                                  : _askListening
                                  ? t.assistantTapWhenDone
                                  : _answer ?? t.assistantAskBody,
                              key: ValueKey<String>(
                                '${_asking}_${_askListening}_${_answer ?? ''}',
                              ),
                              style: const TextStyle(
                                fontFamily: 'Manrope',
                                fontSize: 14.5,
                                height: 1.5,
                                color: Color(0xFFDCE5E9),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // El micro grande: toca, pregunta y vuelve a tocar (o cállate)
              // y Flyra contesta.
              Center(
                child: _BigMic(
                  tooltip: _askListening
                      ? t.assistantTapWhenDone
                      : t.assistantTapToAsk,
                  on: _askListening,
                  busy: _asking,
                  level: _services.speechInput.level,
                  wave: _wave,
                  onTap: () => unawaited(_ask()),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _askListening ? t.assistantTapWhenDone : t.assistantTapToAsk,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Manrope',
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: _muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// El micro grande de "Pregunta": un círculo con aros que laten más fuerte
/// cuanto más alto hablas. Mientras Flyra piensa, gira un arco.
class _BigMic extends StatelessWidget {
  const _BigMic({
    required this.tooltip,
    required this.on,
    required this.busy,
    required this.level,
    required this.wave,
    required this.onTap,
  });

  final String tooltip;
  final bool on;
  final bool busy;
  final ValueListenable<double> level;
  final Animation<double> wave;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[wave, level]),
          builder: (BuildContext context, Widget? child) {
            final double l = on ? level.value : 0;
            final double w = wave.value;
            return SizedBox(
              width: 120,
              height: 120,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  if (on || busy)
                    for (int i = 0; i < 2; i++)
                      Container(
                        width: 78 + (26 + 22 * l) * ((w + i * 0.5) % 1),
                        height: 78 + (26 + 22 * l) * ((w + i * 0.5) % 1),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: (busy ? const Color(0xFFB69CFF) : _accent)
                                .withValues(
                                  alpha: 0.6 * (1 - (w + i * 0.5) % 1),
                                ),
                            width: 2,
                          ),
                        ),
                      ),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    width: 78 + 8 * l,
                    height: 78 + 8 * l,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: on
                            ? const <Color>[
                                Color(0xFFFF6B8B),
                                Color(0xFFFF8A65),
                              ]
                            : const <Color>[_accent, Color(0xFF6CA8FF)],
                      ),
                      boxShadow: <BoxShadow>[
                        BoxShadow(
                          color: (on ? const Color(0xFFFF6B8B) : _accent)
                              .withValues(alpha: 0.45),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    alignment: Alignment.center,
                    child: on
                        ? _Waves(
                            animation: wave,
                            on: true,
                            color: Colors.white,
                            count: 5,
                            height: 26,
                            width: 4,
                          )
                        : Icon(
                            busy
                                ? Icons.auto_awesome_rounded
                                : Icons.mic_rounded,
                            size: 34,
                            color: _bg,
                          ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );
}

/// La tarjeta de "en directo": lo que el micro va entendiendo, con unas
/// ondas que suben y bajan con tu voz.
class _LiveCaption extends StatelessWidget {
  const _LiveCaption({
    required this.text,
    required this.hint,
    required this.mine,
    required this.level,
    required this.wave,
  });

  final String text;
  final String hint;
  final bool mine;
  final ValueListenable<double> level;
  final Animation<double> wave;

  @override
  Widget build(BuildContext context) {
    final Color c = mine ? _accent : _lilac;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            colors: <Color>[c.withValues(alpha: 0.16), const Color(0x0DFFFFFF)],
          ),
          border: Border.all(color: c.withValues(alpha: 0.55)),
        ),
        child: Row(
          children: <Widget>[
            _Waves(
              animation: wave,
              on: true,
              color: c,
              height: 22,
              width: 3,
              level: level,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    text.isEmpty ? '…' : text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _ink,
                    ),
                  ),
                  Text(
                    hint,
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: c,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// La X de cerrar: un círculo oscuro medio transparente.
class _Round extends StatelessWidget {
  const _Round({required this.tooltip, required this.onTap});

  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: Color(0xBF0B1217),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.close_rounded, color: _ink, size: 22),
        ),
      ),
    ),
  );
}

/// "Pregunta | Intérprete": las dos pestañas de arriba.
class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.labels,
    required this.selected,
    required this.onPick,
  });

  final List<String> labels;
  final int selected;
  final void Function(int) onPick;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xBF0B1217),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < labels.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: 4),
            Semantics(
              selected: i == selected,
              button: true,
              child: GestureDetector(
                onTap: () => onPick(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == selected ? _ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                      color: i == selected ? _bg : _ink,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Aparece subiendo un poco (como "it-in" / "nq-in" de la maqueta).
class _In extends StatelessWidget {
  const _In({super.key, required this.child, this.delay = 0});

  final Widget child;
  final int delay;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: Duration(milliseconds: 400 + delay),
    curve: Interval(delay / (400 + delay), 1, curve: Curves.easeOut),
    builder: (BuildContext context, double v, Widget? child) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 12 * (1 - v)), child: child),
    ),
    child: child,
  );
}

/// Las barritas que suben y bajan (la voz).
class _Waves extends StatelessWidget {
  const _Waves({
    required this.animation,
    required this.on,
    required this.color,
    this.count = 5,
    this.height = 20,
    this.width = 4,
    this.level,
  });

  /// Lo fuerte que suena tu voz (0..1): con él, las ondas crecen al hablar
  /// alto y casi se paran en silencio.
  final ValueListenable<double>? level;
  final Animation<double> animation;
  final bool on;
  final Color color;
  final int count;
  final double height;
  final double width;

  static const List<double> _still = <double>[0.35, 0.6, 0.9, 0.6, 0.35];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge(<Listenable?>[animation, level]),
    builder: (BuildContext context, Widget? _) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int k = 0; k < count; k++) ...<Widget>[
          if (k > 0) SizedBox(width: width < 4 ? 2 : 3),
          Transform.scale(
            scaleY: on
                ? 0.3 +
                      (level == null ? 0.7 : 0.15 + 0.55 * level!.value) *
                          (0.5 +
                              0.5 *
                                  math.sin(
                                    (animation.value + k * 0.14) * 2 * math.pi,
                                  ))
                : _still[k % _still.length],
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ],
      ],
    ),
  );
}

/// "IDIOMA DE LA OTRA PERSONA": la bandera (o las banderas girando mientras
/// detecta) y el idioma. Tocándolo, eliges otro.
class _Detect extends StatelessWidget {
  const _Detect({
    required this.detecting,
    required this.known,
    required this.roll,
    required this.flag,
    required this.title,
    required this.text,
    required this.tooltip,
    required this.onTap,
  });

  final bool detecting;
  final bool known;
  final Animation<double> roll;
  final String flag;
  final String title;
  final String text;
  final String tooltip;
  final VoidCallback onTap;

  static const List<String> _roll = <String>[
    '🇯🇵',
    '🇫🇷',
    '🇲🇦',
    '🇬🇧',
    '🇩🇪',
    '🇮🇹',
    '🇨🇳',
    '🇵🇹',
    '🇰🇷',
    '🇯🇵',
  ];

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: known ? const Color(0xFF12291F) : const Color(0xFF141E25),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: detecting
                  ? _lilac
                  : known
                  ? const Color(0xFF2E8A5E)
                  : const Color(0xFF26363F),
            ),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 30,
                height: 30,
                clipBehavior: Clip.antiAlias,
                decoration: const BoxDecoration(
                  color: _bg,
                  shape: BoxShape.circle,
                ),
                child: detecting
                    ? AnimatedBuilder(
                        animation: roll,
                        builder: (BuildContext context, Widget? _) =>
                            OverflowBox(
                              alignment: Alignment.topCenter,
                              maxHeight: 200,
                              child: Transform.translate(
                                offset: Offset(0, -180 * roll.value),
                                child: Column(
                                  children: <Widget>[
                                    for (final String f in _roll)
                                      SizedBox(
                                        height: 20,
                                        child: Center(
                                          child: Text(
                                            f,
                                            style: const TextStyle(
                                              fontSize: 18,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                      )
                    : TweenAnimationBuilder<double>(
                        key: ValueKey<String>(flag),
                        tween: Tween<double>(begin: 0.4, end: 1),
                        duration: const Duration(milliseconds: 500),
                        curve: Curves.easeOutBack,
                        builder: (BuildContext context, double v, Widget? _) =>
                            Transform.scale(
                              scale: v,
                              child: Center(
                                child: Text(
                                  known ? flag : '🌐',
                                  style: const TextStyle(fontSize: 20),
                                ),
                              ),
                            ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.6,
                        color: _muted,
                      ),
                    ),
                    Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'Manrope',
                        fontSize: 13.5,
                        fontWeight: FontWeight.w800,
                        color: _ink,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// El altavoz: leer las traducciones en voz alta o no.
class _VoiceButton extends StatelessWidget {
  const _VoiceButton({
    required this.on,
    required this.tooltip,
    required this.onTap,
  });

  final bool on;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      toggled: on,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: on ? _accent : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            border: on ? null : Border.all(color: const Color(0xFF33444E)),
          ),
          child: Icon(
            on ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            size: 20,
            color: on ? _bg : const Color(0xFFDCE5E9),
          ),
        ),
      ),
    ),
  );
}

/// Flyra explica cómo va, mientras no hay frases.
class _Empty extends StatelessWidget {
  const _Empty({required this.fly, required this.myName});

  final Animation<double> fly;
  final String myName;

  @override
  Widget build(BuildContext context) => Center(
    child: _In(
      child: _FlyraSays(
        fly: fly,
        child: Text.rich(
          TextSpan(
            children: <InlineSpan>[
              const TextSpan(
                text:
                    'Deja el móvil entre los dos. Cuando la otra persona '
                    'hable, toca su botón: ',
              ),
              const TextSpan(
                text: 'yo detecto su idioma',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              TextSpan(
                text:
                    ' y aquí abajo te sale en ${myName.toLowerCase()}. '
                    'Arriba le sale a ella lo que tú digas.',
              ),
            ],
          ),
          style: const TextStyle(
            fontFamily: 'Manrope',
            fontSize: 13.5,
            height: 1.45,
            color: Color(0xFFDFF7EE),
          ),
        ),
      ),
    ),
  );
}

/// Flyra (la que flota) con su bocadillo verde.
class _FlyraSays extends StatelessWidget {
  const _FlyraSays({required this.fly, required this.child});

  final Animation<double> fly;
  final Widget child;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.end,
    children: <Widget>[
      AnimatedBuilder(
        animation: fly,
        builder: (BuildContext context, Widget? child) {
          final double v = Curves.easeInOut.transform(fly.value);
          return Transform.translate(
            offset: Offset(0, -4 * v),
            child: Transform.rotate(
              angle: (-4 + 8 * v) * math.pi / 180,
              child: child,
            ),
          );
        },
        child: ClipOval(
          child: Image.asset(
            'assets/map/flyra.webp',
            width: 44,
            height: 44,
            fit: BoxFit.cover,
            excludeFromSemantics: true,
          ),
        ),
      ),
      const SizedBox(width: 10),
      Flexible(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF13342A),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
            ),
            border: Border.all(color: const Color(0xFF23523F)),
          ),
          child: child,
        ),
      ),
    ],
  );
}

/// Faltan idiomas: Flyra lo dice con su botón de descargar.
class _Download extends StatelessWidget {
  const _Download({
    required this.fly,
    required this.text,
    required this.busy,
    required this.button,
    required this.onTap,
  });

  final Animation<double> fly;
  final String text;
  final bool busy;
  final String button;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: _FlyraSays(
      fly: fly,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            text,
            style: const TextStyle(
              fontFamily: 'Manrope',
              fontSize: 13.5,
              height: 1.45,
              color: Color(0xFFDFF7EE),
            ),
          ),
          const SizedBox(height: 8),
          if (busy)
            const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Tooltip(
              message: button,
              child: GestureDetector(
                onTap: onTap,
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  constraints: const BoxConstraints(maxWidth: 200),
                  decoration: BoxDecoration(
                    color: _accent,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    button,
                    style: const TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: _bg,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

/// Una frase: arriba lo dicho, abajo la traducción (que se va escribiendo).
class _Bubble extends StatelessWidget {
  const _Bubble({
    super.key,
    required this.line,
    required this.flag,
    required this.type,
  });

  final _Line line;
  final String flag;

  /// La última: se escribe letra a letra.
  final bool type;

  @override
  Widget build(BuildContext context) {
    final bool them = !line.mine;
    final String full = line.translated;
    return Align(
      alignment: them ? Alignment.centerLeft : Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.88,
        alignment: them ? Alignment.centerLeft : Alignment.centerRight,
        child: Align(
          alignment: them ? Alignment.centerLeft : Alignment.centerRight,
          child: _In(
            child: Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: them ? const Color(0xFF1E1C33) : const Color(0xFF13342A),
                border: Border.all(
                  color: them
                      ? const Color(0xFF3A3466)
                      : const Color(0xFF23523F),
                ),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(18),
                  topRight: const Radius.circular(18),
                  bottomLeft: Radius.circular(them ? 4 : 18),
                  bottomRight: Radius.circular(them ? 18 : 4),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    them ? '$flag ${line.original}' : 'Tú: ${line.original}',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 12,
                      color: them ? _lilac : const Color(0xFF9FD9BE),
                    ),
                  ),
                  const SizedBox(height: 4),
                  TweenAnimationBuilder<int>(
                    tween: IntTween(
                      begin: type ? 0 : full.length,
                      end: full.length,
                    ),
                    duration: Duration(
                      milliseconds: type ? full.length * 17 : 1,
                    ),
                    builder: (BuildContext context, int n, Widget? _) => Text(
                      // Al acabar, el texto entero (lo que buscan las pruebas).
                      n >= full.length
                          ? (them ? full : '$flag $full')
                          : (them ? '' : '$flag ') + full.substring(0, n),
                      style: them
                          ? const TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                              height: 1.35,
                              color: _ink,
                            )
                          : const TextStyle(
                              fontFamily: 'Manrope',
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              height: 1.35,
                              color: Color(0xFFBFE9D6),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "SU IDIOMA": los idiomas más viajeros a un toque (el elegido, primero).
class _LangChips extends StatelessWidget {
  const _LangChips({
    required this.selected,
    required this.mine,
    required this.name,
    required this.onPick,
  });

  final String selected;
  final String mine;
  final String Function(String) name;
  final void Function(String) onPick;

  static const List<String> _common = <String>[
    'en',
    'fr',
    'ja',
    'ar',
    'de',
    'it',
    'pt',
    'zh',
    'ko',
    'es',
  ];

  @override
  Widget build(BuildContext context) {
    final List<String> langs = <String>[
      selected,
      for (final String l in _common)
        if (l != selected && l != mine) l,
    ];
    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: <Widget>[
          const Center(
            child: Text(
              'SU IDIOMA',
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: 10.5,
                fontWeight: FontWeight.w800,
                color: Color(0xFF6F8490),
              ),
            ),
          ),
          for (final String l in langs) ...<Widget>[
            const SizedBox(width: 6),
            Semantics(
              selected: l == selected,
              button: true,
              child: GestureDetector(
                onTap: () => onPick(l),
                child: Container(
                  height: 30,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: l == selected ? _ink : Colors.transparent,
                    borderRadius: BorderRadius.circular(15),
                    border: l == selected
                        ? null
                        : Border.all(color: const Color(0xFF33444E)),
                  ),
                  child: Text(
                    '${languageFlags[l] ?? '🌐'} ${name(l)}',
                    style: TextStyle(
                      fontFamily: 'Manrope',
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: l == selected ? _bg : _ink,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// "Habla la otra persona" / "Hablo yo": el micro con sus ondas.
class _TalkButton extends StatelessWidget {
  const _TalkButton({
    required this.tooltip,
    required this.label,
    required this.hint,
    required this.on,
    required this.background,
    required this.foreground,
    required this.micBg,
    required this.waveColor,
    required this.wave,
    required this.onTap,
    required this.onLong,
  });

  final String tooltip;
  final String label;
  final String hint;
  final bool on;
  final Color background;
  final Color foreground;
  final Color micBg;
  final Color waveColor;
  final Animation<double> wave;
  final VoidCallback onTap;
  final VoidCallback onLong;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLong,
        child: AnimatedScale(
          scale: on ? 1.03 : 1,
          duration: const Duration(milliseconds: 200),
          child: AnimatedBuilder(
            animation: wave,
            builder: (BuildContext context, Widget? child) => Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(20),
                boxShadow: on
                    ? <BoxShadow>[
                        BoxShadow(
                          color: _accent.withValues(
                            alpha: 0.5 * (1 - wave.value),
                          ),
                          spreadRadius: 10 * wave.value,
                        ),
                      ]
                    : null,
              ),
              child: child,
            ),
            child: Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: micBg,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: _Waves(
                    animation: wave,
                    on: on,
                    color: waveColor,
                    height: 20,
                    width: 3,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                          color: foreground,
                        ),
                      ),
                      Text(
                        hint,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: 10.5,
                          color: foreground.withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// El marco blanco de rayas de "Pregunta" (apunta ahí).
class _DashedFrame extends CustomPainter {
  const _DashedFrame();

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final Path path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(24)),
      );
    for (final PathMetric m in path.computeMetrics()) {
      double d = 0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + 14, m.length)), p);
        d += 24;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedFrame old) => false;
}
