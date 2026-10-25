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
import 'package:intl/intl.dart';

import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../easy/easy_home_screen.dart' show EasyTripSheet;
import '../easy/easy_mode.dart';
import 'voice_intents.dart';

/// Lo que contesta Flyra: el texto (que también lee en alto) y, si toca,
/// un botón para hacerlo.
class _Answer {
  const _Answer(this.text, {this.action, this.onAction, this.icon});

  final String text;
  final String? action;
  final VoidCallback? onAction;
  final IconData? icon;
}

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
  _Answer? _answer;

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
    final _Answer answer = _answerFor(text, AppLocalizations.of(context));
    setState(() => (_heard = text, _answer = answer));
    // Leerlo en alto es un extra: si el móvil no tiene voz, se queda escrito.
    try {
      await _services.speaker.speak(answer.text, _lang);
    } on Exception {
      // Sin voz instalada: no pasa nada.
    }
  }

  _Answer _answerFor(String text, AppLocalizations t) {
    final VoiceIntent? intent = matchIntent(text, _lang);
    final EasyTrip trip = loadEasyTrip(_services.prefs);
    void go(String route) => unawaited(context.push(route));
    switch (intent) {
      case VoiceIntent.flight:
        final DateTime? dep = trip.departure;
        if (!trip.hasFlight || dep == null) {
          return _Answer(
            t.voiceNoFlight,
            action: t.voiceAddTrip,
            icon: Icons.edit_calendar_rounded,
            onAction: () => unawaited(_editTrip()),
          );
        }
        final String date = DateFormat.MMMMEEEEd(_lang).format(dep);
        final String time = DateFormat.Hm(_lang).format(dep);
        final String? gate = trip.gate;
        final String base = t.voiceFlightAt(trip.from!, trip.to!, date, time);
        return _Answer(
          gate == null || gate.isEmpty ? base : '$base ${t.voiceGate(gate)}',
          action: t.airportTitle,
          icon: Icons.local_airport_rounded,
          onAction: () => go(Routes.airport(iata: trip.from, gate: gate)),
        );
      case VoiceIntent.hotel:
        final String? address = trip.hotelAddress;
        if (address == null) {
          return _Answer(
            t.voiceNoHotel,
            action: t.voiceAddTrip,
            icon: Icons.edit_calendar_rounded,
            onAction: () => unawaited(_editTrip()),
          );
        }
        return _Answer(
          t.voiceHotel(trip.hotelName ?? address),
          action: t.voiceTakeMe,
          icon: Icons.directions_rounded,
          onAction: () => unawaited(_services.openLink(directionsTo(address))),
        );
      case VoiceIntent.money:
        return _Answer(
          t.voiceMoney,
          action: t.voiceOpen,
          icon: Icons.receipt_long_rounded,
          onAction: () => go(Routes.money()),
        );
      case VoiceIntent.visa:
        return _Answer(
          t.voiceVisa,
          action: t.visaTitle,
          icon: Icons.verified_user_rounded,
          onAction: () => go(Routes.visa()),
        );
      case VoiceIntent.language:
        return _Answer(
          t.voiceLanguage,
          action: t.voiceOpen,
          icon: Icons.translate_rounded,
          onAction: () => go(Routes.language),
        );
      case VoiceIntent.sos:
        return _Answer(
          t.voiceSos,
          action: 'SOS',
          icon: Icons.emergency_rounded,
          onAction: () => go(Routes.sos),
        );
      case VoiceIntent.nearby:
        return _Answer(
          t.voiceNearby,
          action: t.voiceOpen,
          icon: Icons.near_me_rounded,
          onAction: () => go(Routes.nearby),
        );
      case VoiceIntent.translate:
        return _Answer(
          t.voiceTranslate,
          action: t.voiceOpen,
          icon: Icons.record_voice_over_rounded,
          onAction: () => go(Routes.assistant),
        );
      case VoiceIntent.meetups:
        return _Answer(
          t.voiceMeetups,
          action: t.voiceOpen,
          icon: Icons.diversity_3_rounded,
          onAction: () => go(Routes.meetups()),
        );
      case VoiceIntent.drive:
        return _Answer(
          t.voiceDrive,
          action: t.voiceOpen,
          icon: Icons.directions_car_rounded,
          onAction: () => go(Routes.drive),
        );
      case VoiceIntent.trouble:
        return _Answer(
          t.voiceTrouble,
          action: t.voiceOpen,
          icon: Icons.report_problem_rounded,
          onAction: () => go(Routes.trouble),
        );
      case null:
        return _Answer(
          t.voiceUnknown,
          action: t.voiceAskFlyra,
          icon: Icons.auto_awesome_rounded,
          onAction: () => go(Routes.flyra(question: text)),
        );
    }
  }

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
    final _Answer? answer = _answer;
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
