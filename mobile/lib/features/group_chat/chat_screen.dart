// Chat del viaje: la maqueta "Chat del grupo" tal cual
// (assets/group_chat/chat.html, dentro de un WebView). Todos los del viaje
// en grupo y Flyra dentro: lo que escribes le llega a Flyra, que contesta
// en el hilo sabiendo qué tipo de viaje es (familia = sin cuestas, pareja =
// planes para dos...) y quién ha dicho qué.
//
// ¿Cómo llegan los mensajes nuevos sin gastar dinero?
//   - Con el chat en pantalla, la app pregunta cada 4 segundos "¿hay algo
//     después del último que tengo?". Es una consulta mínima. Si en 2 minutos
//     no llega nada, pregunta más despacio (cada 15 s): un grupo callado casi
//     no gasta.
//   - Con la app en segundo plano NO pregunta (ni batería ni servidor). Para
//     eso está el aviso push.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/api_client.dart';
import '../../core/router.dart';
import '../../core/services.dart';
import '../../core/settings.dart';
import '../../l10n/generated/app_localizations.dart';
import '../flights/flights_page.dart' show unpackJson;
import '../group/group_api.dart';
import '../group/group_hub.dart' show tasteLabel, tastesInText;
import '../money/money_screen.dart' show MoneyTab;
import '../plans/plans_api.dart';
import '../route/web_scene.dart';
import 'chat_api.dart';
import 'chat_page.dart';

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

  /// El puente de la última pantalla abierta (lo miran los tests).
  static WebSceneBridge? lastBridge;

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen>
    with WidgetsBindingObserver {
  late final AppServices _services = ServicesScope.of(context);
  final WebSceneBridge _bridge = GroupChatScreen.lastBridge = WebSceneBridge();

  /// La página se lee una vez (se guarda el texto, no la espera).
  static String? _pageCache;
  String? _html;
  String? _sent;
  bool _started = false;

  ChatPage? _page;
  final List<ChatMessage> _messages = <ChatMessage>[];
  bool _failed = false;

  /// Tu mensaje mientras se envía (y si Flyra está pensando).
  String? _pending;
  bool _flyraTyping = false;
  bool _listening = false;

  GroupPlan? _plan;
  String? _code;
  Set<int> _likes = <int>{};

  Timer? _timer;
  DateTime _lastNews = DateTime.now();
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
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

  Future<void> _start() async {
    try {
      _pageCache ??= await rootBundle.loadString(chatPage, cache: false);
    } on Object {
      return;
    }
    _likes = _readLikes();
    if (mounted) setState(() {});
    await _load();
    unawaited(_loadExtras());
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
        _failed = false;
      });
    } on ApiException {
      if (mounted) setState(() => _failed = true);
    }
    if (mounted) _schedule();
  }

  /// El match del grupo (para la tarjeta de Flyra) y el código para invitar.
  Future<void> _loadExtras() async {
    try {
      final PlanBoard b = await _services.plans.board(widget.tripId);
      if (mounted) setState(() => _plan = chatPlan(b));
    } on ApiException {
      // Sin match no sale la tarjeta: nada más.
    }
    try {
      final GroupTrip trip = await _services.group.get(widget.tripId);
      if (mounted) setState(() => _code = trip.inviteCode);
    } on ApiException {
      // Sin código, "Añadir al chat" dice que lo tiene quien organiza.
    }
  }

  void _schedule() {
    _timer?.cancel();
    final bool quiet =
        DateTime.now().difference(_lastNews) > const Duration(minutes: 2);
    _timer = Timer(
      quiet ? widget.slowPoll : widget.fastPoll,
      () => unawaited(_page == null ? _load() : _poll()),
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
      final bool fresh = _merge(page.messages);
      if (fresh) _lastNews = DateTime.now();
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
    return true;
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  /// Escribir al grupo. Como en la maqueta, Flyra contesta siempre: el
  /// mensaje va con "@Flyra" delante (la etiqueta de la caja de texto).
  Future<void> _send(String raw) async {
    final String text = raw.trim();
    if (text.isEmpty || _pending != null) return;
    final AppLocalizations t = AppLocalizations.of(context);
    final String out = mentionsFlyra(text) ? text : '@Flyra $text';
    setState(() => (_pending = out, _flyraTyping = true));
    try {
      final Posted posted = await _services.groupChat.send(
        widget.tripId,
        out,
        Localizations.localeOf(context).languageCode,
      );
      if (!mounted) return;
      setState(() => _merge(posted.messages));
      _lastNews = DateTime.now();
      unawaited(_noteTastes(text));
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
      if (mounted) setState(() => (_pending = null, _flyraTyping = false));
    }
  }

  /// "Apuntado en tus gustos": si el mensaje nombra gustos (por palabras
  /// clave, sin IA), se añaden a los tuyos de "Gustos de cada uno".
  Future<void> _noteTastes(String text) async {
    final AppLocalizations t = AppLocalizations.of(context);
    final List<String> said = tastesInText(t, text);
    if (said.isEmpty) return;
    try {
      final GroupTrip trip = await _services.group.get(widget.tripId);
      final List<String> mine = trip.me?.tastes ?? const <String>[];
      final List<String> fresh = <String>[
        for (final String id in said)
          if (!mine.contains(id)) id,
      ];
      if (fresh.isEmpty) return;
      await _services.group.setTastes(widget.tripId, <String>[
        ...mine,
        ...fresh,
      ]);
      if (mounted) {
        _snack(
          t.tastesNoted(fresh.map((String id) => tasteLabel(t, id)).join(', ')),
        );
      }
    } on ApiException {
      // Si no se puede apuntar, el mensaje ya se envió: no pasa nada.
    }
  }

  /// El micro: lo que dices se escribe y se manda.
  Future<void> _listen() async {
    if (_listening || _pending != null) return;
    final AppLocalizations t = AppLocalizations.of(context);
    final String lang = Localizations.localeOf(context).languageCode;
    setState(() => _listening = true);
    String? heard;
    try {
      heard = await _services.speechInput.listen(lang);
    } on Object {
      heard = null;
    }
    if (!mounted) return;
    setState(() => _listening = false);
    if (heard == null || heard.trim().isEmpty) {
      _snack(t.voiceNotHeard);
      return;
    }
    await _send(heard);
  }

  /// "Crear chat · Familia": Flyra se adapta. "Solo" es el chat privado con
  /// Flyra (sin el grupo).
  Future<void> _setKind(String k) async {
    if (k == 'solo') {
      unawaited(context.push(Routes.flyra()));
      return;
    }
    final ChatTripKind? kind = ChatTripKind.values
        .where((ChatTripKind c) => c.name == k)
        .firstOrNull;
    if (kind == null) return;
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      await _services.groupChat.setKind(widget.tripId, kind);
      if (mounted) await _load();
    } on ApiException {
      if (mounted) _snack(t.chatSendFailed);
    }
  }

  /// Tocando tu cara: tu nombre en el chat.
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

  /// "+ Añadir al plan" en la tarjeta del match: se apunta y se avisa al
  /// grupo en el chat.
  Future<void> _addToPlan(String id) async {
    final AppLocalizations t = AppLocalizations.of(context);
    try {
      final PlanBoard b = await _services.plans.addToPlan(widget.tripId, id);
      if (!mounted) return;
      final GroupPlan? p = b.plans
          .where((GroupPlan x) => x.id == id)
          .firstOrNull;
      setState(() => _plan = p ?? chatPlan(b));
      if (p == null || !p.planned) return;
      final Posted posted = await _services.groupChat.send(
        widget.tripId,
        t.plansChatAdded(p.title),
        Localizations.localeOf(context).languageCode,
      );
      if (mounted) setState(() => _merge(posted.messages));
    } on ApiException {
      if (mounted) _snack(t.chatSendFailed);
    }
  }

  /// Los "me gusta" a Flyra se guardan en el móvil ("viaje:mensaje").
  Set<int> _readLikes() {
    final String prefix = '${widget.tripId}:';
    try {
      final Object? l = jsonDecode(
        _services.prefs.readData(LocalData.chatLikes) ?? '[]',
      );
      return <int>{
        if (l is List<Object?>)
          for (final Object? k in l)
            if (k is String && k.startsWith(prefix))
              ?int.tryParse(k.substring(prefix.length)),
      };
    } on FormatException {
      return <int>{};
    }
  }

  Future<void> _like(int id, bool on) async {
    if (on) {
      _likes.add(id);
    } else {
      _likes.remove(id);
    }
    List<String> all;
    try {
      final Object? l = jsonDecode(
        _services.prefs.readData(LocalData.chatLikes) ?? '[]',
      );
      all = <String>[
        if (l is List<Object?>)
          for (final Object? k in l)
            if (k is String && !k.startsWith('${widget.tripId}:')) k,
      ];
    } on FormatException {
      all = <String>[];
    }
    all.addAll(<String>[for (final int i in _likes) '${widget.tripId}:$i']);
    // Solo los últimos 300: la lista no crece sin fin.
    await _services.prefs.writeData(
      LocalData.chatLikes,
      jsonEncode(all.length > 300 ? all.sublist(all.length - 300) : all),
    );
  }

  /// Lo que pide la página.
  void _onMessage(String m) {
    final List<String> p = m.split(':');
    final int? n = p.length > 1 ? int.tryParse(p[1]) : null;
    final Map<String, Object?> data =
        (p.length == 3 ? unpackJson(p[2]) : null) ?? const <String, Object?>{};
    final Object? id = data['id'];
    final Object? text = data['t'];
    final Object? kind = data['k'];
    final Object? code = data['c'];
    switch (p.first) {
      case 'back':
        if (context.canPop()) context.pop();
      case 'send' when text is String:
        unawaited(_send(text));
      case 'mic':
        unawaited(_listen());
      case 'kind' when kind is String:
        unawaited(_setKind(kind));
      case 'name':
        unawaited(_rename());
      case 'addplan' when id is String:
        unawaited(_addToPlan(id));
      case 'like' when id is int && n != null:
        unawaited(_like(id, n == 1));
      case 'money':
        unawaited(context.push(Routes.money(tab: MoneyTab.expenses)));
      case 'share' when code is String:
        unawaited(
          _services.share(
            const <String>[],
            text:
                'Únete a nuestro viaje en ECLIPTA con el código '
                '$code',
          ),
        );
      case 'memories':
        unawaited(context.push(Routes.memories));
      case 'play':
        // La reseña la escribe la persona: nunca se manda nada por ella.
        unawaited(
          _services.openLink(
            Uri.https(
              'play.google.com',
              '/store/apps/details',
              <String, String>{'id': 'com.eclipta.app'},
            ),
          ),
        );
    }
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
    final Map<String, Object?> data = chatPageData(
      city: _page?.title ?? '',
      page: _page,
      messages: _messages,
      pending: _pending,
      typing: _flyraTyping,
      rec: _listening,
      plan: _plan,
      code: _code,
      likes: _likes,
      failed: _failed,
    );
    final String push = chatPushScript(data);
    if (_html == null) {
      _html = chatPageWith(page, data);
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

/// Tu nombre en el chat (se abre tocando tu cara arriba).
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
