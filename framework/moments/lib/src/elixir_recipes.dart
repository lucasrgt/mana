import 'dart:convert';
import 'dart:io';

import 'package:mana/runtime.dart' show recipeToken;

import 'backend_recipes.dart';
import 'effects.dart' show recordPreparation;
import 'errors.dart';

/// One call to the app's `Moments.Recipes` plug: `POST <path>/<name>/<operation>`
/// with the sandbox's recipe token.
Future<Map<String, Object?>> callRecipe(
  Map<String, Object?> instance,
  String name,
  String operation,
  Object body, {
  String path = '/__moments',
}) async => (await _post(instance, name, operation, body, path: path))!;

/// [callRecipe], or null when the plug does not know [operation] (404): a
/// backend on an older `Moments.Recipes`.
Future<Map<String, Object?>?> _post(
  Map<String, Object?> instance,
  String name,
  String operation,
  Object body, {
  String path = '/__moments',
  bool optional = false,
  void Function(HttpHeaders headers)? answered,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.postUrl(Uri.parse(instance['apiUrl']! as String).resolve('$path/$name/$operation'));
    request.headers
      ..set('content-type', 'application/json')
      ..set('authorization', 'Bearer ${recipeToken(instance)}');
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await utf8.decoder.bind(response).join().timeout(const Duration(seconds: 15));
    if (optional && response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw MomentsError('Recipe $name $operation failed (${response.statusCode})');
    }
    answered?.call(response.headers);
    final value = jsonDecode(text);
    if (value is! Map) throw MomentsError('Recipe $name returned no object');
    return value.cast();
  } finally {
    client.close(force: true);
  }
}

/// Backend recipes implemented by the app itself (`Moments.Recipe` modules
/// served by `Moments.Recipes`). The engine keeps the returned launch
/// privately; inspect sends it back with the reported projection and checks
/// the observed one. With [preparations], each preparation's answer of the
/// actions it ran is kept there per recipe, for `moments affected`.
Map<String, RecipeAdapter> elixirRecipes(Iterable<String> names, {String path = '/__moments', String? preparations}) {
  Future<Map<String, Object?>> call(Map<String, Object?> instance, String name, String operation, Object body) =>
      callRecipe(instance, name, operation, body, path: path);
  Future<Map<String, Object?>> prepare(Map<String, Object?> instance, String name, Object body) async => (await _post(
    instance,
    name,
    'prepare',
    body,
    path: path,
    answered: preparations == null
        ? null
        : (headers) => recordPreparation(preparations, name, headers.value('x-mana-preparation')),
  ))!;
  Map<String, Object?> context(Map<String, Object?> instance) => {
    'apiUrl': instance['apiUrl'],
    'webUrl': instance['webUrl'],
  };

  return {
    for (final name in names)
      name: RecipeAdapter(
        prepare: (instance) async => {
          'launch': await prepare(instance, name, {'context': context(instance)}),
        },
        prepareFrom: (instance, parent, {snapshot}) async => {
          'launch': await prepare(instance, name, {
            'context': {...context(instance), 'parent': parent},
            if (snapshot != null) 'from': {'snapshot': snapshot},
          }),
        },
        describe: (instance, {snapshot}) async {
          final answer = await _post(instance, name, 'describe', {'snapshot': ?snapshot}, path: path, optional: true);
          if (answer == null) return null;
          return (
            isolated: answer['dataScope'] == true,
            digest: answer['recipe'] as String?,
            snapshot: answer['snapshot'] == true,
          );
        },
        capture: (instance, launch, snapshot) =>
            call(instance, name, 'capture', {'launch': launch, 'snapshot': snapshot}),
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
