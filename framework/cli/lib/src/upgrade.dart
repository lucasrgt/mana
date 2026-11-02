import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import 'elixir.dart';
import 'failure.dart';
import 'graph.dart';
import 'manifest.dart';
import 'toolchain.dart';

const _runtime = 'a verb chosen at runtime';

/// The keys the Flutter apps of [roots] place on the control a
/// `VerbGate(verb: XVerbs.y, ...)` draws (its own `key:` or the one on the
/// widget its `builder` returns), as `mix mana.upgrade verb_steps` reads them:
/// `keys` maps a key to its one verb, `conflicts` a key to every verb that
/// places it (a verb not written as `XVerbs.y` counts as chosen at runtime).
Map<String, Object?> verbKeys(String root, Iterable<String> roots) {
  final placed = <String, Set<String>>{};
  for (final file in screenFiles(root, roots)) {
    final unit = parseString(
      content: file.readAsStringSync(),
      path: file.path,
      throwIfDiagnostics: false,
    ).unit;
    final gates = _VerbGates();
    unit.accept(gates);
    for (final (:verb, :keys) in gates.found) {
      for (final key in keys) {
        (placed[key] ??= {}).add(verb ?? _runtime);
      }
    }
  }
  final keys = placed.keys.toList()..sort();
  return {
    'version': 1,
    'keys': {
      for (final key in keys)
        if (placed[key]!.length == 1 && placed[key]!.single != _runtime)
          key: placed[key]!.single,
    },
    'conflicts': {
      for (final key in keys)
        if (placed[key]!.length > 1 || placed[key]!.single == _runtime)
          key: placed[key]!.toList()..sort(),
    },
  };
}

final class _VerbGates extends RecursiveAstVisitor<void> {
  final found = <({String? verb, List<String> keys})>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.target == null && node.methodName.name == 'VerbGate') {
      _gate(node.argumentList);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (node.constructorName.type.name.lexeme == 'VerbGate' &&
        node.constructorName.name == null) {
      _gate(node.argumentList);
    }
    super.visitInstanceCreationExpression(node);
  }

  void _gate(ArgumentList arguments) {
    final named = {
      for (final argument in arguments.arguments.whereType<NamedArgument>())
        argument.name.lexeme: argument.argumentExpression,
    };
    final verb = switch (named['verb']) {
      PrefixedIdentifier(:final prefix, :final identifier)
          when prefix.name.endsWith('Verbs') && prefix.name != 'Verbs' =>
        verbReference(
          prefix.name.substring(0, prefix.name.length - 'Verbs'.length),
          identifier.name,
        ),
      _ => null,
    };
    final keys = [
      ?_key(named['key']),
      for (final control in _returned(named['builder'])) ?_keyOf(control),
    ];
    if (keys.isNotEmpty) found.add((verb: verb, keys: keys));
  }
}

/// What a builder closure returns: its expression body, or the `return`s of
/// its block (not those of closures inside it), both arms of a conditional.
Iterable<Expression> _returned(Expression? builder) sync* {
  if (builder is! FunctionExpression) return;
  final body = builder.body;
  final returned = switch (body) {
    ExpressionFunctionBody(:final expression) => [expression],
    BlockFunctionBody(:final block) => [
      for (final statement in block.statements)
        if (statement case ReturnStatement(:final expression?)) expression,
    ],
    _ => const <Expression>[],
  };
  for (final expression in returned) {
    yield* _arms(expression);
  }
}

Iterable<Expression> _arms(Expression expression) sync* {
  switch (expression) {
    case ConditionalExpression(:final thenExpression, :final elseExpression):
      yield* _arms(thenExpression);
      yield* _arms(elseExpression);
    case ParenthesizedExpression(:final expression):
      yield* _arms(expression);
    default:
      yield expression;
  }
}

String? _keyOf(Expression control) {
  final arguments = switch (control) {
    MethodInvocation(:final argumentList) => argumentList.arguments,
    InstanceCreationExpression(:final argumentList) => argumentList.arguments,
    _ => const <Argument>[],
  };
  for (final argument in arguments.whereType<NamedArgument>()) {
    if (argument.name.lexeme == 'key') return _key(argument.argumentExpression);
  }
  return null;
}

/// The string of `Key('x')` / `ValueKey('x')` (const or not), when it is
/// written out: an interpolated key cannot be matched to a step.
String? _key(Expression? key) {
  final (name, arguments) = switch (key) {
    MethodInvocation(target: null, :final methodName, :final argumentList) => (
      methodName.name,
      argumentList.arguments,
    ),
    InstanceCreationExpression(:final constructorName, :final argumentList)
        when constructorName.name == null =>
      (constructorName.type.name.lexeme, argumentList.arguments),
    _ => (null, const <Argument>[]),
  };
  if (name != 'Key' && name != 'ValueKey') return null;
  return switch (arguments) {
    [SimpleStringLiteral(:final value)] => value,
    _ => null,
  };
}

/// The `mix mana.upgrade` arguments, run in the framework's `ash/upgrade`
/// project ([project]): paths are given relative to it.
List<String> upgradeArguments({
  required String project,
  required String codemod,
  required List<String> paths,
  String? mapping,
  bool dryRun = false,
}) => [
  'mana.upgrade',
  codemod,
  for (final path in paths) p.relative(p.absolute(path), from: project),
  if (mapping != null) ...[
    '--mapping',
    p.relative(p.absolute(mapping), from: project),
  ],
  if (dryRun) '--dry-run',
];

/// `mana upgrade verb-steps | timed-rules [paths...] [--dry-run]`: the
/// codemods of the framework's `mana_upgrade` over the backend's code (its
/// `lib` by default), so the app needs no dependency on it. `verb-steps`
/// first scans the frontends for the keys `VerbGate`s place.
Future<void> upgrade(String root, List<String> arguments) async {
  final dryRun = arguments.contains('--dry-run');
  final rest = [...arguments.where((a) => a != '--dry-run')];
  final codemod = switch (rest.firstOrNull) {
    'verb-steps' => 'verb_steps',
    'timed-rules' => 'timed_rules',
    _ => throw const ManaFailure(
      'Use mana upgrade verb-steps | timed-rules [paths...] [--dry-run]',
    ),
  };
  final products = productPaths(root, validate(readManifest(root)));
  final backends = {for (final product in products) ?product.backend};
  if (backends.length != 1) {
    throw ManaFailure(
      'mana upgrade needs exactly one backend in mana.toml; found ${backends.length}',
    );
  }
  final backend = p.join(root, backends.single);
  final project = p.join(frameworkRoot(), 'ash', 'upgrade');
  File? mapping;
  if (codemod == 'verb_steps') {
    mapping = File(p.join(backend, '_build', 'mana-verb-steps.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode(
          verbKeys(root, [for (final product in products) ...product.frontend]),
        ),
      );
  }
  try {
    if (!Directory(p.join(project, 'deps', 'sourceror')).existsSync()) {
      await mix(project, ['deps.get']);
    }
    await mix(
      project,
      upgradeArguments(
        project: project,
        codemod: codemod,
        paths: rest.length > 1 ? rest.sublist(1) : [p.join(backend, 'lib')],
        mapping: mapping?.path,
        dryRun: dryRun,
      ),
    );
  } finally {
    if (mapping != null && mapping.existsSync()) mapping.deleteSync();
  }
}
