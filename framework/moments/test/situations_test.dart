import 'dart:convert';
import 'dart:io';

import 'package:mana/runtime.dart' show uuidV4;
import 'package:moments/src/cli.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/format.dart';
import 'package:moments/src/protocol.dart';
import 'package:moments/src/situations.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// The backend side of `Moments.Recipes` in memory: each data scope is a
/// database of tables and history; every evaluation generates fresh ids and
/// times, as a real recipe does.
final class Backend {
  final scopes = <String, ({Map<String, int> tables, List<Map<String, Object?>> history})>{};
  final snapshots = <String, ({Map<String, int> tables, List<Map<String, Object?>> history})>{};
  final calls = <String>[];
  var digest = 'aaaa', replays = 0;
  var failReplay = false;

  String _scope() => uuidV4().substring(0, 12);

  Map<String, Object?> _entry(String text) => {
    'log': 'MyApp.History.Entry',
    'subject': 'note:${uuidV4()}',
    'action': 'create',
    'verb': null,
    'actorKind': 'system',
    'outcome': 'done',
    'before': <String, Object?>{},
    'after': {'text': text, 'id': uuidV4(), 'inserted_at': DateTime.now().toUtc().toIso8601String()},
  };

  /// What a continuation of [scope] does: one more row, one more entry.
  void write(String scope) {
    final current = scopes[scope]!;
    current.tables.update('notes', (n) => n + 1);
    current.history.add(_entry('later'));
  }

  ({Map<String, int> tables, List<Map<String, Object?>> history}) _copy(
    ({Map<String, int> tables, List<Map<String, Object?>> history}) origin,
  ) => (
    tables: {...origin.tables},
    history: [for (final entry in origin.history) jsonDecode(jsonEncode(entry)) as Map<String, Object?>],
  );

  Future<Map<String, Object?>> call(String recipe, String operation, Map<String, Object?> body) async {
    calls.add('$recipe/$operation');
    final scope = (body['launch'] as Map?)?['dataScope'] as String?;
    switch (operation) {
      case 'describe':
        return {'dataScope': recipe != 'shared', 'recipe': digest, 'snapshot': snapshots.containsKey(body['snapshot'])};
      case 'capture':
        snapshots[body['snapshot']! as String] = _copy(scopes[scope]!);
        return {'snapshot': body['snapshot']};
      case 'prepare':
        if (recipe == 'shared') return {'route': '/'};
        final id = _scope();
        if ((body['from'] as Map?)?['snapshot'] case final String snapshot) {
          // A child: its parent's situation, one more note on top.
          scopes[id] = _copy(snapshots[snapshot]!);
          write(id);
          return {'route': '/notes/archived', 'dataScope': id};
        }
        scopes[id] = (tables: {'notes': 1, 'users': 2}, history: [_entry('first')]);
        return {
          'route': '/notes',
          'account': {'password': 'p'},
          'dataScope': id,
        };
      case 'replay':
        if (failReplay) throw StateError('replay failed');
        replays++;
        final id = _scope();
        final moves = ((body['trace']! as Map)['moves']! as List).length;
        scopes[id] = (tables: {'notes': moves}, history: [for (var i = 0; i < moves; i++) _entry('move $i')]);
        return {'dataScope': id};
      case 'fork':
        final origin = scopes[scope]!;
        return {
          'launches': [
            for (var i = 0; i < (body['n']! as int); i++)
              () {
                final id = _scope();
                scopes[id] = (
                  tables: {...origin.tables},
                  history: [for (final entry in origin.history) jsonDecode(jsonEncode(entry)) as Map<String, Object?>],
                );
                return {...(body['launch']! as Map).cast<String, Object?>(), 'dataScope': id};
              }(),
          ],
        };
      case 'project':
        final found = scopes[scope]!;
        return {'recipe': recipe == explorations ? null : digest, 'tables': found.tables, 'history': found.history};
      case 'observe':
        return {
          'notes': scopes[scope]!.tables['notes'],
          'firstNote': uuidV4(),
          'refreshedAt': DateTime.now().toUtc().toIso8601String(),
          'sessionToken': uuidV4(),
        };
    }
    throw StateError('unexpected $operation');
  }
}

