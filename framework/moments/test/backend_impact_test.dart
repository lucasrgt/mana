import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moments/src/affected.dart';
import 'package:moments/src/impact.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

String digest(String text) => sha256.convert(utf8.encode(text)).toString();
String serverPath(String name) => '../../server/lib/$name.ex';

/// An app whose two Moments are owned by compiled Elixir resources `a` and
/// `b`; `a` depends on `helper` and `shared`, `b` on `shared`.
final class Fixture {
  Fixture({bool dart = false}) : root = temporary('mana-backend-impact-') {
    app = p.join(root, 'app');
    server = p.join(root, 'server');
    git(['init']);
    git(['config', 'user.name', 'Moments fixture']);
    git(['config', 'user.email', 'fixture@moments.invalid']);
    for (final name in ['a', 'b', 'helper', 'shared']) {
      final text = '# $name\n';
      put(p.join(server, 'lib/$name.ex'), text);
      files[serverPath(name)] = {
        'sha256': digest(text),
        'dependencies': name == 'a'
            ? [serverPath('helper'), serverPath('shared')]
            : name == 'b'
            ? [serverPath('shared')]
            : <String>[],
      };
    }
    for (final name in ['a', 'b']) {
      screens['/$name'] = <String, Object?>{
        'properties': {
          'route': {
            'enum': ['/$name'],
          },
        },
        'watch': <Object?>[],
      };
      moments[name] = <String, Object?>{
        'source': <String, Object?>{
          'file': serverPath(name),
          'sha256': files[serverPath(name)]!['sha256'],
          'module': 'Fixture.$name',
          'line': 1,
        },
        'projection': {'route': '/$name'},
        'checks': [
          {'name': 'restored', 'kind': 'restored'},
        ],
        'steps': <Object?>[],
      };
      roots[name] = [serverPath(name)];
    }
    if (dart) {
      for (final name in ['a', 'b']) {
        screens['/$name']!['clientRoots'] = ['lib/$name.dart'];
        put(p.join(app, 'lib/$name.dart'), 'const $name=1;');
      }
      put(p.join(app, 'pubspec.yaml'), 'name: backend_impact_fixture\nenvironment:\n  sdk: ^3.13.2\n');
      put(p.join(app, 'pubspec.lock'), 'packages: {}\n');
      put(
        p.join(app, '.dart_tool/package_config.json'),
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'backend_impact_fixture', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.13'},
          ],
        }),
      );
    }
    put(
      p.join(app, 'moments/sources.json'),
      jsonEncode({
        'version': 1,
        'roots': [
          {'name': 'server', 'path': '../server'},
        ],
      }),
    );
    save();
    git(['add', 'app', 'server']);
    git(['commit', '-m', 'compiled fixture baseline']);
  }

  final String root;
  late final String app, server;
  final screens = <String, Map<String, Object?>>{};
  final moments = <String, Map<String, Object?>>{};
  final files = <String, Map<String, Object?>>{};
  final roots = <String, Object?>{};
  late Map<String, Object?>? graph = {
    'version': 1,
    'status': 'available',
    'engine': 'mix-xref+ash-resources',
    'elixir': '1.18.4',
    'environment': 'dev',
    'project': '../../server',
    'sourcePaths': ['lib'],
    'files': files,
    'roots': roots,
  };

  String get manifestFile => p.join(app, 'moments/manifest.json');

  void put(String file, String text) {
    Directory(p.dirname(file)).createSync(recursive: true);
    File(file).writeAsStringSync(text);
  }

  void save() => put(
    manifestFile,
    jsonEncode({'version': 2, 'watch': <Object?>[], 'screens': screens, 'moments': moments, 'backendGraph': ?graph}),
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

  void edit(String name, {bool sync = true}) {
    final file = p.join(server, 'lib/$name.ex');
    put(file, '${File(file).readAsStringSync()}# edit\n');
    if (!sync) return;
    final sha = sha256.convert(File(file).readAsBytesSync()).toString();
    files[serverPath(name)]!['sha256'] = sha;
    (moments[name]?['source'] as Map?)?['sha256'] = sha;
    save();
  }

  Future<Map<String, Object?>> plan() => affectedMoments(app);
}

List<Object?> names(Map<String, Object?> plan) => [for (final s in (plan['selected']! as List).cast<Map>()) s['name']];
List<Map> reasons(Map<String, Object?> plan) => (plan['reasons']! as List).cast<Map>();
Map<String, Object?> graphOf(Map<String, Object?> plan, String key) => (plan[key]! as Map).cast();

