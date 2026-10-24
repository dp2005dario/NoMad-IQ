// La llamada del chat con Flyra al ai-orchestrator (por la puerta de entrada):
//   POST /v1/flyra/chat  {messages, language, place?}  → {reply, remaining_today}
//
// Flyra NO guarda la conversación en el servidor: la app manda en cada
// pregunta los últimos mensajes (como mucho 20) para que Flyra tenga contexto.
// Así el historial vive solo en TU móvil y lo borras cuando quieras.
import 'dart:convert';

import '../../core/api_client.dart';

/// Lo mismo que acepta el servidor (flyra/domain.py). Si cambian allí,
/// cambian aquí.
const int maxTurnsSent = 20;
const int maxQuestionChars = 2000;
const int _maxTotalChars = 12000;

/// Cuántos mensajes guardamos en el móvil (más de los que se envían).
const int maxTurnsKept = 60;

enum ChatRole { user, flyra }

/// Un mensaje del chat: tuyo o de Flyra.
class ChatTurn {
  const ChatTurn(this.role, this.text);

  final ChatRole role;
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{
    'role': role.name,
    'text': text,
  };

  /// Lee un mensaje guardado en el móvil (null si está roto).
  static ChatTurn? tryParse(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final Object? role = raw['role'];
    final Object? text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    return switch (role) {
      'user' => ChatTurn(ChatRole.user, text),
      'flyra' => ChatTurn(ChatRole.flyra, text),
      _ => null,
    };
  }
}

/// La respuesta de Flyra y cuántas preguntas te quedan hoy.
class FlyraReply {
  const FlyraReply(this.text, this.remainingToday);

  final String text;
  final int remainingToday;
}

/// El historial en texto (JSON) para guardarlo en el móvil, y al revés.
String encodeHistory(List<ChatTurn> turns) => jsonEncode(
  turns
      .skip(turns.length > maxTurnsKept ? turns.length - maxTurnsKept : 0)
      .map((ChatTurn t) => t.toJson())
      .toList(),
);

List<ChatTurn> decodeHistory(String? raw) {
  if (raw == null || raw.isEmpty) return <ChatTurn>[];
  try {
    final Object? list = jsonDecode(raw);
    if (list is! List<Object?>) return <ChatTurn>[];
    return list.map(ChatTurn.tryParse).whereType<ChatTurn>().toList();
  } on FormatException {
    return <ChatTurn>[]; // algo raro guardado: se empieza de cero
  }
}

/// Elige qué mensajes se envían: los últimos, sin pasarse de los límites
/// del servidor, y empezando siempre por uno tuyo (no por uno de Flyra).
List<ChatTurn> turnsToSend(List<ChatTurn> history) {
  final List<ChatTurn> picked = <ChatTurn>[];
  int chars = 0;
  for (final ChatTurn turn in history.reversed) {
    final String text = turn.text.length > maxQuestionChars
        ? turn.text.substring(0, maxQuestionChars)
        : turn.text;
    if (picked.length == maxTurnsSent || chars + text.length > _maxTotalChars) {
      break;
    }
    picked.insert(0, ChatTurn(turn.role, text));
    chars += text.length;
  }
  while (picked.isNotEmpty && picked.first.role == ChatRole.flyra) {
    picked.removeAt(0);
  }
  return picked;
}

class FlyraApi {
  const FlyraApi(this._api);

  final ApiClient _api;

  /// Manda el hilo (el último mensaje es tu pregunta) y devuelve la respuesta.
  /// Errores (ApiException): signedOut (invitado), rateLimited (ya no quedan
  /// preguntas hoy), unavailable (Flyra ocupada) o network (sin internet).
  Future<FlyraReply> ask(
    List<ChatTurn> history, {
    required String language,
    String? place,
  }) async {
    final Object? body = await _api.postJson(
      '/v1/flyra/chat',
      <String, Object?>{
        'messages': turnsToSend(history)
            .map((ChatTurn t) => t.toJson())
            .toList(),
        'language': language,
        'place': ?place,
      },
    );
    if (body is! Map<String, Object?>) _bad();
    final Object? reply = body['reply'];
    final Object? remaining = body['remaining_today'];
    if (reply is! String || reply.trim().isEmpty || remaining is! int) _bad();
    return FlyraReply(reply.trim(), remaining);
  }

  static Never _bad() => throw const ApiException(ApiError.unavailable);
}
