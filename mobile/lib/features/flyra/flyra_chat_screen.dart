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
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../auth/session.dart';
import '../../core/api_client.dart';
import '../../core/content_language.dart';
import '../../core/motion.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../../widgets/user_avatar.dart';
import '../home/home_screen.dart' show displayName;
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

  /// La ficha de Flyra (como en la maqueta): su foto grande, qué sabe
  /// hacer y el aviso de que puede equivocarse.
  Future<void> _about() => showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) {
      final AppLocalizations t = AppLocalizations.of(context);
      return _AboutFlyra(t: t);
    },
  );

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final bool guest =
        SessionScope.of(context).status != SessionStatus.signedIn;
    final String? name = displayName(SessionScope.of(context).user?.email);
    final String initial = name == null || name.isEmpty
        ? ''
        : String.fromCharCodes(name.runes.take(1)).toUpperCase();
    final String? photo = SessionScope.of(context).user?.photoUrl;
    final List<ChatTurn> turns = _history;
    final List<String> ideas = <String>[
      t.flyraSuggestion1,
      t.flyraSuggestion2,
      t.flyraSuggestion3,
      t.flyraSuggestion4,
    ];
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        // Sin flecha de volver (pestaña): un poco de aire a la izquierda.
        titleSpacing: Navigator.of(context).canPop() ? 0 : 16,
        title: Semantics(
          button: true,
          label: t.flyraAbout,
          child: InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: _about,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  const _GlowAvatar(size: 40),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Flyra',
                          style: TextStyle(
                            fontFamily: NomadFonts.display,
                            fontWeight: FontWeight.w800,
                            fontSize: 20,
                          ),
                        ),
                        Row(
                          children: <Widget>[
                            Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(
                                color: NomadColors.mint,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: Text(
                                _waiting
                                    ? t.flyraThinking
                                    : '${t.flyraOnlineNow} · ${t.flyraSubtitle}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: NomadColors.textMuted,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: <Widget>[
          IconButton(
            tooltip: t.flyraAbout,
            onPressed: _about,
            icon: const Icon(Icons.info_outline_rounded),
          ),
          if (turns.isNotEmpty)
            IconButton(
              tooltip: t.flyraClear,
              onPressed: _waiting ? null : _clear,
              icon: const Icon(Icons.delete_sweep_rounded),
            ),
        ],
      ),
      body: _Aurora(
        child: SafeArea(
          child: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: <Widget>[
                    if (turns.isEmpty)
                      _Hero(t: t)
                    else
                      _DayPill(label: t.flyraToday),
                    _Bubble(turn: ChatTurn(ChatRole.flyra, t.flyraWelcome)),
                    if (turns.isEmpty && !guest)
                      _Suggestions(
                        title: t.flyraIdeas,
                        items: ideas,
                        onPick: _send,
                      ),
                    for (int i = 0; i < turns.length; i++)
                      _Bubble(
                        // La clave hace que cada bocadillo sea "el mismo" al
                        // redibujar (y no repita su animación de entrada).
                        key: ValueKey<String>('turn-$i'),
                        turn: turns[i],
                        initial: initial,
                        name: name,
                        photoUrl: photo,
                        typing: i == _typing,
                        listenLabel: t.cameraListen,
                        copyLabel: t.visaCopy,
                        copiedLabel: t.settleCopied,
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
                // Con conversación: ideas rápidas encima de la caja (como los
                // "@Flyra ¿dónde cenamos?" de la maqueta).
                if (turns.isNotEmpty && !_waiting && _remaining != 0)
                  _QuickIdeas(items: ideas, onPick: _send),
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
                      fontSize: 11.5,
                      color: NomadColors.textMuted,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// La foto de Flyra con un halo que respira (menta → violeta).
class _GlowAvatar extends StatelessWidget {
  const _GlowAvatar({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: NomadColors.mint.withValues(alpha: 0.35),
          blurRadius: size * 0.45,
        ),
        BoxShadow(
          color: NomadColors.group.withValues(alpha: 0.18),
          blurRadius: size * 0.8,
          spreadRadius: size * 0.02,
        ),
      ],
    ),
    child: FlyraAvatar(size: size),
  );
}

/// La portada del chat vacío: Flyra grande y lo que sabe hacer.
class _Hero extends StatelessWidget {
  const _Hero({required this.t});

  final AppLocalizations t;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 700),
    curve: Curves.easeOutBack,
    builder: (BuildContext context, double v, Widget? child) => Opacity(
      opacity: v.clamp(0, 1),
      child: Transform.scale(scale: 0.85 + 0.15 * v, child: child),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 16),
      child: Column(
        children: <Widget>[
          const _GlowAvatar(size: 76),
          const SizedBox(height: 10),
          const Text(
            'Flyra',
            style: TextStyle(
              fontFamily: NomadFonts.display,
              fontWeight: FontWeight.w800,
              fontSize: 30,
              color: NomadColors.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            t.flyraSubtitle,
            style: const TextStyle(color: NomadColors.textMuted),
          ),
          const SizedBox(height: 14),
          _Traits(t: t),
        ],
      ),
    ),
  );
}

/// Las tres "insignias" de Flyra (idioma, privacidad, gratis).
class _Traits extends StatelessWidget {
  const _Traits({required this.t});

  final AppLocalizations t;

  @override
  Widget build(BuildContext context) {
    Widget chip(String text, Color color, IconData icon) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        chip(t.flyraTraitLanguage, NomadColors.mint, Icons.translate_rounded),
        chip(t.flyraTraitPrivate, NomadColors.flights, Icons.lock_rounded),
        chip(t.flyraTraitFree, NomadColors.group, Icons.bolt_rounded),
      ],
    );
  }
}

