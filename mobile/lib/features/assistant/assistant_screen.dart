// Asistente (maqueta "Asistente"), con dos pestañas:
//
//   - Conversación: un intérprete cara a cara. Pones el móvil en la mesa:
//     la mitad de arriba está girada para la otra persona, en su idioma; la
//     de abajo es la tuya. Cada uno pulsa su micrófono y habla; el móvil lo
//     traduce y lo lee en alto. Todo dentro del móvil (ver interpreter.dart):
//     con los dos idiomas descargados, funciona en modo avión.
//   - Pregunta: "¿qué es esto?". Apunta con la cámara (el modo cámara
//     reconoce el monumento) o pregúntale a Flyra.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import 'interpreter.dart';

enum _Tab { talk, ask }

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

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
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

  /// null = nadie habla; true = yo; false = la otra persona.
  bool? _listening;
  bool _busy = false;
  bool _voice = true;

  /// Faltan modelos por descargar (null = aún no se sabe).
  List<String>? _missing;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  @override
  void dispose() {
    unawaited(_services.speechInput.stop());
    unawaited(_services.speaker.stop());
    super.dispose();
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

  Future<void> _pickTheirs() async {
    final String? code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            for (final MapEntry<String, String> e
                in interpreterLanguages.entries)
              if (e.key != _mine)
                ListTile(
                  title: Text(e.value),
                  selected: e.key == _theirs,
                  onTap: () => Navigator.of(context).pop(e.key),
                ),
          ],
        ),
      ),
    );
    if (code == null || !mounted) return;
    setState(() => (_theirs = code, _missing = null));
    await _services.prefs.writeData(LocalData.interpreterLang, code);
    await _check();
  }

  /// Traduce y lo añade a la conversación (y lo lee en alto).
  Future<void> _say(String text, {required bool mine}) async {
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
      setState(
        () => _lines.add(
          _Line(mine: mine, original: text, translated: translated),
        ),
      );
      if (_voice) unawaited(_services.speaker.speak(translated, to));
    } on TranslationUnavailable {
      if (mounted) _snack(AppLocalizations.of(context).assistantNeedModels);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _listen({required bool mine}) async {
    if (_listening != null) {
      await _services.speechInput.stop();
      return;
    }
    setState(() => _listening = mine);
    final String? heard = await _services.speechInput.listen(
      mine ? _mine : _theirs,
    );
    if (!mounted) return;
    setState(() => _listening = null);
    if (heard == null) {
      _snack(AppLocalizations.of(context).assistantDidntHear);
      return;
    }
    await _say(heard, mine: mine);
  }

  /// Escribir en vez de hablar (con ruido, o si el micro no va).
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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.assistantTitle),
        actions: <Widget>[
          IconButton(
            tooltip: _voice ? t.driveVoiceOff : t.driveVoiceOn,
            icon: Icon(
              _voice ? Icons.volume_up_rounded : Icons.volume_off_rounded,
            ),
            onPressed: () => setState(() => _voice = !_voice),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SegmentedButton<_Tab>(
              segments: <ButtonSegment<_Tab>>[
                ButtonSegment<_Tab>(
                  value: _Tab.talk,
                  label: Text(t.assistantTalk),
                  icon: const Icon(Icons.record_voice_over_rounded),
                ),
                ButtonSegment<_Tab>(
                  value: _Tab.ask,
                  label: Text(t.assistantAsk),
                  icon: const Icon(Icons.help_rounded),
                ),
              ],
              selected: <_Tab>{_tab},
              onSelectionChanged: (Set<_Tab> s) =>
                  setState(() => _tab = s.first),
            ),
          ),
          Expanded(
            child: switch (_tab) {
              _Tab.talk => _talk(t),
              _Tab.ask => _ask(t),
            },
          ),
        ],
      ),
    );
  }

  Widget _talk(AppLocalizations t) {
    final List<String>? missing = _missing;
    return Column(
      children: <Widget>[
        // La mitad de la otra persona, girada para que la lea de frente.
        Expanded(
          child: RotatedBox(
            quarterTurns: 2,
            child: _Half(
              language: _theirs,
              lines: <(bool, String)>[
                for (final _Line l in _lines)
                  (!l.mine, l.mine ? l.translated : l.original),
              ],
              color: NomadColors.group,
              listening: _listening == false,
              busy: _busy,
              micTooltip: interpreterLanguages[_theirs] ?? _theirs,
              onMic: () => _listen(mine: false),
              onType: () => _type(mine: false),
              typeTooltip: t.assistantType,
            ),
          ),
        ),
        Material(
          color: NomadColors.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${interpreterLanguages[_mine]} ⇄ ${interpreterLanguages[_theirs]}',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton(
                  onPressed: _pickTheirs,
                  child: Text(t.assistantTheirLanguage),
                ),
              ],
            ),
          ),
        ),
        if (missing != null && missing.isNotEmpty)
          Material(
            color: NomadColors.money.withValues(alpha: 0.15),
            child: ListTile(
              dense: true,
              leading: const Icon(Icons.download_rounded),
              title: Text(
                t.assistantDownload(
                  missing.map((String l) => interpreterLanguages[l]).join(', '),
                ),
              ),
              trailing: _downloading
                  ? const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton.outlined(
                      tooltip: t.assistantDownloadButton,
                      icon: const Icon(Icons.download_rounded),
                      onPressed: _download,
                    ),
            ),
          ),
        Expanded(
          child: _Half(
            language: _mine,
            lines: <(bool, String)>[
              for (final _Line l in _lines)
                (l.mine, l.mine ? l.original : l.translated),
            ],
            color: NomadColors.mint,
            listening: _listening == true,
            busy: _busy,
            micTooltip: t.assistantSpeak,
            onMic: () => _listen(mine: true),
            onType: () => _type(mine: true),
            typeTooltip: t.assistantType,
            hint: t.assistantHint,
          ),
        ),
      ],
    );
  }

  Widget _ask(AppLocalizations t) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<String> chips = <String>[
      t.assistantChipInside,
      t.assistantChipPhoto,
      t.assistantChipMore,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: <Widget>[
        Text(t.assistantAskTitle, style: text.titleLarge),
        const SizedBox(height: 8),
        Text(t.assistantAskBody, style: text.bodyMedium),
        const SizedBox(height: 16),
        FilledButton.icon(
          icon: const Icon(Icons.photo_camera_rounded),
          label: Text(t.assistantPointCamera),
          onPressed: () => unawaited(context.push(Routes.camera)),
        ),
        const SizedBox(height: 16),
        Text(t.assistantAskFlyra, style: text.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final String c in chips)
              ActionChip(
                avatar: const Icon(Icons.auto_awesome_rounded, size: 18),
                label: Text(c),
                onPressed: () =>
                    unawaited(context.push(Routes.flyra(question: c))),
              ),
          ],
        ),
      ],
    );
  }
}

