// Habla con Flyra (maqueta "Voz"): tocas el micro, preguntas en voz alta y
// Flyra te contesta (también en voz alta) con un botón para hacerlo.
//
// ¿Cómo entiende lo que dices sin gastar dinero?
//   1. El reconocimiento de voz es el del propio móvil (gratis, y si tienes
//      el idioma descargado funciona sin internet).
//   2. Las preguntas típicas ("¿a qué hora sale mi avión?", "llévame al
//      hotel"...) se reconocen con palabras clave EN el móvil (ver
//      voice_intents.dart): respuesta al instante, sin servidor.
//   3. Lo que no reconoce se lo pasa al chat de Flyra (que sí usa el
//      servidor, con su tope diario). Así el servidor solo trabaja cuando
//      de verdad hace falta.
//
// Lo de "reserva cena para dos" de la maqueta NO está: no hay ninguna forma
// gratis y fiable de reservar restaurantes en todo el mundo. Esa pregunta
// cae en el chat de Flyra, que te dice cómo hacerlo.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_home_screen.dart' show EasyTripSheet;
import '../easy/easy_mode.dart';
import 'voice_answer.dart';

class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> {
  late final AppServices _services = ServicesScope.of(context);
  final TextEditingController _typed = TextEditingController();

  bool _listening = false;
  String? _heard;
  VoiceAnswer? _answer;

  @override
  void dispose() {
    unawaited(_services.speechInput.stop());
    unawaited(_services.speaker.stop());
    _typed.dispose();
    super.dispose();
  }

  String get _lang => Localizations.localeOf(context).languageCode;

  Future<void> _listen() async {
    if (_listening) {
      await _services.speechInput.stop();
      return;
    }
    await _services.speaker.stop();
    setState(() => (_listening = true, _answer = null));
    final String? text = await _services.speechInput.listen(_lang);
    if (!mounted) return;
    setState(() => _listening = false);
    if (text == null || text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).voiceNotHeard)),
        );
      return;
    }
    await _ask(text.trim());
  }

  /// Contesta a [text] (dicho o escrito) y lo lee en alto.
  Future<void> _ask(String text) async {
    final VoiceAnswer answer = _answerFor(text, AppLocalizations.of(context));
    setState(() => (_heard = text, _answer = answer));
    // Leerlo en alto es un extra: si el móvil no tiene voz, se queda escrito.
    try {
      await _services.speaker.speak(answer.text, _lang);
    } on Exception {
      // Sin voz instalada: no pasa nada.
    }
  }

  VoiceAnswer _answerFor(String text, AppLocalizations t) => voiceAnswer(
    text,
    t: t,
    lang: _lang,
    trip: loadEasyTrip(_services.prefs),
    go: (String route) => unawaited(context.push(route)),
    editTrip: _editTrip,
    openLink: _services.openLink,
  );

  Future<void> _editTrip() async {
    final EasyTrip? trip = await showModalBottomSheet<EasyTrip>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => EasyTripSheet(trip: loadEasyTrip(_services.prefs)),
    );
    if (trip == null) return;
    await saveEasyTrip(_services.prefs, trip);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final VoiceAnswer? answer = _answer;
    final List<String> examples = <String>[
      t.voiceExFlight,
      t.voiceExMoney,
      t.voiceExHotel,
      t.voiceExVisa,
      t.voiceExLanguage,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(t.voiceTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
        children: <Widget>[
          Text(t.voiceSubtitle, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 28),
          Center(
            child: Semantics(
              button: true,
              label: _listening ? t.voiceListening : t.voiceTapToAsk,
              child: GestureDetector(
                onTap: () => unawaited(_listen()),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: _listening ? 132 : 116,
                  height: _listening ? 132 : 116,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: NomadColors.group,
                    boxShadow: <BoxShadow>[
                      BoxShadow(
                        color: NomadColors.group.withValues(alpha: 0.4),
                        blurRadius: _listening ? 36 : 16,
                      ),
                    ],
                  ),
                  child: Icon(
                    _listening ? Icons.graphic_eq_rounded : Icons.mic_rounded,
                    size: 52,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _listening ? t.voiceListening : t.voiceTapToAsk,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 24),
          if (_heard != null) ...<Widget>[
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text('“$_heard”'),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (answer != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Icon(
                          Icons.auto_awesome_rounded,
                          color: NomadColors.group,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            answer.text,
                            style: theme.textTheme.bodyLarge,
                          ),
                        ),
                      ],
                    ),
                    if (answer.action != null) ...<Widget>[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: answer.onAction,
                        icon: Icon(answer.icon),
                        label: Text(answer.action!),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: 20),
          // Sin micro (o en un sitio donde no puedes hablar): se escribe.
          TextField(
            controller: _typed,
            textInputAction: TextInputAction.send,
            decoration: InputDecoration(
              hintText: t.voiceTypeHint,
              prefixIcon: const Icon(Icons.keyboard_rounded),
            ),
            onSubmitted: (String v) {
              if (v.trim().isEmpty) return;
              _typed.clear();
              unawaited(_ask(v.trim()));
            },
          ),
          const SizedBox(height: 20),
          Text(t.voiceTryAsking, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String e in examples)
                ActionChip(label: Text(e), onPressed: () => unawaited(_ask(e))),
            ],
          ),
        ],
      ),
    );
  }
}
