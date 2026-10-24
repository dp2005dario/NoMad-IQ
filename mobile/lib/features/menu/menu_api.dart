// El traductor de cartas de restaurante: el móvil manda las líneas que leyó
// de la foto y el servidor (Flyra) devuelve los platos explicados.
//
// La foto NUNCA sale del teléfono: solo el texto, y el servidor no lo guarda.
import '../../core/api_client.dart';

/// Un plato de la carta, ya explicado.
class Dish {
  const Dish({
    required this.original,
    required this.name,
    this.description = '',
    this.allergens = '',
    this.orderPhrase = '',
    this.orderSounds = '',
    this.price = '',
  });

  /// Como está en la carta ("親子丼").
  final String original;

  /// Qué es, en tu idioma.
  final String name;

  /// De qué va; vacío si Flyra no lo sabe (mejor callar que inventar).
  final String description;

  /// Aviso de alérgenos frecuentes; vacío si no hay.
  final String allergens;

  /// Cómo pedirlo en el idioma del sitio, y cómo suena.
  final String orderPhrase;
  final String orderSounds;

  /// El precio tal y como aparece en la carta.
  final String price;

  static Dish? parse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final Object? original = json['original'];
    final Object? name = json['name'];
    if (original is! String ||
        name is! String ||
        original.isEmpty ||
        name.isEmpty) {
      return null;
    }
    String text(String key) {
      final Object? value = json[key];
      return value is String ? value : '';
    }

    return Dish(
      original: original,
      name: name,
      description: text('description'),
      allergens: text('allergens'),
      orderPhrase: text('order_phrase'),
      orderSounds: text('order_sounds'),
      price: text('price'),
    );
  }
}

class MenuTranslation {
  const MenuTranslation({required this.dishes, required this.remainingToday});

  final List<Dish> dishes;

  /// Cartas que te quedan hoy (el cupo gratuito).
  final int remainingToday;
}

class MenuApi {
  const MenuApi(this._api);

  final ApiClient _api;

  /// Traduce las líneas de una carta. [language] es el idioma de la app y
  /// [placeLanguage] el del sitio (para el "pídelo así").
  Future<MenuTranslation> translate({
    required List<String> lines,
    required String language,
    String? placeLanguage,
  }) async {
    final Object? json = await _api.postJson(
      '/v1/menu/translate',
      <String, Object?>{
        'lines': lines,
        'language': language,
        'place_language': ?placeLanguage,
      },
    );
    if (json is! Map<String, Object?>) {
      throw const ApiException(ApiError.unavailable);
    }
    final Object? items = json['dishes'];
    final Object? left = json['remaining_today'];
    return MenuTranslation(
      dishes: <Dish>[
        if (items is List<Object?>)
          for (final Object? item in items) ?Dish.parse(item),
      ],
      remainingToday: left is int && left >= 0 ? left : 0,
    );
  }
}
