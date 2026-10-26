// Chat del viaje (maqueta "Chat del viaje"): todos los del viaje en grupo
// y Flyra dentro. Si alguien escribe "@Flyra ...", contesta ella en el hilo,
// sabiendo qué tipo de viaje es (familia = sin cuestas, pareja = planes para
// dos...) y quién ha dicho qué.
//
// ¿Cómo llegan los mensajes nuevos sin gastar dinero?
//   - Con el chat en pantalla, la app pregunta cada 4 segundos "¿hay algo
//     después del último que tengo?". Es una consulta mínima. Si en 2 minutos
//     no llega nada, pregunta más despacio (cada 15 s): un grupo callado casi
//     no gasta.
//   - Con la app en segundo plano NO pregunta (ni batería ni servidor). Para
//     eso está el aviso push.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../widgets/flyra_avatar.dart';
import '../../widgets/user_avatar.dart';
import '../group/group_api.dart';
import 'chat_api.dart';

class GroupChatScreen extends StatefulWidget {
  const GroupChatScreen({
    super.key,
    required this.tripId,
    this.fastPoll = const Duration(seconds: 4),
    this.slowPoll = const Duration(seconds: 15),
  });

  final String tripId;

  /// Cada cuánto pregunta si hay mensajes nuevos (en los tests, más rápido).
  final Duration fastPoll;
  final Duration slowPoll;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen>
    with WidgetsBindingObserver {
  late final AppServices _services = ServicesScope.of(context);
  final TextEditingController _text = TextEditingController();
  final ScrollController _scroll = ScrollController();

  ChatPage? _page;
  final List<ChatMessage> _messages = <ChatMessage>[];
  Object? _error;
  bool _sending = false;
  bool _flyraTyping = false;

  Timer? _timer;
  DateTime _lastNews = DateTime.now();
  bool _polling = false;
  bool _askedKind = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_load()));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // En segundo plano, nada de preguntar: al volver, se pone al día.
    if (state == AppLifecycleState.resumed) {
      _lastNews = DateTime.now();
      _schedule();
      unawaited(_poll());
    } else {
      _timer?.cancel();
    }
  }

  int? get _lastId => _messages.isEmpty ? null : _messages.last.id;

  Future<void> _load() async {
    try {
      final ChatPage page = await _services.groupChat.read(widget.tripId);
      if (!mounted) return;
      setState(() {
        _page = page;
        _messages
          ..clear()
          ..addAll(page.messages);
        _error = null;
      });
      _toBottom();
      _schedule();
      // Chat recién creado: primero, "¿con quién vas?".
      if (page.messages.isEmpty && !_askedKind) {
        _askedKind = true;
        unawaited(_pickKind(first: true));
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _schedule() {
    _timer?.cancel();
    final bool quiet =
        DateTime.now().difference(_lastNews) > const Duration(minutes: 2);
    _timer = Timer(
      quiet ? widget.slowPoll : widget.fastPoll,
      () => unawaited(_poll()),
    );
  }

  Future<void> _poll() async {
    if (_polling || _page == null) return;
    _polling = true;
    try {
      final ChatPage page = await _services.groupChat.read(
        widget.tripId,
        after: _lastId,
      );
      if (!mounted) return;
      if (_merge(page.messages)) _lastNews = DateTime.now();
      setState(() => _page = page);
    } on ApiException {
      // Sin red un momento: se vuelve a probar en el siguiente turno.
    } finally {
      _polling = false;
      if (mounted) _schedule();
    }
  }

  /// Añade los que no estaban (por número) y dice si había alguno nuevo.
  bool _merge(List<ChatMessage> fresh) {
    final Set<int> known = <int>{for (final ChatMessage m in _messages) m.id};
    final List<ChatMessage> added = <ChatMessage>[
      for (final ChatMessage m in fresh)
        if (!known.contains(m.id)) m,
    ];
    if (added.isEmpty) return false;
    _messages
      ..addAll(added)
      ..sort((ChatMessage a, ChatMessage b) => a.id.compareTo(b.id));
    _toBottom();
    return true;
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  Future<void> _send([String? preset]) async {
    final String text = (preset ?? _text.text).trim();
    if (text.isEmpty || _sending) return;
    final AppLocalizations t = AppLocalizations.of(context);
    final bool forFlyra = mentionsFlyra(text);
    setState(() => (_sending = true, _flyraTyping = forFlyra));
    try {
      final Posted posted = await _services.groupChat.send(
        widget.tripId,
        text,
        Localizations.localeOf(context).languageCode,
      );
      if (!mounted) return;
      if (preset == null) _text.clear();
      setState(() => _merge(posted.messages));
      _lastNews = DateTime.now();
      switch (posted.flyra) {
        case FlyraTrouble.quota:
          _snack(t.chatFlyraQuota);
        case FlyraTrouble.busy:
          _snack(t.chatFlyraBusy);
        case null:
          break;
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      _snack(
        e.error == ApiError.rateLimited ? t.chatTooMany : t.chatSendFailed,
      );
    } finally {
      if (mounted) setState(() => (_sending = false, _flyraTyping = false));
    }
  }

  Future<void> _pickKind({bool first = false}) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final _KindChoice? choice = await showModalBottomSheet<_KindChoice>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => _KindSheet(
        current: first ? null : _page?.kind,
        title: t.chatKindTitle,
      ),
    );
    if (choice == null || !mounted) return;
    if (choice.solo) {
      // "Solo" = el chat privado con Flyra (sin el grupo).
      unawaited(context.push(Routes.flyra()));
      return;
    }
    try {
      await _services.groupChat.setKind(widget.tripId, choice.kind!);
      if (mounted) await _load();
    } on ApiException {
      if (mounted) _snack(t.chatSendFailed);
    }
  }

  Future<void> _rename() async {
    final AppLocalizations t = AppLocalizations.of(context);
    final ChatMember? me = _page?.members
        .where((ChatMember m) => m.me)
        .firstOrNull;
    final String? name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: me?.name ?? ''),
    );
    if (name == null || !mounted) return;
    try {
      await _services.groupChat.setName(
        widget.tripId,
        name.isEmpty ? null : name,
      );
      if (mounted) await _load();
    } on ApiException {
      if (mounted) _snack(t.chatSendFailed);
    }
  }

  Future<void> _invite() async {
    final AppLocalizations t = AppLocalizations.of(context);
    String? code;
    try {
      final GroupTrip trip = await _services.group.get(widget.tripId);
      code = trip.inviteCode;
    } on ApiException {
      code = null;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      builder: (BuildContext context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                t.chatInviteTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (code != null) ...<Widget>[
                SelectableText(
                  code,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Text(t.chatInviteText, textAlign: TextAlign.center),
                const SizedBox(height: 12),
                FilledButton.icon(
                  icon: const Icon(Icons.copy_rounded),
                  label: Text(t.chatInviteCopy),
                  onPressed: () {
                    unawaited(Clipboard.setData(ClipboardData(text: code!)));
                    Navigator.of(context).pop();
                  },
                ),
              ] else
                Text(t.chatInviteAskOrganizer),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _end() async {
    final ChatPage? page = _page;
    if (page == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (_) => _EndSheet(
        title: page.title,
        messages: _messages.where((ChatMessage m) => !m.flyra).length,
        flyraAnswers: _messages.where((ChatMessage m) => m.flyra).length,
        people: page.members.where((ChatMember m) => m.active).length,
      ),
    );
  }

  void _showFlyra() {
    final AppLocalizations t = AppLocalizations.of(context);
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        builder: (BuildContext context) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const FlyraAvatar(size: 72),
                const SizedBox(height: 8),
                Text('Flyra', style: Theme.of(context).textTheme.headlineSmall),
                Text(t.chatFlyraRole),
                const SizedBox(height: 12),
                for (final String line in <String>[
                  t.chatFlyraLanguages,
                  t.chatFlyraKnowsTrip,
                  t.chatFlyraNoSelling,
                ])
                  ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.check_circle_rounded,
                      color: NomadColors.mint,
                    ),
                    title: Text(line),
                  ),
                const SizedBox(height: 8),
                Text(
                  t.chatFlyraHint,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: NomadColors.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _kindLabel(AppLocalizations t, ChatTripKind kind) => switch (kind) {
    ChatTripKind.friends => t.chatKindFriends,
    ChatTripKind.couple => t.chatKindCouple,
    ChatTripKind.family => t.chatKindFamily,
  };

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final ChatPage? page = _page;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: page == null
            ? Text(t.chatTitle)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(page.title, overflow: TextOverflow.ellipsis),
                  Text(
                    '${_kindLabel(t, page.kind)} · ${page.members.where((ChatMember m) => m.active).map((ChatMember m) => m.me ? t.chatYou : m.name).join(', ')} · Flyra',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: NomadColors.textMuted,
                    ),
                  ),
                ],
              ),
        actions: <Widget>[
          IconButton(
            tooltip: t.chatFlyraProfile,
            onPressed: _showFlyra,
            icon: const FlyraAvatar(size: 30),
          ),
          PopupMenuButton<String>(
            onSelected: (String v) => unawaited(switch (v) {
              'invite' => _invite(),
              'name' => _rename(),
              'kind' => _pickKind(),
              _ => _end(),
            }),
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'invite',
                child: Text(t.chatInviteTitle),
              ),
              PopupMenuItem<String>(value: 'name', child: Text(t.chatMyName)),
              PopupMenuItem<String>(
                value: 'kind',
                child: Text(t.chatKindTitle),
              ),
              PopupMenuItem<String>(value: 'end', child: Text(t.chatEndTrip)),
            ],
          ),
        ],
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(t.chatLoadFailed, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: () => unawaited(_load()),
                      child: Text(t.chatRetry),
                    ),
                  ],
                ),
              ),
            )
          : page == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: <Widget>[
                Expanded(
                  child: _messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              t.chatEmpty,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: NomadColors.textMuted,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                          itemCount: _messages.length + (_flyraTyping ? 1 : 0),
                          itemBuilder: (_, int i) => i == _messages.length
                              ? _Typing(label: t.chatFlyraTyping)
                              : _Bubble(message: _messages[i]),
                        ),
                ),
                SizedBox(
                  height: 44,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: <Widget>[
                        for (final String q in <String>[
                          t.chatQuickDinner,
                          t.chatQuickTomorrow,
                          t.chatQuickRain,
                        ])
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: ActionChip(
                              label: Text(q),
                              onPressed: _sending
                                  ? null
                                  : () => unawaited(_send(q)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                    child: Row(
                      children: <Widget>[
                        IconButton(
                          tooltip: t.chatMentionFlyra,
                          icon: const Icon(Icons.alternate_email_rounded),
                          onPressed: () {
                            if (!mentionsFlyra(_text.text)) {
                              _text.text = '@Flyra ${_text.text}';
                            }
                            _text.selection = TextSelection.collapsed(
                              offset: _text.text.length,
                            );
                          },
                        ),
                        Expanded(
                          child: TextField(
                            controller: _text,
                            minLines: 1,
                            maxLines: 4,
                            maxLength: maxChatText,
                            textInputAction: TextInputAction.send,
                            decoration: InputDecoration(
                              hintText: t.chatHint,
                              counterText: '',
                            ),
                            onSubmitted: (_) => unawaited(_send()),
                          ),
                        ),
                        IconButton.filled(
                          tooltip: t.chatSend,
                          icon: _sending
                              ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send_rounded),
                          onPressed: _sending ? null : () => unawaited(_send()),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

/// Un mensaje: los tuyos a la derecha, los demás a la izquierda con su
/// nombre, y los de Flyra con su foto y otro color.
class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ChatMessage m = message;
    final String time = DateFormat.Hm(
      Localizations.localeOf(context).toLanguageTag(),
    ).format(m.at.toLocal());
    final Color bg = m.mine
        ? const Color(0xFF24414F)
        : m.flyra
        ? const Color(0xFF13342A)
        : const Color(0xFF2A1E26);
    final Widget avatar = m.flyra
        ? const FlyraAvatar(size: 30)
        : UserAvatar(
            name: m.name.isEmpty ? '?' : m.name,
            photoUrl: m.photoUrl,
            size: 30,
            textColor: const Color(0xFF0B1217),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: m.mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          if (!m.mine) ...<Widget>[avatar, const SizedBox(width: 8)],
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 300),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(16),
                border: m.flyra
                    ? Border.all(color: const Color(0xFF23523F))
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (!m.mine)
                    Text(
                      m.name,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: m.flyra
                            ? NomadColors.mint
                            : const Color(0xFFFFB3C9),
                      ),
                    ),
                  Text(m.text),
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Text(
                      time,
                      style: const TextStyle(
                        fontSize: 10,
                        color: NomadColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: <Widget>[
        const FlyraAvatar(size: 30),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            fontStyle: FontStyle.italic,
            color: NomadColors.textMuted,
          ),
        ),
      ],
    ),
  );
}

/// Lo elegido en "¿Con quién vas?": un tipo de viaje, o "solo".
class _KindChoice {
  const _KindChoice.kind(ChatTripKind this.kind) : solo = false;
  const _KindChoice.solo() : kind = null, solo = true;

  final ChatTripKind? kind;
  final bool solo;
}

class _KindSheet extends StatelessWidget {
  const _KindSheet({required this.current, required this.title});

  final ChatTripKind? current;
  final String title;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<(_KindChoice, IconData, Color, String, String)> options =
        <(_KindChoice, IconData, Color, String, String)>[
          (
            const _KindChoice.solo(),
            Icons.person_rounded,
            NomadColors.flights,
            t.chatKindSolo,
            t.chatKindSoloText,
          ),
          (
            const _KindChoice.kind(ChatTripKind.friends),
            Icons.groups_rounded,
            NomadColors.group,
            t.chatKindFriends,
            t.chatKindFriendsText,
          ),
          (
            const _KindChoice.kind(ChatTripKind.couple),
            Icons.favorite_rounded,
            const Color(0xFFFF8FB1),
            t.chatKindCouple,
            t.chatKindCoupleText,
          ),
          (
            const _KindChoice.kind(ChatTripKind.family),
            Icons.family_restroom_rounded,
            NomadColors.money,
            t.chatKindFamily,
            t.chatKindFamilyText,
          ),
        ];
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const FlyraAvatar(size: 40),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(t.chatKindIntro),
            const SizedBox(height: 12),
            for (final (
                  _KindChoice choice,
                  IconData icon,
                  Color color,
                  String label,
                  String sub,
                )
                in options)
              Card(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                  side: choice.kind != null && choice.kind == current
                      ? BorderSide(color: color, width: 2)
                      : BorderSide.none,
                ),
                child: ListTile(
                  leading: Icon(icon, color: color),
                  title: Text(label),
                  subtitle: Text(sub),
                  onTap: () => Navigator.of(context).pop(choice),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _c = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(t.chatMyName),
      content: TextField(
        controller: _c,
        autofocus: true,
        maxLength: 30,
        decoration: InputDecoration(helperText: t.chatMyNameHelp),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_c.text.trim()),
          child: Text(MaterialLocalizations.of(context).saveButtonLabel),
        ),
      ],
    );
  }
}