/// La ficha de Flyra (se abre tocando su nombre).
class _AboutFlyra extends StatelessWidget {
  const _AboutFlyra({required this.t});

  final AppLocalizations t;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(10),
    padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: NomadColors.outline),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[Color(0xFF221A4A), NomadColors.surface],
      ),
    ),
    child: SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _GlowAvatar(size: 120),
            const SizedBox(height: 16),
            const Text(
              'Flyra',
              style: TextStyle(
                fontFamily: NomadFonts.display,
                fontWeight: FontWeight.w800,
                fontSize: 32,
                color: NomadColors.text,
              ),
            ),
            Text(
              t.flyraSubtitle,
              style: const TextStyle(color: NomadColors.textMuted),
            ),
            const SizedBox(height: 16),
            _Traits(t: t),
            const SizedBox(height: 16),
            Text(
              t.flyraDisclaimer,
              textAlign: TextAlign.center,
              style: const TextStyle(color: NomadColors.textMuted, height: 1.4),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF7B61FF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  t.flyraBackToChat,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// "Hoy", en una pastilla en medio (como "Día 3 · jueves" en la maqueta).
class _DayPill extends StatelessWidget {
  const _DayPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: Container(
      margin: const EdgeInsets.only(bottom: 12, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: NomadColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: NomadColors.textMuted,
        ),
      ),
    ),
  );
}

/// Un bocadillo: los de Flyra a un lado (con su foto y su nombre en menta),
/// los tuyos al otro (con tu inicial). "start"/"end" en vez de
/// izquierda/derecha: en árabe se da la vuelta solo.
///
/// Entra con un pequeño deslizamiento. Si [typing] es true (la respuesta que
/// acaba de llegar), el texto aparece letra a letra; tocarlo lo enseña entero.
class _Bubble extends StatefulWidget {
  const _Bubble({
    super.key,
    required this.turn,
    this.initial = '',
    this.name,
    this.photoUrl,
    this.typing = false,
    this.listenLabel,
    this.copyLabel,
    this.copiedLabel,
    this.onListen,
    this.onTyped,
  });

  final ChatTurn turn;

  /// Tu inicial (si no tienes foto) y tu foto (la que elegiste en el móvil
  /// o la de tu cuenta de Google).
  final String initial;
  final String? name;
  final String? photoUrl;
  final bool typing;

