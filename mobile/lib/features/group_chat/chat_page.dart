// Lo que la app le da a la página del chat del viaje (la maqueta "Chat del
// grupo", en assets/group_chat/chat.html): quién está, los mensajes de
// verdad (con Flyra dentro), el match del grupo de Elegid planes, el código
// para invitar (con su QR) y las cifras del final del viaje.
//
// Dart puro: se prueba sin WebView.
import 'dart:convert';

import 'package:qr_flutter/qr_flutter.dart';

import '../group/group_page.dart' show faceColors;
import '../plans/plans_api.dart';
import 'chat_api.dart';

/// Dónde está la página y la marca donde la app mete sus datos.
const String chatPage = 'assets/group_chat/chat.html';
const String chatMarker = '/*ECLIPTA*/{}';

/// Tu color en el chat (el verde de la maqueta).
const String myChatColor = '#3DDC97';

const List<String> _weekdays = <String>[
  'lunes',
  'martes',
  'miércoles',
  'jueves',
  'viernes',
  'sábado',
  'domingo',
];
const List<String> _months = <String>[
  'ene',
  'feb',
  'mar',
  'abr',
  'may',
  'jun',
  'jul',
  'ago',
  'sep',
  'oct',
  'nov',
  'dic',
];

/// "Hoy · domingo", "Ayer · sábado" o "jueves 6 nov".
String chatDayLabel(DateTime at, DateTime now) {
  final DateTime a = DateTime(at.year, at.month, at.day);
  final DateTime n = DateTime(now.year, now.month, now.day);
  final String wd = _weekdays[a.weekday - 1];
  final int ago = n.difference(a).inDays;
  if (ago == 0) return 'Hoy · $wd';
  if (ago == 1) return 'Ayer · $wd';
  return '$wd ${a.day} ${_months[a.month - 1]}';
}

/// Qué tarjeta va bajo la respuesta de Flyra, según lo que le preguntaste:
/// "money" (los gastos del viaje), "plan" (vuestro match) o ninguna.
String? chatCard(String question) {
  final String s = question.toLowerCase();
  if (RegExp('llu|llov').hasMatch(s)) return null;
  if (RegExp('gast|cuánto|cuanto|dinero|pag|debe').hasMatch(s)) {
    return 'money';
  }
  if (RegExp(r'mañana|hacemos|\bplan').hasMatch(s)) return 'plan';
  return null;
}

/// Tu mensaje sin el "@Flyra" del principio (en la maqueta, la etiqueta
/// "@Flyra" va fuera del texto).
String withoutMention(String text) =>
    text.replaceFirst(RegExp(r'^\s*@flyra\b[\s,:]*', caseSensitive: false), '');

/// El QR del código (21×21, como el dibujo de la maqueta), como el "d" de
/// un `<path>` SVG: un cuadradito por cada punto negro. '' si no cabe.
String qrPath(String code) {
  try {
    final QrCode qr = QrCode(1, QrErrorCorrectLevel.M)..addData(code);
    final QrImage img = QrImage(qr);
    final StringBuffer d = StringBuffer();
    for (int y = 0; y < img.moduleCount; y++) {
      for (int x = 0; x < img.moduleCount; x++) {
        if (img.isDark(y, x)) d.write('M$x ${y}h1v1h-1z');
      }
    }
    return d.toString();
  } on Object {
    return '';
  }
}

/// El match del grupo que sale en la tarjeta de Flyra: el primero que aún
/// no está en el plan (o, si ya están todos, el primero).
GroupPlan? chatPlan(PlanBoard? board) {
  final List<GroupPlan> m = <GroupPlan>[
    for (final GroupPlan p in board?.plans ?? const <GroupPlan>[])
      if (p.myMatch) p,
  ];
  return m.where((GroupPlan p) => !p.planned).firstOrNull ?? m.firstOrNull;
}

