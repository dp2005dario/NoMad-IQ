// Las llamadas del chat del viaje al ai-orchestrator:
//   GET  /v1/group-negotiations/{id}/chat?after=N  → lo nuevo (sin after: lo último)
//   POST /v1/group-negotiations/{id}/chat          → escribir ("@Flyra ..." = pregunta a Flyra)
//   PUT  /v1/group-negotiations/{id}/chat/kind     → tipo de viaje (Flyra se adapta)
//   PUT  /v1/group-negotiations/{id}/chat/me       → tu nombre en el chat
//
// Igual que en el resto de la app, se revisa todo lo que llega: un mensaje
// con forma rara se ignora en vez de romper la pantalla.
import '../../core/api_client.dart';

/// Tope de letras por mensaje (el mismo que el servidor).
const int maxChatText = 2000;

/// El tipo de viaje. "Solo" no está: eso es el chat privado con Flyra.
enum ChatTripKind { friends, couple, family }

class ChatMember {
  const ChatMember({
    required this.seat,
    required this.name,
    required this.me,
    required this.active,
  });

  final int seat;
  final String name;
  final bool me;

  /// false = borró su cuenta (su asiento queda anónimo).
  final bool active;

  static ChatMember? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? seat = json['seat'];
    final Object? name = json['name'];
    if (seat is! int || name is! String) return null;
    return ChatMember(
      seat: seat,
      name: name,
      me: json['me'] == true,
      active: json['active'] != false,
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.name,
    required this.text,
    required this.at,
    required this.mine,
    required this.flyra,
    this.seat,
    this.photoUrl,
  });

  /// Foto de quien escribe, si viene con su perfil.
  final String? photoUrl;

  final int id;

  /// null = Flyra.
  final int? seat;
  final String name;
  final String text;
  final DateTime at;
  final bool mine;
  final bool flyra;

  static ChatMessage? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? id = json['id'];
    final Object? name = json['name'];
    final Object? text = json['text'];
    final DateTime? at = DateTime.tryParse('${json['at']}');
    if (id is! int || name is! String || text is! String || at == null) {
      return null;
    }
    final Object? seat = json['seat'];
    return ChatMessage(
      id: id,
      seat: seat is int ? seat : null,
      name: name,
      text: text,
      at: at,
      mine: json['mine'] == true,
      flyra: json['flyra'] == true,
      photoUrl: json['photo_url'] is String ? json['photo_url'] as String : null,
    );
  }
}

class ChatPage {
  const ChatPage({
    required this.title,
    required this.kind,
    required this.members,
    required this.messages,
  });

  final String title;
  final ChatTripKind kind;
  final List<ChatMember> members;
  final List<ChatMessage> messages;

  static ChatPage parse(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    final Object? title = json['title'];
    final Object? members = json['members'];
    final Object? messages = json['messages'];
    if (title is! String || members is! List<Object?> || messages is! List) {
      throw const ApiException(ApiError.unavailable);
    }
    return ChatPage(
      title: title,
      kind: ChatTripKind.values.firstWhere(
        (ChatTripKind k) => k.name == json['kind'],
        orElse: () => ChatTripKind.friends,
      ),
      members: <ChatMember>[
        for (final Object? m in members) ?ChatMember.parse(m),
      ],
      messages: <ChatMessage>[
        for (final Object? m in messages) ?ChatMessage.parse(m),
      ],
    );
  }
}

/// Por qué Flyra no contestó (el mensaje sí se envió).
enum FlyraTrouble { quota, busy }

class Posted {
  const Posted({required this.messages, this.flyra});

  /// El tuyo y, si llamaste a Flyra y pudo, su respuesta.
  final List<ChatMessage> messages;
  final FlyraTrouble? flyra;

  static Posted parse(Object? json) {
    if (json is! Map<String, Object?> || json['messages'] is! List) {
      throw const ApiException(ApiError.unavailable);
    }
    return Posted(
      messages: <ChatMessage>[
        for (final Object? m in json['messages']! as List<Object?>)
          ?ChatMessage.parse(m),
      ],
      flyra: switch (json['flyra_error']) {
        'quota' => FlyraTrouble.quota,
        'busy' => FlyraTrouble.busy,
        _ => null,
      },
    );
  }
}

/// ¿Va para Flyra? (empieza por "@Flyra", como en el servidor).
bool mentionsFlyra(String text) =>
    RegExp(r'^\s*@flyra\b', caseSensitive: false).hasMatch(text);

class GroupChatApi {
  const GroupChatApi(this._api);

  final ApiClient _api;

  String _base(String tripId) =>
      '/v1/group-negotiations/${Uri.encodeComponent(tripId)}/chat';

  /// Sin [after]: los últimos mensajes. Con [after]: solo los nuevos.
  Future<ChatPage> read(String tripId, {int? after}) async => ChatPage.parse(
    await _api.getJson(
      _base(tripId),
      query: after == null ? null : <String, String>{'after': '$after'},
    ),
  );

  Future<Posted> send(String tripId, String text, String language) async =>
      Posted.parse(
        await _api.postJson(_base(tripId), <String, Object?>{
          'text': text.length > maxChatText
              ? text.substring(0, maxChatText)
              : text,
          'language': language,
        }),
      );

  Future<void> setKind(String tripId, ChatTripKind kind) async => _api.putJson(
    '${_base(tripId)}/kind',
    <String, Object?>{'kind': kind.name},
  );

  Future<void> setName(String tripId, String? name) async =>
      _api.putJson('${_base(tripId)}/me', <String, Object?>{'name': name});
}