  /// Texto del botón de altavoz ("Escuchar"); sin él, no hay botones.
  final String? listenLabel;
  final String? copyLabel;
  final String? copiedLabel;
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

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.turn.text));
    final String? done = widget.copiedLabel;
    if (!mounted || done == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(done), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool mine = widget.turn.role == ChatRole.user;
    final String text = widget.turn.text;
    final String? listenLabel = widget.listenLabel;
    final String? copyLabel = widget.copyLabel;
    final Widget bubble = Flexible(
      child: GestureDetector(
        // Tocar mientras teclea: sale entero ya.
        onTap: _type.isAnimating ? () => _type.value = 1 : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            // Tuyos: degradado azul → violeta. De Flyra: cristal oscuro
            // con un filo violeta (sin el verde de antes).
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: mine
                  ? const <Color>[Color(0xFF4F6BFF), Color(0xFF8A5CF6)]
                  : const <Color>[Color(0xFF1D2340), Color(0xFF141A2C)],
            ),
            borderRadius: BorderRadiusDirectional.only(
              topStart: const Radius.circular(20),
              topEnd: const Radius.circular(20),
              bottomStart: Radius.circular(mine ? 20 : 6),
              bottomEnd: Radius.circular(mine ? 6 : 20),
            ).resolve(Directionality.of(context)),
            border: Border.all(
              color: mine ? const Color(0x55B9A4FF) : const Color(0x40A78BFA),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: mine ? const Color(0x405B6BFF) : const Color(0x33000000),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!mine)
                const Padding(
                  padding: EdgeInsets.only(bottom: 3),
                  child: Text(
                    'Flyra',
                    style: TextStyle(
                      color: Color(0xFFC4B2FF),
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              AnimatedBuilder(
                animation: _type,
                builder: (BuildContext context, Widget? _) {
                  final int shown = (text.length * _type.value).round();
                  // Se puede seleccionar y copiar (una dirección, una frase...).
                  return SelectableText(
                    shown >= text.length ? text : text.substring(0, shown),
                    // El lector de pantalla lee siempre el texto completo.
                    semanticsLabel: text,
                    style: const TextStyle(
                      color: Color(0xFFF1F0FF),
                      height: 1.45,
                      fontSize: 15,
                    ),
                  );
                },
              ),
              if (!mine && listenLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      _MiniAction(
                        tooltip: listenLabel,
                        icon: Icons.volume_up_rounded,
                        onTap: widget.onListen,
                      ),
                      if (copyLabel != null)
                        _MiniAction(
                          tooltip: copyLabel,
                          icon: Icons.copy_rounded,
                          onTap: _copy,
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
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
                const _GlowAvatar(size: 30),
                const SizedBox(width: 8),
              ] else
                const SizedBox(width: 38),
              bubble,
              if (mine) ...<Widget>[
                const SizedBox(width: 8),
                _MeDot(
                  initial: widget.initial,
                  name: widget.name,
                  photoUrl: widget.photoUrl,
                ),
              ] else
                const SizedBox(width: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// Un botoncito dentro del bocadillo de Flyra (escuchar, copiar).
class _MiniAction extends StatelessWidget {
  const _MiniAction({required this.tooltip, required this.icon, this.onTap});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkResponse(
      onTap: onTap,
      radius: 20,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(end: 12, top: 2, bottom: 2),
        child: Icon(icon, size: 18, color: const Color(0xFFA9A0F5)),
      ),
    ),
  );
}

/// Tu foto (la que elegiste en el móvil o la de Google) en un aro azul;
/// sin foto, tu inicial.
class _MeDot extends StatelessWidget {
  const _MeDot({required this.initial, this.name, this.photoUrl});

  final String initial;
  final String? name;
  final String? photoUrl;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(2),
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        colors: <Color>[Color(0xFF4F6BFF), Color(0xFF8A5CF6)],
      ),
    ),
    child: ExcludeSemantics(
      child: UserAvatar(
        name: name ?? initial,
        photoUrl: photoUrl,
        size: 28,
        color: NomadColors.flights,
        isMe: true,
      ),
    ),
  );
}

/// Ideas para la primera pregunta: tarjetas con icono (se envían al tocarlas).
class _Suggestions extends StatelessWidget {
  const _Suggestions({
    required this.title,
    required this.items,
    required this.onPick,
  });

  final String title;
  final List<String> items;
  final ValueChanged<String> onPick;

  static const List<(IconData, Color)> _looks = <(IconData, Color)>[
    (Icons.explore_rounded, NomadColors.mint),
    (Icons.luggage_rounded, NomadColors.flights),
    (Icons.directions_bus_rounded, NomadColors.money),
    (Icons.translate_rounded, NomadColors.group),
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 6, bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: NomadColors.textMuted,
            ),
          ),
        ),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints c) {
            final double w = (c.maxWidth - 10) / 2;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                for (int i = 0; i < items.length; i++)
                  SizedBox(
                    width: w,
                    child: _IdeaCard(
                      text: items[i],
                      icon: _looks[i % _looks.length].$1,
                      color: _looks[i % _looks.length].$2,
                      delay: i,
                      onTap: () => onPick(items[i]),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    ),
  );
}