void main() {
  setUpAll(() async {
    try {
      importsBinary();
    } on Object {
      await buildImportsTool();
    }
  });

  test('compiled resource and transitive helper deltas select the owning Moment offline', () async {
    final f = Fixture();
    f.edit('helper');
    var plan = await f.plan();
    expect(plan['precision'], 'elixir-compiled');
    expect(names(plan), ['a']);
    expect(plan['executed'], false);
    expect(graphOf(plan, 'backendGraph')['fileCount'], 4);
    f.edit('a');
    plan = await f.plan();
    expect(names(plan), ['a']);
    expect(((plan['selected']! as List).first as Map)['reason'], 'elixir-compiled-dependency');
    f.edit('shared');
    expect(names(await f.plan()), ['a', 'b']);
  });

  test('stale hashes, new source files, deleted sources and changed dependencies never narrow', () async {
    final f = Fixture();
    f.edit('helper', sync: false);
    var plan = await f.plan();
    expect(plan['precision'], 'whole-catalog');
    expect(reasons(plan).any((r) => r['code'] == 'backend-impact-unavailable'), isTrue);
    f.edit('helper');
    f.put(p.join(f.server, 'lib/extra.ex'), '# extra');
    expect((await f.plan())['precision'], 'whole-catalog');
    File(p.join(f.server, 'lib/extra.ex')).deleteSync();
    (f.files[serverPath('b')]!['dependencies']! as List).add(serverPath('helper'));
    f.save();
    plan = await f.plan();
    expect(plan['precision'], 'whole-catalog');
    expect(reasons(plan).any((r) => r['code'] == 'backend-topology-change'), isTrue);
    File(p.join(f.server, 'lib/helper.ex')).deleteSync();
    expect(names(await f.plan()), ['a', 'b']);
  });

  test('config, adapter and Dart without declared roots remain broad', () async {
    for (final file in ['server/config/runtime.exs', 'app/moments/backend.json', 'app/lib/a.dart']) {
      final f = Fixture();
      f.edit('a');
      f.put(p.join(f.root, file), '// configuration');
      expect((await f.plan())['precision'], 'whole-catalog', reason: file);
    }
  });

  test('declaration-only domains and changed compiler/resource roots cannot infer backend ownership', () async {
    for (final mutate in <void Function(Map<String, Object?> graph)>[
      (g) => (g['roots']! as Map)['b'] = <Object?>[],
      (g) => g['environment'] = 'prod',
      (g) => g['sourcePaths'] = ['other'],
      (g) => g['status'] = 'unavailable',
    ]) {
      final f = Fixture();
      f.edit('a');
      mutate(f.graph!);
      f.save();
      expect((await f.plan())['precision'], 'whole-catalog');
    }
  });

  test('source symlinks and graph paths outside configured roots are refused even in a stable baseline', () async {
    final f = Fixture();
    f.put(p.join(f.root, 'external.ex'), '# outside');
    Link(p.join(f.server, 'lib/escape.ex')).createSync(p.join(f.root, 'external.ex'));
    f.git(['add', 'external.ex', 'server/lib/escape.ex']);
    f.git(['commit', '-m', 'symlink fixture']);
    f.edit('a');
    expect((await f.plan())['precision'], 'whole-catalog');
    Link(p.join(f.server, 'lib/escape.ex')).deleteSync();
    f.files['../../external.ex'] = {'sha256': digest('# outside'), 'dependencies': <String>[]};
    f.save();
    f.git(['add', 'app/moments/manifest.json', 'server/lib/a.ex', 'server/lib/escape.ex']);
    f.git(['commit', '-m', 'untrusted graph fixture']);
    f.edit('a');
    expect((await f.plan())['precision'], 'whole-catalog');
  });

  test('a backend graph missing at the baseline widens even when current sources are fresh', () async {
    final f = Fixture();
    final graph = f.graph;
    f.graph = null;
    f.save();
    f.git(['add', 'app/moments/manifest.json']);
    f.git(['commit', '-m', 'legacy baseline']);
    f.graph = graph;
    f.edit('a');
    expect((await f.plan())['precision'], 'whole-catalog');
  });

  test('mixed changes in the same slice retain both graphs and select the union once', () async {
    final f = Fixture(dart: true);
    f.edit('a');
    f.put(p.join(f.app, 'lib/a.dart'), 'const a=2;');
    final plan = await f.plan();
    expect(plan['precision'], 'dart-and-elixir');
    expect(names(plan), ['a']);
    expect(((plan['selected']! as List).first as Map)['reason'], 'dart-and-elixir-dependency');
    List<Object?> paths(String key) => [
      for (final m in (graphOf(plan, key)['matches']! as List).cast<Map>()) m['path'],
    ];
    expect(paths('dartGraph'), ['app/lib/a.dart']);
    expect(paths('backendGraph'), ['server/lib/a.ex']);
    expect(plan['executed'], false);
  });

  test('mixed changes in different slices take the union, never the intersection', () async {
    final f = Fixture(dart: true);
    f.edit('b');
    f.put(p.join(f.app, 'lib/a.dart'), 'const a=2;');
    final plan = await f.plan();
    expect(plan['precision'], 'dart-and-elixir');
    expect(names(plan), ['a', 'b']);
    expect(
      [for (final s in (plan['selected']! as List).cast<Map>()) s['reason']],
      ['dart-import-dependency', 'elixir-compiled-dependency'],
    );
  });

  test('one unavailable graph or unknown path widens a mixed plan despite the valid other graph', () async {
    final f = Fixture(dart: true);
    f.edit('helper', sync: false);
    f.put(p.join(f.app, 'lib/a.dart'), 'const a=2;');
    var plan = await f.plan();
    expect(plan['precision'], 'whole-catalog');
    expect(names(plan), ['a', 'b']);
    expect(reasons(plan).any((r) => r['code'] == 'backend-impact-unavailable'), isTrue);
    f.edit('helper');
    f.put(p.join(f.app, 'lib/a.dart'), 'const a=;');
    plan = await f.plan();
    expect(plan['precision'], 'whole-catalog');
    expect(reasons(plan).any((r) => r['code'] == 'dart-impact-unavailable'), isTrue);
    f.put(p.join(f.app, 'lib/a.dart'), 'const a=2;');
    f.put(p.join(f.root, 'deployment.toml'), '[new]');
    plan = await f.plan();
    expect(plan['precision'], 'whole-catalog');
    expect(names(plan), ['a', 'b']);
    expect(reasons(plan).any((r) => (r['paths'] as List).contains('deployment.toml')), isTrue);
  });
}