({String project, Backend backend, Situations situations, String Function() version, void Function(String) setVersion})
fixture() {
  final project = temporary('moments-situations-');
  writeJson(p.join(project, 'moments/manifest.json'), {
    'version': 3,
    'protocol': protocol,
    'watch': <Object?>[],
    'properties': <String, Object?>{},
    'moments': {
      'notes': {
        'description': 'Notes',
        'backend': {'recipe': 'notes'},
      },
      'archived': {
        'from': 'notes',
        'description': 'One archived',
        'backend': {'recipe': 'notes'},
      },
      'shared': {
        'description': 'Shared data',
        'backend': {'recipe': 'shared'},
      },
    },
  });
  final backend = Backend();
  var version = 'v1';
  final situations = Situations(project: project, call: backend.call, backendVersion: () => version);
  return (
    project: project,
    backend: backend,
    situations: situations,
    version: () => version,
    setVersion: (next) => version = next,
  );
}

String scopeOf(String project, String id) {
  final file = readJson(p.join(project, 'moments/.backend/situations.json'))! as Map;
  return (((file['situations']! as Map)[id]! as Map)['launch']! as Map)['dataScope']! as String;
}

String exploration(String root, {List<Object?>? moves}) {
  final file = p.join(root, 'counterexample.json');
  writeJson(file, {
    'property': 'refusal_enforced',
    'resource': 'MyApp.Booking',
    'verb': 'pay',
    'actor': 'traveler',
    'detail': 'a cancelled booking still takes a payment',
    'moves':
        moves ??
        [
          {'kind': 'start', 'actor': 'traveler', 'verb': 'book', 'resource': 'MyApp.Booking', 'params': {}},
          {
            'kind': 'verb',
            'actor': 'traveler',
            'verb': 'cancel',
            'ref': ['MyApp.Booking', 0],
          },
          {
            'kind': 'clock',
            'by': [16, 'minute'],
          },
        ],
  });
  return file;
}

/// A backend beside the app whose Ash declaration lists explorations in
/// [directory] (from the manifest): `sync` exports every trace saved there as
/// a Moment, as `mix moments.export` does.
({String backend, Situations situations, int Function() exports}) declareExplorations(
  ({
    String project,
    Backend backend,
    Situations situations,
    String Function() version,
    void Function(String) setVersion,
  })
  f, {
  String? directory,
}) {
  final backend = '${f.project}-backend';
  Directory(backend).createSync(recursive: true);
  addTearDown(() {
    if (Directory(backend).existsSync()) Directory(backend).deleteSync(recursive: true);
  });
  writeJson(p.join(f.project, 'moments/sources.json'), {
    'version': 1,
    'roots': [
      {'name': 'server', 'path': '../${p.basename(backend)}'},
    ],
  });
  final manifestFile = p.join(f.project, 'moments/manifest.json');
  final relative = directory ?? '../../${p.basename(backend)}/priv/moments/explorations';
  final manifest = (readJson(manifestFile)! as Map).cast<String, Object?>();
  writeJson(manifestFile, {
    ...manifest,
    'explorations': [
      {
        'domain': 'MyApp.Bookings',
        'directory': relative,
        'resources': ['MyApp.Booking'],
      },
    ],
  });
  var exports = 0;
  Future<void> sync() async {
    exports++;
    final current = (readJson(manifestFile)! as Map).cast<String, Object?>();
    final folder = Directory(p.normalize(p.join(p.dirname(manifestFile), relative)));
    writeJson(manifestFile, {
      ...current,
      'moments': {
        ...(current['moments']! as Map),
        for (final file in folder.listSync().whereType<File>())
          p.basenameWithoutExtension(file.path): {
            'description': 'Found by Mana.Explore',
            'checks': [
              {'name': 'refusal_enforced', 'kind': 'property'},
            ],
            'steps': <Object?>[],
            'exploration': {
              'file': p.relative(file.path, from: p.dirname(manifestFile)),
              'sha256': '0' * 64,
              'trace': readJson(file.path),
            },
          },
      },
    });
  }

  return (
    backend: backend,
    situations: Situations(project: f.project, call: f.backend.call, backendVersion: f.version, sync: sync),
    exports: () => exports,
  );
}