class _IdeaCard extends StatelessWidget {
  const _IdeaCard({
    required this.text,
    required this.icon,
    required this.color,
    required this.delay,
    required this.onTap,
  });

  final String text;
  final IconData icon;
  final Color color;
  final int delay;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Duration(milliseconds: 450 + delay * 120),
    curve: Curves.easeOutCubic,
    builder: (BuildContext context, double v, Widget? child) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 14 * (1 - v)), child: child),
    ),
    child: Material(
      color: NomadColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: NomadColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: color, size: 19),
              ),
              const SizedBox(height: 10),
              Text(
                text,
                style: const TextStyle(
                  color: NomadColors.text,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Ideas rápidas encima de la caja, en una fila que se desliza.
class _QuickIdeas extends StatelessWidget {
  const _QuickIdeas({required this.items, required this.onPick});

  final List<String> items;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 40,
    child: ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      scrollDirection: Axis.horizontal,
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(width: 8),
      itemBuilder: (BuildContext context, int i) => ActionChip(
        backgroundColor: const Color(0xFF1A2036),
        side: const BorderSide(color: Color(0xFF323C66)),
        shape: const StadiumBorder(),
        label: Text(
          items[i],
          style: const TextStyle(
            color: NomadColors.text,
            fontWeight: FontWeight.w700,
            fontSize: 12.5,
          ),
        ),
        onPressed: () => onPick(items[i]),
      ),
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
        const _GlowAvatar(size: 28),
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
                      color: NomadColors.group,
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
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    child: Container(
      padding: const EdgeInsetsDirectional.fromSTEB(6, 4, 4, 4),
      decoration: BoxDecoration(
        color: const Color(0xE6141A2C),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: listening ? const Color(0xFFB69CFF) : const Color(0xFF2C3558),
          width: listening ? 1.6 : 1,
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x338A5CF6),
            blurRadius: 18,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          // El micro: mientras escucha se pone del color de Flyra.
          IconButton(
            tooltip: micLabel,
            isSelected: listening,
            onPressed: enabled ? onMic : null,
            icon: const Icon(Icons.mic_none_rounded),
            selectedIcon: const Icon(
              Icons.mic_rounded,
              color: NomadColors.group,
            ),
          ),
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
              style: const TextStyle(fontSize: 15),
              decoration: InputDecoration(
                hintText: hint,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 12,
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            tooltip: sendLabel,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFF7B61FF),
              foregroundColor: Colors.white,
              disabledBackgroundColor: NomadColors.surfaceHigh,
            ),
            onPressed: enabled ? () => onSend() : null,
            // En árabe la flecha apunta al otro lado (la app se da la vuelta).
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
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

/// El fondo del chat: noche azul con tres luces suaves (violeta, azul y
/// rosa) que se mueven muy despacio, como una aurora. Solo degradados (sin
/// desenfoques), así no gasta batería ni hace que la lista vaya a tirones.
class _Aurora extends StatefulWidget {
  const _Aurora({required this.child});

  final Widget child;

  @override
  State<_Aurora> createState() => _AuroraState();
}

class _AuroraState extends State<_Aurora> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _t.stop();
    } else if (!_t.isAnimating) {
      Motion.loop(_t, testCount: 1);
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _AuroraPainter(_t),
    // La lista se pinta en su propia capa: la aurora no la redibuja.
    child: RepaintBoundary(child: widget.child),
  );
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t) : super(repaint: t);

  final Animation<double> t;

  static const List<(Color, double, double, double)> _lights =
      <(Color, double, double, double)>[
        (Color(0x388A5CF6), -0.7, -0.9, 0.0),
        (Color(0x2E4F6BFF), 0.9, -0.4, 0.33),
        (Color(0x1FFF7AB6), -0.4, 0.9, 0.66),
      ];

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF0B1020), Color(0xFF0B1217)],
        ).createShader(Offset.zero & size),
    );
    final double r = size.longestSide * 0.55;
    for (final (Color c, double x, double y, double phase) in _lights) {
      final double a = (t.value + phase) * 2 * math.pi;
      final Offset center = Offset(
        size.width * (0.5 + 0.5 * x + 0.08 * math.cos(a)),
        size.height * (0.5 + 0.5 * y + 0.06 * math.sin(a)),
      );
      canvas.drawCircle(
        center,
        r,
        Paint()
          ..shader = RadialGradient(colors: <Color>[c, c.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: center, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => false;
}
