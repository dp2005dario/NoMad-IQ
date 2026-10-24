// El chat con Flyra: le preguntas lo que quieras (de tu viaje o de cualquier
// cosa) y te contesta la IA de NomadIQ.
//
// Cómo funciona:
//   - Tus mensajes y los de Flyra se ven como "bocadillos" (como WhatsApp).
//   - Al enviar, la app manda los últimos mensajes al servidor (Flyra no
//     tiene memoria propia: el contexto se lo damos nosotros cada vez).
//   - La conversación se guarda SOLO en tu móvil. "Borrar" la elimina.
//   - Cada cuenta tiene preguntas gratis al día (así el servidor cuesta 0 €).
//     Debajo de la caja se ve cuántas te quedan.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import 'flyra_api.dart';

class FlyraChatScreen extends StatefulWidget {
  const FlyraChatScreen({super.key, this.draft});

  /// Una pregunta para dejar ya escrita en la caja (desde otra pantalla).
  final String? draft;

  @override
  State<FlyraChatScreen> createState() => _FlyraChatScreenState();
}

/// Qué aviso enseñar debajo del chat cuando algo no sale bien.
enum _Problem { busy, outOfQuestions, network }

class _FlyraChatScreenState extends State<FlyraChatScreen> {
  late final AppServices _services = ServicesScope.of(context);
  late final TextEditingController _input = TextEditingController(
    text: widget.draft,
  );
  final ScrollController _scroll = ScrollController();
  List<ChatTurn>? _turns;
  bool _waiting = false;
  int? _remaining;
  _Problem? _problem;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _turns ??= decodeHistory(_services.prefs.readFlyraChat());
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  List<ChatTurn> get _history => _turns ?? <ChatTurn>[];

  Future<void> _save() => _services.prefs.writeFlyraChat(
    _history.isEmpty ? null : encodeHistory(_history),
  );