/// Media pantalla: las frases en un idioma y su micrófono.
class _Half extends StatelessWidget {
  const _Half({
    required this.language,
    required this.lines,
    required this.color,
    required this.listening,
    required this.busy,
    required this.micTooltip,
    required this.onMic,
    required this.onType,
    required this.typeTooltip,
    this.hint,
  });

  final String language;

  /// (es de esta persona, texto).
  final List<(bool, String)> lines;
  final Color color;
  final bool listening;
  final bool busy;
  final String micTooltip;
  final VoidCallback onMic;
  final VoidCallback onType;
  final String typeTooltip;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final TextDirection dir = rtlLanguages.contains(language)
        ? TextDirection.rtl
        : TextDirection.ltr;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        children: <Widget>[
          Expanded(
            child: lines.isEmpty
                ? Center(
                    child: Text(
                      hint ?? '',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: NomadColors.textMuted),
                    ),
                  )
                : ListView(
                    reverse: true,
                    children: <Widget>[
                      for (final (bool own, String text) in lines.reversed)
                        Align(
                          alignment: own
                              ? AlignmentDirectional.centerEnd
                              : AlignmentDirectional.centerStart,
                          child: Container(
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            constraints: const BoxConstraints(maxWidth: 320),
                            decoration: BoxDecoration(
                              color: own ? color : NomadColors.surface,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Text(
                              text,
                              textDirection: dir,
                              style: TextStyle(
                                fontSize: 18,
                                color: own ? NomadColors.background : null,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              IconButton.outlined(
                tooltip: typeTooltip,
                icon: const Icon(Icons.keyboard_rounded),
                onPressed: busy ? null : onType,
              ),
              const SizedBox(width: 16),
              SizedBox.square(
                dimension: 64,
                child: IconButton.filled(
                  tooltip: micTooltip,
                  style: IconButton.styleFrom(backgroundColor: color),
                  icon: Icon(
                    listening ? Icons.stop_rounded : Icons.mic_rounded,
                    size: 32,
                    color: NomadColors.background,
                  ),
                  onPressed: busy ? null : onMic,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
