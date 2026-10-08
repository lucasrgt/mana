import 'dart:async';

import 'package:moments/src/backend_recipes.dart';
import 'package:moments/src/errors.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => RegExp(text).hasMatch('$e'), 'matches "$text"'));

/// Two Moments, `first` and `second`, sharing the backend base `shared`.
final class Fixture {
  Fixture({Map<String, Object?> initial = const {}, this.prepareBase, this.prepareLeaf})
    : directory = temporary('moments-base-') {
    current = {...initial};
    save();
  }

  final String directory;
  final Future<Map<String, Object?>?> Function(Map<String, Object?> instance)? prepareBase, prepareLeaf;
  late Map<String, Object?> current;
  final events = <String>[];
  final manifest = <String, Object?>{
    'version': 1,
    'properties': {
      'route': {
        'enum': ['/screen'],
      },
    },
    'watch': <Object?>[],
    'moments': <String, Object?>{
      for (final name in ['first', 'second'])
        name: <String, Object?>{
          'projection': {'route': '/screen'},
          'backend': <String, Object?>{'recipe': name, 'base': 'shared'},
        },
    },
  };

  String get manifestFile => p.join(directory, 'manifest.json');
  Map<String, Object?> backend(String name) =>
      ((manifest['moments']! as Map)[name] as Map)['backend'] as Map<String, Object?>;
  void save() => writeJson(manifestFile, manifest);

  BackendRecipes engine() => BackendRecipes(
    manifestFile: manifestFile,
    instance: () => current,
    assertAvailable: () async {},
    acquire: () {
      events.add('lock');
      return () => events.add('unlock');
    },
    startBase: (base) async {
      events.add('checkpoint');
      current = {...current, 'baseRecipe': base, 'phase': 'seeding'};
    },
    commit: (launch, {base, preparedMoment}) async {
      events.add(base != null ? 'persist-base' : 'persist-leaf');
      current = {
        ...current,
        'launch': launch,
        if (base != null) ...{'baseRecipe': base, 'phase': 'ready'},
        'preparedMoment': ?preparedMoment,
      };
    },
    bases: {
      'shared': BaseAdapter(
        prepare: (value) async {
          events.add('base');
          return prepareBase != null
              ? prepareBase!(value)
              : {
                  'launch': {
                    'account': {'password': 'private'},
                    'projection': {'id': 'shared-record'},
                  },
                };
        },
      ),
    },
    recipes: {
      for (final name in ['first', 'second'])
        name: RecipeAdapter(
          prepare: (value) async {
            events.add(name);
            expect(value['phase'], 'ready');
            expect(value['launch'], isNotNull);
            return prepareLeaf?.call(value);
          },
          inspect: (_, _) async {
            events.add('inspect');
            return {'status': 'ready', 'projection': (current['launch'] as Map?)?['projection']};
          },
        ),
    },
  );
}

void main() {
  test('base prepares and persists before selected recipe; switching and restarting reuse it', () async {
    final f = Fixture();
    await f.engine().prepare('first');
    expect(f.events, ['lock', 'checkpoint', 'base', 'persist-base', 'first', 'persist-leaf', 'unlock']);
    expect(f.current['preparedMoment'], {'version': 1, 'moment': 'first', 'recipe': 'first', 'base': 'shared'});
    await f.engine().prepare('second');
    await f.engine().prepare('first');
    expect(f.events.where((x) => x == 'base').length, 1);
    expect(f.events.where((x) => x == 'second').length, 1);
    expect(f.current['baseRecipe'], 'shared');
  });

  test('legacy launch is adopted through adapter without an initial write checkpoint', () async {
    final launch = {
      'projection': {'id': 'old'},
    };
    final f = Fixture(
      initial: {'launch': launch, 'phase': 'ready'},
      prepareBase: (value) async {
        expect(value['launch'], launch);
        return {'launch': launch};
      },
    );
    await f.engine().prepare('second');
    expect(f.current['launch'], launch);
    expect(f.events.contains('checkpoint'), isFalse);
    expect(f.current['baseRecipe'], 'shared');
  });

  test('failed base persists interruption and cannot silently retry its writes', () async {
    final f = Fixture(prepareBase: (_) async => throw const MomentsError('partial base write'));
    await expectLater(f.engine().prepare('first'), throwing('partial base'));
    expect(f.current['phase'], 'seeding');
    expect(f.current['launch'], isNull);
    await expectLater(f.engine().prepare('first'), throwing('reset this local instance'));
    expect(f.events.where((x) => x == 'base').length, 1);
    expect(f.events.contains('first'), isFalse);
    expect(f.events.where((x) => x == 'lock').length, f.events.where((x) => x == 'unlock').length);
  });

  test('leaf failure keeps successful base and retry does not seed it again', () async {
    var fails = true;
    final f = Fixture(
      prepareLeaf: (_) async {
        if (fails) throw const MomentsError('leaf unavailable');
        return null;
      },
    );
    await expectLater(f.engine().prepare('first'), throwing('leaf unavailable'));
    fails = false;
    await f.engine().prepare('first');
    expect(f.current['phase'], 'ready');
    expect(f.events.where((x) => x == 'base').length, 1);
  });

  test('inspection only observes; missing, malformed and foreign bases fail before any preparation', () async {
    final unprepared = Fixture();
    await expectLater(unprepared.engine().inspect('first'), throwing('has not been prepared'));
    expect(unprepared.events, isEmpty);
    final f = Fixture(
      initial: {
        'baseRecipe': 'shared',
        'phase': 'ready',
        'launch': {'projection': <String, Object?>{}},
      },
    );
    final result = await f.engine().inspect('first');
    expect(result['base'], 'shared');
    expect(f.events, ['inspect']);
    for (final base in ['../shell', 'unknown', null]) {
      f.backend('first')['base'] = base;
      f.save();
      await expectLater(f.engine().prepare('first'), throwing('Invalid|not registered'), reason: '$base');
    }
    expect(f.events, ['inspect']);
    final foreign = Fixture(initial: {'baseRecipe': 'another', 'launch': <String, Object?>{}, 'phase': 'ready'});
    expect(() => foreign.engine().declared('first'), throwing('different backend base'));
    expect(foreign.events, isEmpty);
  });

  test('while base preparation runs another open cannot enter or inspect half-prepared data', () async {
    final entered = Completer<void>(), held = Completer<void>();
    final f = Fixture(
      prepareBase: (_) async {
        entered.complete();
        await held.future;
        return {
          'launch': {'projection': <String, Object?>{}},
        };
      },
    );
    final engine = f.engine();
    final opening = engine.prepare('first');
    await entered.future;
    await expectLater(engine.prepare('second'), throwing('already running'));
    await expectLater(engine.inspect('first'), throwing('in progress'));
    held.complete();
    await opening;
    expect(f.events.contains('second'), isFalse);
  });
}