  /// Baja hasta el último mensaje (después de dibujarlo).
  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  Future<void> _send([String? text]) async {
    final String question = (text ?? _input.text).trim();
    if (question.isEmpty || _waiting) return;
    final String clipped = question.length > maxQuestionChars
        ? question.substring(0, maxQuestionChars)
        : question;
    setState(() {
      _turns = <ChatTurn>[..._history, ChatTurn(ChatRole.user, clipped)];
      _waiting = true;
      _problem = null;
      _input.clear();
    });
    _toBottom();
    final String language = Localizations.localeOf(context).languageCode;
    try {
      final FlyraReply reply = await _services.flyra.ask(
        _history,
        language: language,
      );
      if (!mounted) return;
      setState(() {
        _turns = <ChatTurn>[..._history, ChatTurn(ChatRole.flyra, reply.text)];
        _remaining = reply.remainingToday;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // La pregunta no se contestó: vuelve a la caja para reenviarla.
      setState(() {
        _turns = _history.sublist(0, _history.length - 1);
        _input.text = clipped;
        _problem = switch (e.error) {
          ApiError.rateLimited => _Problem.outOfQuestions,
          ApiError.network => _Problem.network,
          _ => _Problem.busy,
        };
        if (e.error == ApiError.rateLimited) _remaining = 0;
      });
    } finally {
      if (mounted) setState(() => _waiting = false);
    }
    await _save();
    _toBottom();
  }

  Future<void> _clear() async {
    setState(() {
      _turns = <ChatTurn>[];
      _problem = null;
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool guest =
        SessionScope.of(context).status != SessionStatus.signedIn;
    final List<ChatTurn> turns = _history;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: <Widget>[
            const FlyraAvatar(size: 36),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('Flyra'),
                  Text(
                    t.flyraSubtitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: NomadColors.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: <Widget>[
          if (turns.isNotEmpty)
            IconButton(
              tooltip: t.flyraClear,
              onPressed: _waiting ? null : _clear,
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                children: <Widget>[
                  _Bubble(turn: ChatTurn(ChatRole.flyra, t.flyraWelcome)),
                  if (turns.isEmpty && !guest)
                    _Suggestions(
                      items: <String>[
                        t.flyraSuggestion1,
                        t.flyraSuggestion2,
                        t.flyraSuggestion3,
                        t.flyraSuggestion4,
                      ],
                      onPick: _send,
                    ),
                  for (final ChatTurn turn in turns) _Bubble(turn: turn),
                  if (_waiting) _Thinking(label: t.flyraThinking),
                ],
              ),
            ),
            if (guest)
              _SignIn(text: t.flyraSignIn, button: t.signInFromGuest)
            else ...<Widget>[
              if (_problem case final _Problem p)
                _Notice(
                  text: switch (p) {
                    _Problem.busy => t.flyraBusy,
                    _Problem.outOfQuestions => t.flyraOutOfQuestions,
                    _Problem.network => t.errorNetwork,
                  },
                ),
              _Composer(
                controller: _input,
                hint: t.flyraInputHint,
                sendLabel: t.flyraSend,
                enabled: !_waiting && _remaining != 0,
                onSend: _send,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _remaining == null
                      ? t.flyraDisclaimer
                      : '${t.flyraRemaining(_remaining!)} · ${t.flyraDisclaimer}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 12,
                    color: NomadColors.textMuted,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Un bocadillo: los de Flyra a un lado (con su foto), los tuyos al otro.
/// "start"/"end" en vez de izquierda/derecha: en árabe se da la vuelta solo.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.turn});

  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final bool mine = turn.role == ChatRole.user;
    final Widget bubble = Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? NomadColors.mint : const Color(0xFF1A1530),
          borderRadius: BorderRadiusDirectional.only(
            topStart: const Radius.circular(18),
            topEnd: const Radius.circular(18),
            bottomStart: Radius.circular(mine ? 18 : 4),
            bottomEnd: Radius.circular(mine ? 4 : 18),
          ).resolve(Directionality.of(context)),
          border: mine ? null : Border.all(color: const Color(0xFF3E3163)),
        ),
        // Se puede seleccionar y copiar (una dirección, una frase útil...).
        child: SelectableText(
          turn.text,
          style: TextStyle(
            color: mine ? NomadColors.background : const Color(0xFFDCD3F7),
            height: 1.4,
          ),
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          if (!mine) ...<Widget>[
            const FlyraAvatar(size: 28),
            const SizedBox(width: 8),
          ],
          bubble,
          if (mine) const SizedBox(width: 36),
        ],
      ),
    );
  }
}

/// Ideas para la primera pregunta (se envían al tocarlas).
class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.items, required this.onPick});

  final List<String> items;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsetsDirectional.only(start: 36, bottom: 12),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        for (final String item in items)
          ActionChip(label: Text(item), onPressed: () => onPick(item)),
      ],
    ),
  );
}

class _Thinking extends StatelessWidget {
  const _Thinking({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: <Widget>[
        const FlyraAvatar(size: 28),
        const SizedBox(width: 10),
        const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        // liveRegion: el lector de pantalla anuncia "Flyra está pensando".
        Semantics(
          liveRegion: true,
          child: Text(
            label,
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        ),
      ],
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: NomadColors.surfaceHigh,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: NomadColors.safety),
      ),
      child: Text(text),
    ),
  );
}

/// La caja de escribir y el botón de enviar.
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.hint,
    required this.sendLabel,
    required this.enabled,
    required this.onSend,
  });

  final TextEditingController controller;
  final String hint;
  final String sendLabel;
  final bool enabled;
  final Future<void> Function([String?]) onSend;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            minLines: 1,
            maxLines: 5,
            maxLength: maxQuestionChars,
            // Sin el contador "0/2000" debajo: solo estorba.
            buildCounter: (
              BuildContext context, {
              required int currentLength,
              required bool isFocused,
              required int? maxLength,
            }) => null,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => onSend(),
            decoration: InputDecoration(
              hintText: hint,
              filled: true,
              fillColor: NomadColors.surfaceHigh,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 12,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: sendLabel,
          onPressed: enabled ? () => onSend() : null,
          // En árabe la flecha apunta al otro lado (la app se da la vuelta).
          icon: const Icon(Icons.send_rounded),
        ),
      ],
    ),
  );
}

class _SignIn extends StatelessWidget {
  const _SignIn({required this.text, required this.button});

  final String text;
  final String button;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    child: Column(
      children: <Widget>[
        Text(text, textAlign: TextAlign.center),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: () => context.push(Routes.signIn),
          child: Text(button),
        ),
      ],
    ),
  );
}