void main() {
  test('normalization hides generated ids, times and secrets, numbering ids by first appearance', () {
    const a = '0b5f8c1e-1111-4111-8111-111111111111', b = '0b5f8c1e-2222-4222-8222-222222222222';
    expect(
      normalize({
        'subject': 'note:$a',
        'owner': b.toUpperCase(),
        'again': a,
        'at': '2026-11-01T08:00:00.123Z',
        'apiToken': 'abc',
        'items': [1, 'x'],
      }),
      {
        'again': '<id:1>',
        'apiToken': '<secret>',
        'at': '<time>',
        'items': [1, 'x'],
        'owner': '<id:2>',
        'subject': 'note:<id:1>',
      },
    );
  });

  group('independentFork', () {
    test('N forks are N databases cloned from one prepared situation; writing one leaves the others', () async {
      final f = fixture();
      final result = await f.situations.fork('notes', 2);
      final [a, b] = [for (final fork in (result['forks']! as List).cast<Map>()) fork['id']! as String];
      final origin = (result['origin']! as Map)['id']! as String;
      expect([origin, a, b], ['notes@1', 'notes@2', 'notes@3']);
      expect({scopeOf(f.project, origin), scopeOf(f.project, a), scopeOf(f.project, b)}, hasLength(3));
      expect(f.backend.calls.where((c) => c == 'notes/prepare'), hasLength(1), reason: 'prepared once, cloned');
      f.backend.write(scopeOf(f.project, a));
      final changed = await f.situations.diff(a, b);
      expect(changed['status'], 'different');
      expect(((changed['layers']! as Map)['data']! as Map)['tables'], {
        'notes': [2, 1],
      });
      expect(((((changed['layers']! as Map)['data']! as Map)['history']! as Map)['onlyA']! as List), hasLength(1));
      expect((await f.situations.diff(b, origin))['status'], 'same', reason: 'the other fork never saw the write');
      expect(jsonEncode(result), isNot(contains('password')), reason: 'launches stay in the private file');
    });

    test('a Moment prepared on the shared database or a bad count is refused', () async {
      final f = fixture();
      await expectLater(f.situations.fork('shared', 2), throwing('data_scope: true'));
      await expectLater(f.situations.fork('notes', 17), throwing('1 to 16'));
      expect(parseArgs(['fork', 'notes', '-n', '3']).count, 3);
      for (final args in [
        ['fork', 'notes'],
        ['fork', 'notes', '-n', '0'],
        ['fork', 'notes', '-n', '17'],
        ['open', 'notes', '-n', '2'],
      ]) {
        expect(() => parseArgs(args), throwing('-n'), reason: '$args');
      }
    });
  });

  group('wholeSituationSnapshot', () {
    test('a fork carries every table and the whole history of the situation, not a chosen subset', () async {
      final f = fixture();
      final result = await f.situations.fork('notes', 1);
      final fork = ((result['forks']! as List).single as Map)['id']! as String;
      final origin = (result['origin']! as Map)['id']! as String;
      final same = await f.situations.diff(origin, fork);
      expect(same['status'], 'same');
      final scope = f.backend.scopes[scopeOf(f.project, fork)]!;
      expect(scope.tables, {'notes': 1, 'users': 2});
      expect(scope.history, hasLength(1));
    });
  });

  group('normalizedVersionComparison', () {
    test('diff(a, a) is empty, and two evaluations differing only in ids and times are the same', () async {
      final f = fixture();
      final self = await f.situations.diff('notes', 'notes');
      expect(self['status'], 'same');
      expect(f.backend.calls.where((c) => c == 'notes/prepare'), hasLength(1));
      final twice = await f.situations.diff('notes', 'notes@1');
      expect(twice['status'], 'same', reason: '${jsonEncode(twice['layers'])}');
      expect(twice['comparison'], 'same-version');
      expect(twice['normalization'], normalization);
    });

    test('across backend versions with the same recipe it compares; a changed recipe is declared redefined', () async {
      final f = fixture();
      final before = (await f.situations.prepare('notes'))['id']! as String;
      f.setVersion('v2');
      final across = await f.situations.diff(before, 'notes');
      expect(across['comparison'], 'across-versions');
      expect(across['redefined'], false);
      f.backend.digest = 'bbbb';
      final redefined = await f.situations.diff(before, 'notes');
      expect(redefined['redefined'], true);
      expect(redefined['meaning'], contains('not changed behaviour'));
      await expectLater(f.situations.diff('notes', 'shared'), throwing('data_scope'));
    });

    test('a situation whose scope is gone is compared by the projection it had when made', () async {
      final f = fixture();
      final id = (await f.situations.prepare('notes'))['id']! as String;
      f.backend.scopes.clear();
      Future<Map<String, Object?>> failing(String recipe, String operation, Map<String, Object?> body) async =>
          operation == 'project'
          ? throw const MomentsError('Recipe notes project failed (422)')
          : f.backend.call(recipe, operation, body);
      final later = Situations(project: f.project, call: failing, backendVersion: f.version);
      final result = await later.diff(id, id);
      expect((result['a']! as Map)['source'], 'captured');
      expect(result['status'], 'same');
    });
  });

  group('traceFromRoot', () {
    test('a trace walks the declared path from the root and every recorded change in order', () async {
      final f = fixture();
      expect(f.situations.path('archived'), ['notes', 'archived']);
      final trace = await f.situations.trace('notes');
      expect(trace['path'], ['notes']);
      expect(trace['root'], contains('empty'));
      final steps = (trace['steps']! as List).cast<Map>();
      expect(steps.single['step'], 1);
      expect(steps.single['subject'], matches(RegExp(r'^note:<id:\d+>$')));
      expect(steps.single['action'], 'create');
      expect((steps.single['changes']! as Map)['text'], [null, 'first']);
      expect((steps.single['changes']! as Map)['inserted_at'], [null, '<time>']);
      expect(trace['tables'], {'notes': 1, 'users': 2});
      expect((await f.situations.trace('archived'))['path'], ['notes', 'archived']);
    });
  });

  group('parentMaterialization', () {
    test(
      "a child's situation is cloned from its parent's snapshot; forks of it never prepare the parent again",
      () async {
        final f = fixture();
        final forked = await f.situations.fork('archived', 2);
        final ids = [for (final fork in (forked['forks']! as List).cast<Map>()) fork['id']! as String];
        expect(f.backend.calls.where((c) => c == 'notes/capture'), hasLength(1));
        expect(f.backend.scopes[scopeOf(f.project, ids.first)]!.tables, {'notes': 2, 'users': 2});
        final trace = await f.situations.trace('archived');
        expect(
          [for (final step in (trace['steps']! as List).cast<Map>()) (step['changes']! as Map)['text']?.last],
          ['first', 'later'],
          reason: "the parent's history first, then the child's",
        );
        expect(
          f.backend.calls.where((c) => c == 'notes/prepare'),
          hasLength(3),
          reason: 'the parent once; the child twice, each from the snapshot',
        );
      },
    );
  });

  group('saveExplorationAsMoment', () {
    test('a replayed trace is written where the Ash declaration lists explorations and exported as a Moment', () async {
      final f = fixture();
      final saving = declareExplorations(f);
      final saved = await saving.situations.save(exploration(f.project), 'cancelled-yet-paid');
      expect(saved['trace'], '../${p.basename(saving.backend)}/priv/moments/explorations/cancelled-yet-paid.json');
      expect(saved['moves'], 3);
      expect(saving.exports(), 1, reason: 'the declaration is exported again once the trace is written');
      expect(readJson(p.join(saving.backend, 'priv/moments/explorations/cancelled-yet-paid.json')), {
        ...readJson(exploration(f.project))! as Map,
      });
      final declared = ((readJson(p.join(f.project, 'moments/manifest.json'))! as Map)['moments']! as Map);
      expect((declared['cancelled-yet-paid']! as Map)['exploration'], isA<Map>());
      expect((saved['situation']! as Map)['kind'], 'exploration');

      final map = parseMap(File(p.join(f.project, 'moments/explorations.md')).readAsStringSync());
      final state = map.states['cancelled-yet-paid']!;
      expect(map.meta['moments'], '0.1');
      expect(state.from, isNull, reason: 'replay starts from the empty database');
      expect(state.run!.ref, saved['trace']);
      expect(state.checks.single, contains('refusal_enforced holds for MyApp.Booking pay'));
      expect(state.describe, contains('traveler performs cancel on MyApp.Booking #0'));
      expect(state.describe, contains('the clock moves 16 minute'));

      final forked = await saving.situations.fork('cancelled-yet-paid', 1);
      expect(f.backend.replays, 2, reason: 'evaluating the Moment replays the trace its declaration carries');
      expect((forked['forks']! as List), hasLength(1));
      final second = await saving.situations.save(exploration(f.project, moves: const []), 'empty-case');
      expect(second['moves'], 0);
      expect(parseMap(File(p.join(f.project, 'moments/explorations.md')).readAsStringSync()).order, [
        'cancelled-yet-paid',
        'empty-case',
      ]);
      await expectLater(
        saving.situations.save(exploration(f.project), 'cancelled-yet-paid'),
        throwing('already names'),
      );
    });

    test(
      'a name in use, no trace, no declared directory, one outside the roots or a failed replay writes nothing',
      () async {
        final f = fixture();
        await expectLater(f.situations.save(exploration(f.project), 'notes'), throwing('already names'));
        final junk = p.join(f.project, 'junk.json');
        File(junk).writeAsStringSync('{"moves": "none"}');
        await expectLater(f.situations.save(junk, 'junk'), throwing('Not an exploration trace'));
        await expectLater(f.situations.save(exploration(f.project), 'undeclared'), throwing('declares explorations'));
        final saving = declareExplorations(f, directory: '../../elsewhere');
        await expectLater(saving.situations.save(exploration(f.project), 'outside'), throwing('outside the app'));
        final declared = declareExplorations(f);
        f.backend.failReplay = true;
        await expectLater(declared.situations.save(exploration(f.project), 'broken'), throwsA(isA<StateError>()));
        expect(declared.exports(), 0);
        expect(File(p.join(f.project, 'moments/explorations.md')).existsSync(), isFalse);
        expect(Directory(p.join(declared.backend, 'priv/moments/explorations')).existsSync(), isFalse);
      },
    );
  });

  group('CLI', () {
    setUpAll(compileCli);

    test('the verbs parse their arguments and refuse others', () {
      expect(parseArgs(['diff', 'notes@1', 'notes']).names, ['notes@1', 'notes']);
      expect(parseArgs(['save', 'trace.json', 'found-it']).name, 'found-it');
      expect(parseArgs(['trace', 'notes']).name, 'notes');
      for (final args in [
        ['diff', 'notes'],
        ['diff', 'notes@0', 'notes'],
        ['trace', 'notes', '--fresh'],
        ['save', 'trace.json', 'Bad Name'],
        ['situations', 'extra'],
      ]) {
        expect(() => parseArgs(args), throwsA(anything), reason: '$args');
      }
    });

    test('without a running backend the verbs are unavailable, and situations lists what is kept', () async {
      final f = fixture();
      await f.situations.prepare('notes');
      final fork = await moments(['fork', 'notes', '-n', '2', '--json'], cwd: f.project);
      expect(fork.code, 2);
      expect(fork.stdout, contains('No backend running'));
      final listed = await moments(['situations', '--json'], cwd: f.project);
      expect(listed.code, 0);
      final records = ((jsonDecode(listed.stdout) as Map)['situations']! as List).cast<Map>();
      expect(records.single['id'], 'notes@1');
      expect(listed.stdout, isNot(contains('dataScope')));
      final text = await moments(['situations'], cwd: f.project);
      expect(text.stdout, contains('notes@1 · prepared'));
    });
  });
}