/// "Viaje terminado": el resumen, las estrellas y el vídeo de Recuerdos.
class _EndSheet extends StatefulWidget {
  const _EndSheet({
    required this.title,
    required this.messages,
    required this.flyraAnswers,
    required this.people,
  });

  final String title;
  final int messages;
  final int flyraAnswers;
  final int people;

  @override
  State<_EndSheet> createState() => _EndSheetState();
}

class _EndSheetState extends State<_EndSheet> {
  int _stars = 0;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = AppLocalizations.of(context);
    final AppServices services = ServicesScope.of(context);
    final String verdict = switch (_stars) {
      0 => t.chatStarsTap,
      1 || 2 => t.chatStarsBad,
      3 || 4 => t.chatStarsOk,
      _ => t.chatStarsGreat,
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              t.chatTripOver,
              style: const TextStyle(
                letterSpacing: 2,
                fontWeight: FontWeight.w800,
                color: NomadColors.mint,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t.chatWhatATrip(widget.title),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: <Widget>[
                for (final (int v, String l) in <(int, String)>[
                  (widget.people, t.chatStatPeople),
                  (widget.messages, t.chatStatMessages),
                  (widget.flyraAnswers, t.chatStatFlyra),
                ])
                  Expanded(
                    child: Column(
                      children: <Widget>[
                        Text(
                          '$v',
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          l,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: NomadColors.textMuted),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 20),
            Text(t.chatHowWasIt),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                for (int n = 1; n <= 5; n++)
                  IconButton(
                    tooltip: t.chatStarsLabel(n),
                    onPressed: () => setState(() => _stars = n),
                    icon: Icon(
                      n <= _stars
                          ? Icons.star_rounded
                          : Icons.star_border_rounded,
                      size: 36,
                      color: n <= _stars
                          ? const Color(0xFFFFD166)
                          : NomadColors.textMuted,
                    ),
                  ),
              ],
            ),
            Text(verdict, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            // Con 5 estrellas, se le invita a decirlo en Google Play (la
            // reseña la escribe la persona: nunca se manda nada por ella).
            if (_stars == 5)
              FilledButton.icon(
                icon: const Icon(Icons.shop_rounded),
                label: Text(t.chatRatePlay),
                onPressed: () => unawaited(
                  services.openLink(
                    Uri.https(
                      'play.google.com',
                      '/store/apps/details',
                      <String, String>{'id': 'com.nomadiq.app'},
                    ),
                  ),
                ),
              ),
            TextButton.icon(
              icon: const Icon(Icons.movie_rounded),
              label: Text(t.chatSeeVideo),
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(context.push(Routes.memories));
              },
            ),
          ],
        ),
      ),
    );
  }
}
