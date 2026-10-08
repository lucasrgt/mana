import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show recipeToken;

import 'backend_recipes.dart';
import 'errors.dart';

/// Backend recipes implemented by the app itself (`Moments.Recipe` modules
/// served by `Moments.Recipes`). The engine keeps the returned launch
/// privately; inspect sends it back with the reported projection and checks
/// the observed one.
Map<String, RecipeAdapter> elixirRecipes(Iterable<String> names, {String path = '/__moments'}) {
  Future<Map<String, Object?>> call(Map<String, Object?> instance, String name, String operation, Object body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(Uri.parse(instance['apiUrl']! as String).resolve('$path/$name/$operation'));
      request.headers
        ..set('content-type', 'application/json')
        ..set('authorization', 'Bearer ${recipeToken(instance)}');
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(const Duration(seconds: 15));
      final text = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw MomentsError('Recipe $name $operation failed (${response.statusCode})');
      }
      final value = jsonDecode(text);
      if (value is! Map) throw MomentsError('Recipe $name returned no object');
      return value.cast();
    } finally {
      client.close(force: true);
    }
  }

  return {
    for (final name in names)
      name: RecipeAdapter(
        prepare: (instance) async => {
          'launch': await call(instance, name, 'prepare', {
            'context': {'apiUrl': instance['apiUrl'], 'webUrl': instance['webUrl']},
          }),
        },
        inspect: (instance, context) async => {
          'status': 'ready',
          'source': 'recipe:$name',
          'observedAt': DateTime.now().toUtc().toIso8601String(),
          'projection': await call(instance, name, 'observe', {
            'launch': instance['launch'] ?? <String, Object?>{},
            'projection': context['projection'] ?? <String, Object?>{},
          }),
        },
      ),
  };
}

/// `fill` steps read only the inputs a recipe declared in its launch.
String recipeInput(Map<String, Object?> instance, String reference) {
  final value = ((instance['launch'] as Map?)?['inputs'] as Map?)?[reference];
  if (value is! String) throw MomentsError('Recipe input not prepared: $reference');
  return value;
}
