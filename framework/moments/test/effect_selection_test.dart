import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moments/src/affected.dart';
import 'package:moments/src/elixir_recipes.dart';
import 'package:moments/src/impact.dart';
import 'package:moments/src/effects.dart' show recordPreparation;
import 'package:moments/src/protocol.dart' show protocol;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

String digest(String text) => sha256.convert(utf8.encode(text)).toString();
String server(String name) => '../../server/lib/$name.ex';

/// A backend whose `App.Booking` resource runs `pay` through `pay_change`
/// and `cancel` through `cancel_change`, both declared in `booking`, and an
/// app whose Moments each have their own screen. The export maps each change
/// module to its action (`backendGraph.actions`).
final class Fixture {
  Fixture(Map<String, Map<String, Object?>> scenes) : root = temporary('mana-effect-selection-') {
    app = p.join(root, 'app');
    final dependencies = {
      'domain': ['booking'],
      'booking': ['pay_change', 'cancel_change', 'helper'],
      'pay_change': ['helper'],
      'cancel_change': <String>[],
      'helper': <String>[],
    };
    for (final MapEntry(key: name, value: deps) in dependencies.entries) {
      put(p.join(root, 'server/lib/$name.ex'), '# $name\n');
      files[server(name)] = {
        'sha256': digest('# $name\n'),
        'dependencies': [for (final d in deps) server(d)]..sort(),
      };
    }
    for (final MapEntry(key: name, value: scene) in scenes.entries) {
      screens['/$name'] = {
        'properties': {
          'route': {
            'enum': ['/$name'],
          },
        },
        'watch': <Object?>[],
        'clientRoots': ['lib/${name.replaceAll('-', '_')}.dart'],
      };
      put(p.join(app, 'lib/${name.replaceAll('-', '_')}.dart'), 'const value = 1;');
      moments[name] = {
        'source': {'file': server('domain'), 'sha256': digest('# domain\n'), 'module': 'App.Domain', 'line': 1},
        'projection': {'route': '/$name'},
        'checks': [
          {'name': 'restored', 'kind': 'restored'},
        ],
        'steps': <Object?>[],
        ...scene,
      };
      roots[name] = [server('domain'), server('booking')];
    }
    put(p.join(app, 'pubspec.yaml'), 'name: effect_fixture\nenvironment:\n  sdk: ^3.13.2\n');
    put(p.join(app, 'pubspec.lock'), 'packages: {}\n');
    put(
      p.join(app, '.dart_tool/package_config.json'),
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {'name': 'effect_fixture', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.13'},
        ],
      }),
    );
    put(
      p.join(app, 'moments/sources.json'),
      jsonEncode({
        'version': 1,
        'roots': [
          {'name': 'server', 'path': '../server'},
        ],
      }),
    );
    put(p.join(root, '.gitignore'), '.dart_tool/\n.proofs/\n');
    save();
    git(['init']);
    git(['config', 'user.name', 'Moments fixture']);
    git(['config', 'user.email', 'fixture@moments.invalid']);
    git(['add', '.']);
    git(['commit', '-m', 'effect fixture baseline']);
  }

  final String root;
  late final String app;
  final screens = <String, Map<String, Object?>>{};
  final moments = <String, Map<String, Object?>>{};
  final files = <String, Map<String, Object?>>{};
  final roots = <String, Object?>{};
  late Map<String, Object?> actions = {
    'version': 1,
    'status': 'available',
    'engine': 'ash-resource-info+mix-xref',
    'effects': {
      server('pay_change'): ['App.Booking.pay'],
      server('cancel_change'): ['App.Booking.cancel'],
    },
    'verbs': {'booking.withdraw': 'App.Booking.cancel'},
    'recipes': {
      'booking-paid': ['App.Booking'],
    },
  };

  String get manifestFile => p.join(app, 'moments/manifest.json');

  void put(String file, String text) {
    Directory(p.dirname(file)).createSync(recursive: true);
    File(file).writeAsStringSync(text);
  }

  void save() => put(
    manifestFile,
    jsonEncode({
      'version': 3,
      'protocol': protocol,
      'watch': <Object?>[],
      'screens': screens,
      'moments': moments,
      'backendGraph': {
        'version': 1,
        'status': 'available',
        'engine': 'mix-xref+ash-resources',
        'elixir': '1.18.4',
        'environment': 'dev',
        'project': '../../server',
        'sourcePaths': ['lib'],
        'files': files,
        'roots': roots,
        'actions': actions,
      },
    }),
  );

  void git(List<String> args) {
    final result = Process.runSync('git', [
      '-C',
      root,
      '-c',
      'core.hooksPath=/dev/null',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ]);
    if (result.exitCode != 0) throw StateError('git ${args.join(' ')}: ${result.stderr}');
  }

  /// Edits a backend file and exports its new hash, as `moments sync` does.
  void edit(String name) {
    final file = p.join(root, 'server/lib/$name.ex');
    put(file, '${File(file).readAsStringSync()}# edit\n');
    files[server(name)]!['sha256'] = sha256.convert(File(file).readAsBytesSync()).toString();
    save();
  }

  /// A report `moments run` keeps for a passed journey: its steps and the
  /// receipts of the actions their gestures called.
  void receipt(
    String moment,
    List<String> actions, {
    String status = 'passed',
    List<String>? steps,
    bool truncated = false,
    bool? writesComplete,
    String at = '2026-11-01T10-00-00-000Z',
  }) {
    final gesture = '00000000-0000-4000-8000-${(_reports++).toString().padLeft(12, '0')}';
    put(
      p.join(app, 'moments/.proofs/$at-$gesture.json'),
      jsonEncode({
        'version': 1,
        'name': moment,
        'operation': 'journey',
        'status': status,
        'steps': [
          for (final step in steps ?? [for (final s in moments[moment]!['steps']! as List) (s as Map)['name']])
            {'name': step, 'id': gesture, 'status': 'passed'},
        ],
        'actions': {
          'status': 'observed',
          'coverage': 'not-established',
          'overflow': false,
          'receipts': [
            {
              'version': 1,
              'gesture': gesture,
              'request': 'a' * 32,
              'step': (steps ?? [for (final s in moments[moment]!['steps']! as List) (s as Map)['name']]).firstOrNull,
              'truncated': truncated,
              'writesComplete': ?writesComplete,
              'scope': 'request-actions-only',
              'coverage': 'not-established',
              'actions': [
                for (final action in actions)
                  {
                    'resource': action.substring(0, action.lastIndexOf('.')),
                    'action': action.substring(action.lastIndexOf('.') + 1),
                    'outcome': 'span-finished',
                  },
              ],
            },
          ],
        },
      }),
    );
  }

  var _reports = 0;

  Future<Map<String, Object?>> plan() => affectedMoments(app);
}

