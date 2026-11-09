// El chat con Flyra: le preguntas lo que quieras (de tu viaje o de cualquier
// cosa) y te contesta la IA de ECLIPTA.
//
// Cómo funciona:
//   - Tus mensajes y los de Flyra se ven como "bocadillos" (como WhatsApp).
//   - Al enviar, la app manda los últimos mensajes al servidor (Flyra no
//     tiene memoria propia: el contexto se lo damos nosotros cada vez).
//   - La conversación se guarda SOLO en tu móvil. "Borrar" la elimina.
//   - Cada cuenta tiene preguntas gratis al día (así el servidor cuesta 0 €).
//     Debajo de la caja se ve cuántas te quedan.
//   - Animaciones ligeras: cada bocadillo nuevo entra deslizándose, Flyra
//     "piensa" con tres puntitos y su respuesta aparece como si la tecleara.
//     Con "reducir movimiento" del móvil activado, todo sale de golpe.
//   - Micro: dictas la pregunta en vez de escribirla (el reconocimiento de
//     voz del propio móvil, gratis). Altavoz: Flyra te lee su respuesta.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/content_language.dart';
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
enum _Problem { busy, outOfQuestions, network, off }

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

  /// Posición (en la lista) de la respuesta de Flyra que acaba de llegar:
  /// solo esa se "teclea". Las antiguas salen enteras.
  int? _typing;

  /// true mientras el micro está escuchando.
  bool _listening = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _turns ??= decodeHistory(_services.prefs.readFlyraChat());
  }

  @override
  void dispose() {
    unawaited(_services.speechInput.stop());
    unawaited(_services.speaker.stop());
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
    final String language = contentLanguage(context);
    try {
      final FlyraReply reply = await _services.flyra.ask(
        _history,
        language: language,
      );
      if (!mounted) return;
      setState(() {
        _turns = <ChatTurn>[..._history, ChatTurn(ChatRole.flyra, reply.text)];
        _typing = _history.length - 1;
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
          // 404: el servidor no tiene a Flyra encendida (p. ej. sin Ollama).
          ApiError.notFound => _Problem.off,
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

  /// La respuesta nueva ya se ve entera: baja hasta ella y no la vuelvas a
  /// "teclear" (por ejemplo al volver a dibujar la lista).
  void _typed() {
    _typing = null;
    _toBottom();
  }

  /// Dictar: escucha en el idioma de la app y deja lo oído en la caja (no
  /// lo envía solo, así puedes corregirlo antes).
  Future<void> _dictate() async {
    if (_listening) {
      await _services.speechInput.stop();
      return;
    }
    final String language = contentLanguage(context);
    setState(() => _listening = true);
    final String? heard = await _services.speechInput.listen(language);
    if (!mounted) return;
    setState(() {
      _listening = false;
      if (heard != null && heard.trim().isNotEmpty) {
        final String before = _input.text.trim();
        _input.text = before.isEmpty ? heard.trim() : '$before ${heard.trim()}';
      }
    });
  }

  /// Flyra lee en alto uno de sus mensajes, en el idioma de la app.
  void _listen(String text) {
    final String language = contentLanguage(context);
    unawaited(_services.speaker.speak(text, language));
  }

  Future<void> _clear() async {
    unawaited(_services.speaker.stop());
    setState(() {
      _typing = null;
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
                  for (int i = 0; i < turns.length; i++)
                    _Bubble(
                      // La clave hace que cada bocadillo sea "el mismo" al
                      // redibujar (y no repita su animación de entrada).
                      key: ValueKey<String>('turn-$i'),
                      turn: turns[i],
                      typing: i == _typing,
                      listenLabel: t.cameraListen,
                      onListen: () => _listen(turns[i].text),
                      onTyped: _typed,
                    ),
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
                    _Problem.off => t.errorFeatureOff,
                  },
                ),
              _Composer(
                controller: _input,
                hint: t.flyraInputHint,
                sendLabel: t.flyraSend,
                micLabel: t.assistantSpeak,
                listening: _listening,
                enabled: !_waiting && _remaining != 0,
                onSend: _send,
                onMic: _dictate,
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
///
/// Entra con un pequeño deslizamiento. Si [typing] es true (la respuesta que
/// acaba de llegar), el texto aparece letra a letra; tocarlo lo enseña entero.
class _Bubble extends StatefulWidget {
  const _Bubble({
    super.key,
    required this.turn,
    this.typing = false,
    this.listenLabel,
    this.onListen,
    this.onTyped,
  });

  final ChatTurn turn;
  final bool typing;

  /// Texto del botón de altavoz ("Escuchar"); sin él, no hay botón.
  final String? listenLabel;
  final VoidCallback? onListen;

  /// Se llama al acabar de "teclear" (para bajar hasta el final).
  final VoidCallback? onTyped;

  @override
  State<_Bubble> createState() => _BubbleState();
}

class _BubbleState extends State<_Bubble> with TickerProviderStateMixin {
  // Entrada: de transparente a visible, subiendo un poco. Dura poco (300 ms).
  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );

  // "Tecleo": de 0 letras a todas. Unos 18 ms por letra, como mucho 2,5 s
  // (una respuesta larga no te hace esperar).
  late final AnimationController _type = AnimationController(
    vsync: this,
    duration: Duration(
      milliseconds: (widget.turn.text.length * 18).clamp(200, 2500),
    ),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // "Reducir movimiento" en el móvil: sin animaciones, todo de golpe.
    final bool still = MediaQuery.disableAnimationsOf(context);
    if (_enter.status == AnimationStatus.dismissed) {
      if (still) {
        _enter.value = 1;
      } else {
        unawaited(_enter.forward());
      }
    }
    if (_type.status == AnimationStatus.dismissed) {
      if (still || !widget.typing) {
        _type.value = 1;
      } else {
        unawaited(_type.forward().then((_) => widget.onTyped?.call()));
      }
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _type.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool mine = widget.turn.role == ChatRole.user;
    final String text = widget.turn.text;
    final Widget bubble = Flexible(
      child: GestureDetector(
        // Tocar mientras teclea: sale entero ya.
        onTap: _type.isAnimating ? () => _type.value = 1 : null,
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
          child: AnimatedBuilder(
            animation: _type,
            builder: (BuildContext context, Widget? _) {
              final int shown = (text.length * _type.value).round();
              // Se puede seleccionar y copiar (una dirección, una frase...).
              return SelectableText(
                shown >= text.length ? text : text.substring(0, shown),
                // El lector de pantalla lee siempre el texto completo.
                semanticsLabel: text,
                style: TextStyle(
                  color: mine
                      ? NomadColors.background
                      : const Color(0xFFDCD3F7),
                  height: 1.4,
                ),
              );
            },
          ),
        ),
      ),
    );
    final String? listenLabel = widget.listenLabel;
    return FadeTransition(
      opacity: _enter,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.25),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic)),
        child: Padding(
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
              if (!mine && listenLabel != null)
                IconButton(
                  tooltip: listenLabel,
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onListen,
                  icon: const Icon(
                    Icons.volume_up_rounded,
                    size: 20,
                    color: NomadColors.textMuted,
                  ),
                ),
              if (mine) const SizedBox(width: 36),
            ],
          ),
        ),
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

/// "Flyra está pensando": su foto y tres puntitos que saltan uno tras otro.
class _Thinking extends StatefulWidget {
  const _Thinking({required this.label});

  final String label;

  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dots = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Se repite un número fijo de veces (unos 40 s), no para siempre: así
    // nunca se queda gastando batería si algo se cuelga.
    if (!MediaQuery.disableAnimationsOf(context) && !_dots.isAnimating) {
      unawaited(_dots.repeat(count: 45));
    }
  }

  @override
  void dispose() {
    _dots.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: <Widget>[
        const FlyraAvatar(size: 28),
        const SizedBox(width: 10),
        AnimatedBuilder(
          animation: _dots,
          builder: (BuildContext context, Widget? _) => Row(
            children: <Widget>[
              for (int i = 0; i < 3; i++)
                Transform.translate(
                  // Cada puntito salta con un poco de retraso sobre el
                  // anterior (la "ola" de los chats).
                  offset: Offset(0, -5 * _hop(_dots.value - i * 0.18)),
                  child: Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: const BoxDecoration(
                      color: NomadColors.mint,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        // liveRegion: el lector de pantalla anuncia "Flyra está pensando".
        Semantics(
          liveRegion: true,
          child: Text(
            widget.label,
            style: const TextStyle(color: NomadColors.textMuted),
          ),
        ),
      ],
    ),
  );

  /// Altura del salto (0 = en el suelo, 1 = arriba) en el punto [t] de la
  /// vuelta: sube y baja en la primera mitad y descansa en la segunda.
  static double _hop(double t) {
    final double x = t % 1;
    if (x > 0.5) return 0;
    final double half = x * 2; // 0..1 dentro del salto
    return 1 - (2 * half - 1) * (2 * half - 1);
  }
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
    required this.micLabel,
    required this.listening,
    required this.enabled,
    required this.onSend,
    required this.onMic,
  });

  final TextEditingController controller;
  final String hint;
  final String sendLabel;
  final String micLabel;
  final bool listening;
  final bool enabled;
  final Future<void> Function([String?]) onSend;
  final VoidCallback onMic;

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
        const SizedBox(width: 4),
        // El micro: mientras escucha se pone del color de Flyra.
        IconButton(
          tooltip: micLabel,
          isSelected: listening,
          onPressed: enabled ? onMic : null,
          icon: const Icon(Icons.mic_none_rounded),
          selectedIcon: const Icon(Icons.mic_rounded, color: NomadColors.mint),
        ),
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