/// Todo lo que necesita la página. [pending] es tu mensaje mientras se
/// envía; [failed] = no se pudo leer el chat.
Map<String, Object?> chatPageData({
  required String city,
  ChatPage? page,
  List<ChatMessage> messages = const <ChatMessage>[],
  String? pending,
  bool typing = false,
  bool rec = false,
  GroupPlan? plan,
  String? code,
  Set<int> likes = const <int>{},
  bool failed = false,
  DateTime? now,
}) {
  final List<ChatMember> people = <ChatMember>[
    for (final ChatMember m in page?.members ?? const <ChatMember>[])
      if (m.active) m,
  ];
  String colorOf(int? seat, bool mine) =>
      mine ? myChatColor : faceColors[(seat ?? 0) % faceColors.length];
  String initial(String name) =>
      String.fromCharCodes(name.trim().runes.take(1)).toUpperCase();
  final List<Map<String, Object?>> msgs = <Map<String, Object?>>[];
  String? asked;
  for (final ChatMessage m in messages) {
    if (m.mine) asked = mentionsFlyra(m.text) ? m.text : null;
    final String? card = m.flyra && asked != null ? chatCard(asked) : null;
    if (m.flyra) asked = null;
    msgs.add(<String, Object?>{
      'id': m.id,
      'who': m.flyra
          ? 'ia'
          : m.mine
          ? 'me'
          : 'p',
      'name': m.name,
      'text': m.mine ? withoutMention(m.text) : m.text,
      'c': colorOf(m.seat, m.mine),
      'card': ?(card == 'plan' && plan == null ? null : card),
    });
  }
  if (pending != null) {
    msgs.add(<String, Object?>{
      'id': -1,
      'who': 'me',
      'name': '',
      'text': withoutMention(pending),
      'c': myChatColor,
    });
  }
  if (failed && page == null) {
    msgs.add(<String, Object?>{
      'id': 0,
      'who': 'ia',
      'name': 'Flyra',
      'text':
          'No he podido abrir el chat. Mira tu conexión: lo vuelvo a '
          'intentar yo sola.',
    });
  }
  final DateTime today = now ?? DateTime.now();
  final Set<String> days = <String>{
    for (final ChatMessage m in messages)
      '${m.at.toLocal().year}-${m.at.toLocal().month}-${m.at.toLocal().day}',
  };
  final int said = messages.where((ChatMessage m) => !m.flyra).length;
  final int flyra = messages.where((ChatMessage m) => m.flyra).length;
  final String c = code ?? '';
  return <String, Object?>{
    'city': city,
    'kind': page?.kind.name,
    'first': page == null ? null : (messages.isEmpty ? 'type' : 'chat'),
    'members': <Map<String, Object?>>[
      for (final ChatMember m in people)
        <String, Object?>{
          'ini': initial(m.name),
          'name': m.name,
          'c': colorOf(m.seat, m.me),
          'me': m.me,
        },
    ],
    'msgs': msgs,
    'plan': plan == null
        ? null
        : <String, Object?>{
            'id': plan.id,
            'title': plan.title,
            'note': plan.note ?? '',
            'planned': plan.planned,
          },
    'typing': typing,
    'rec': rec,
    'day': chatDayLabel(
      messages.isEmpty ? today : messages.last.at.toLocal(),
      today,
    ),
    'code': c,
    'qr': c.isEmpty ? '' : qrPath(c),
    'likes': likes.toList()..sort(),
    'stats': <Map<String, Object?>>[
      <String, Object?>{
        'v': '${days.length}',
        'l': days.length == 1 ? 'día' : 'días',
      },
      <String, Object?>{'v': '$said', 'l': said == 1 ? 'mensaje' : 'mensajes'},
      <String, Object?>{
        'v': '$flyra',
        'l': flyra == 1 ? 'respuesta de Flyra' : 'respuestas de Flyra',
      },
    ],
  };
}

/// La página lista para enseñar.
String chatPageWith(String page, Map<String, Object?> data) =>
    // "<" como \u003c: ningún dato puede cerrar el script.
    page.replaceFirst(chatMarker, jsonEncode(data).replaceAll('<', r'\u003c'));

/// Lo que se le manda a la página sin recargarla.
String chatPushScript(Map<String, Object?> data) =>
    'window.ECLin&&window.ECLin(${jsonEncode(data).replaceAll('<', r'\u003c')})';