Map<String, Object?> tap(String name) => {'name': name, 'kind': 'tap', 'target': '$name.button'};

List<Object?> names(Map<String, Object?> plan) => [for (final s in (plan['selected']! as List).cast<Map>()) s['name']];
Map<Object?, Object?> why(Map<String, Object?> plan) => {
  for (final s in (plan['selected']! as List).cast<Map>()) s['name']: s['why'],
};

void main() {
  setUpAll(() async {
    try {
      importsBinary();
    } on Object {
      await buildImportsTool();
    }
  });

  test('a change module selects the Moments whose receipts name its action, and only those, plus imports', () async {
    final f = Fixture({
      'pay': {
        'steps': [tap('pay')],
      },
      'cancel': {
        'steps': [tap('cancel')],
      },
      'look': {},
    });
    f.receipt('pay', ['App.Booking.read', 'App.Booking.pay']);
    f.receipt('cancel', ['App.Booking.read', 'App.Booking.cancel']);
    f.edit('pay_change');
    f.put(p.join(f.app, 'lib/look.dart'), 'const value = 2;');
    final plan = await f.plan();
    expect(plan['precision'], 'dart-and-elixir');
    expect(names(plan), ['look', 'pay']);
    expect(plan['omitted'], ['cancel']);
    expect(why(plan), {
      'look': ['import'],
      'pay': ['effect: App.Booking.pay'],
    });
    final effects = (plan['effectGraph']! as Map).cast<String, Object?>();
    expect(effects['matches'], [
      {
        'path': 'server/lib/pay_change.ex',
        'actions': ['App.Booking.pay'],
        'moments': ['pay'],
      },
    ]);
    expect(plan['executed'], false);
  });

  test('verbs and recipes name actions too; a Moment without that evidence stays selected', () async {
    final f = Fixture({
      'withdraw': {
        'steps': [
          {...tap('withdraw'), 'target': 'verb:booking.withdraw', 'verb': 'booking.withdraw'},
        ],
      },
      'paid': {
        'backend': {'recipe': 'booking-paid'},
      },
      'fresh': {
        'steps': [tap('fresh')],
      },
      'elsewhere': {
        'backend': {'recipe': 'not-a-set'},
      },
      'child': {'from': 'fresh'},
      'look': {},
    });
    f.receipt('withdraw', ['App.Booking.read']);
    f.edit('cancel_change');
    final plan = await f.plan();
    expect(plan['precision'], 'elixir-effects');
    expect(why(plan), {
      'child': ['no receipt'],
      'elsewhere': ['recipe not exported: not-a-set'],
      'fresh': ['no receipt'],
      'paid': ['effect: App.Booking.cancel'],
      'withdraw': ['effect: App.Booking.cancel'],
    });
    expect(plan['omitted'], ['look']);
    expect((plan['effectGraph']! as Map)['evidenceMissing'], {
      'child': 'no receipt',
      'elsewhere': 'recipe not exported: not-a-set',
      'fresh': 'no receipt',
    });
  });

  test('only the latest passed receipt of the current steps counts, and a truncated one is incomplete', () async {
    final f = Fixture({
      'pay': {
        'steps': [tap('pay')],
      },
    });
    f.edit('pay_change');
    f.receipt('pay', ['App.Booking.pay'], status: 'failed', at: '2026-11-01T11-00-00-000Z');
    expect(why(await f.plan()), {
      'pay': ['no receipt'],
    });
    f.receipt('pay', ['App.Booking.pay'], steps: ['an-older-step'], at: '2026-11-01T12-00-00-000Z');
    expect(why(await f.plan()), {
      'pay': ['no receipt'],
    });
    f.receipt('pay', ['App.Booking.cancel'], truncated: true, at: '2026-11-01T13-00-00-000Z');
    expect(why(await f.plan()), {
      'pay': ['receipt truncated'],
    });
    // Reads gave way to writes past the limit: every write is still listed.
    f.receipt('pay', ['App.Booking.cancel'], truncated: true, writesComplete: true, at: '2026-11-01T13-30-00-000Z');
    expect(names(await f.plan()), isEmpty);
    f.receipt('pay', ['App.Booking.cancel'], truncated: true, writesComplete: false, at: '2026-11-01T13-40-00-000Z');
    expect(why(await f.plan()), {
      'pay': ['receipt truncated'],
    });
    f.receipt('pay', ['App.Booking.cancel'], at: '2026-11-01T14-00-00-000Z');
    final plan = await f.plan();
    expect(names(plan), isEmpty);
    expect(plan['precision'], 'elixir-effects');
    // Older receipts that named the action do not outlive the latest.
    f.receipt('pay', ['App.Booking.pay'], at: '2026-11-01T09-00-00-000Z');
    expect(names(await f.plan()), isEmpty);
  });

  test('files outside the effects, or without an action map, keep the compiled file graph', () async {
    var f = Fixture({
      'pay': {
        'steps': [tap('pay')],
      },
      'cancel': {
        'steps': [tap('cancel')],
      },
    });
    f.receipt('pay', ['App.Booking.pay']);
    f.receipt('cancel', ['App.Booking.cancel']);
    f.edit('helper');
    var plan = await f.plan();
    expect(plan['precision'], 'elixir-compiled');
    expect(why(plan), {
      'cancel': ['compiled dependency'],
      'pay': ['compiled dependency'],
    });
    f.edit('pay_change');
    expect(why(await f.plan()), {
      'cancel': ['compiled dependency'],
      'pay': ['compiled dependency', 'effect: App.Booking.pay'],
    });

    f = Fixture({
      'pay': {
        'steps': [tap('pay')],
      },
    })..actions = {'version': 1, 'status': 'unavailable'};
    f.save();
    f.git(['commit', '-am', 'export without an action map']);
    f.receipt('pay', ['App.Booking.cancel']);
    f.edit('pay_change');
    plan = await f.plan();
    expect(plan['precision'], 'elixir-compiled');
    expect((plan['effectGraph']! as Map)['status'], 'unavailable');
    expect(names(plan), ['pay']);
  });

  test('an action map changed since the base or naming unknown files never narrows', () async {
    var f = Fixture({
      'pay': {
        'steps': [tap('pay')],
      },
    });
    f.receipt('pay', ['App.Booking.cancel']);
    (f.actions['effects']! as Map)[server('helper')] = ['App.Booking.pay'];
    f.edit('pay_change');
    var plan = await f.plan();
    expect(plan['precision'], 'whole-catalog');
    expect((plan['reasons']! as List).cast<Map>().map((r) => r['code']), contains('backend-topology-change'));

    f = Fixture({
      'pay': {
        'steps': [tap('pay')],
      },
    });
    f.receipt('pay', ['App.Booking.cancel']);
    (f.actions['effects']! as Map)['../../server/lib/missing.ex'] = ['App.Booking.pay'];
    f.save();
    f.git(['commit', '-am', 'malformed action map']);
    f.edit('pay_change');
    plan = await f.plan();
    expect(plan['precision'], 'whole-catalog');
    expect((plan['reasons']! as List).cast<Map>().map((r) => r['code']), contains('backend-impact-unavailable'));
  });

  String preparation(List<String> actions, {bool truncated = false, bool? writesComplete}) => base64Url
      .encode(
        utf8.encode(
          jsonEncode({'version': 1, 'truncated': truncated, 'writesComplete': ?writesComplete, 'actions': actions}),
        ),
      )
      .replaceAll('=', '');

  test('a recipe that has prepared is matched by the actions it ran, not by what its module reaches', () async {
    final f = Fixture({
      'paid': {
        'backend': {'recipe': 'booking-paid'},
      },
      'other': {
        'backend': {'recipe': 'booking-paid'},
        'from': 'paid',
      },
    });
    final kept = p.join(f.app, 'moments/.proofs/preparations');
    f.edit('cancel_change');
    // Statically the recipe reaches App.Booking, so cancel's change selects it.
    expect(why(await f.plan()), {
      'other': ['effect: App.Booking.cancel'],
      'paid': ['effect: App.Booking.cancel'],
    });
    recordPreparation(kept, 'booking-paid', preparation(['App.Booking.create', 'App.Booking.pay']));
    var plan = await f.plan();
    expect(names(plan), isEmpty);
    expect(plan['omitted'], ['other', 'paid']);
    f.edit('pay_change');
    expect(why(await f.plan()), {
      'other': ['effect: App.Booking.pay'],
      'paid': ['effect: App.Booking.pay'],
    });
    // Truncated past reads only, the writes are still all there.
    recordPreparation(
      kept,
      'booking-paid',
      preparation(['App.Booking.create', 'App.Booking.pay'], truncated: true, writesComplete: true),
    );
    f.edit('cancel_change');
    expect(names(await f.plan()), ['other', 'paid']);
    expect(why(await f.plan())['paid'], ['effect: App.Booking.pay']);
    // An incomplete or malformed answer is no observation: the static reach decides again.
    recordPreparation(kept, 'booking-paid', preparation(['App.Booking.create'], truncated: true));
    recordPreparation(kept, 'booking-paid', 'not base64 json');
    plan = await f.plan();
    expect(why(plan)['paid'], ['effect: App.Booking.cancel', 'effect: App.Booking.pay']);
    expect(Directory(p.join(f.app, 'moments/.proofs')).statSync().mode & 0x3f, 0);
  });

  test('an exploration Moment is reached through the resources its trace touches', () async {
    Map<String, Object?> exploration(Map<String, Object?> trace) => {
      'checks': [
        {'name': 'paid-once', 'kind': 'property'},
      ],
      'exploration': {'file': '../explorations/x.json', 'sha256': 'a' * 64, 'trace': trace},
    };
    final f = Fixture({
      'by-move': exploration({
        'property': 'paid-once',
        'moves': [
          {
            'kind': 'verb',
            'actor': 'host',
            'verb': 'pay',
            'ref': ['App.Booking', 0],
          },
        ],
      }),
      'by-resource': exploration({'property': 'paid-once', 'resource': 'App.Booking', 'moves': <Object?>[]}),
      'elsewhere': exploration({
        'property': 'paid-once',
        'resources': ['App.Other'],
        'moves': <Object?>[],
      }),
      'nothing': exploration({'property': 'paid-once', 'moves': <Object?>[]}),
    });
    f.edit('pay_change');
    expect(why(await f.plan()), {
      'by-move': ['effect: App.Booking.pay'],
      'by-resource': ['effect: App.Booking.pay'],
      'nothing': ['exploration names no resource'],
    });
  });

  test('the recipe adapter keeps what a preparation answered it ran', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      request.response.headers
        ..contentType = ContentType.json
        ..set('x-mana-preparation', preparation(['App.Booking.create']));
      request.response.write(jsonEncode({'route': '/paid'}));
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final kept = p.join(temporary('mana-preparations-'), 'moments/.proofs/preparations');
    final adapter = elixirRecipes(['booking-paid'], preparations: kept)['booking-paid']!;
    final launch = await adapter.prepare({'apiUrl': 'http://127.0.0.1:${server.port}', 'password': 'p' * 32});
    expect(launch, {
      'launch': {'route': '/paid'},
    });
    expect(jsonDecode(File(p.join(kept, 'booking-paid.json')).readAsStringSync()), {
      'version': 1,
      'recipe': 'booking-paid',
      'complete': true,
      'actions': ['App.Booking.create'],
    });
  });
}
