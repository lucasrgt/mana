import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moments/src/affected.dart';
import 'package:moments/src/cli.dart';
import 'package:moments/src/impact.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// A git checkout with one app and two Moments, `a` and `b`.
final class Fixture {
  Fixture({bool backendSource = false, bool dartRoots = false}) : root = temporary('mana-affected-') {
    app = p.join(root, 'app');
    manifestFile = p.join(app, 'moments/manifest.json');
    git(['init']);
    git(['config', 'user.name', 'Moments fixture']);
    git(['config', 'user.email', 'fixture@moments.invalid']);
    put(p.join(root, '.moments.json'), jsonEncode({'project': 'app'}));
    for (final name in ['a', 'b']) {
      final server = name == 'a' && backendSource;
      final file = server ? p.join(root, 'server/a.ex') : p.join(app, 'moments/ash/lib/$name.ex');
      put(file, '# declaration $name\n');
      (manifest['screens']! as Map)['/$name'] = {
        'watch': ['lib/$name.dart'],
        'properties': {
          'route': {
            'enum': ['/$name'],
          },
        },
      };
      moments[name] = {
        'source': {
          'file': server ? '../../server/a.ex' : 'ash/lib/$name.ex',
          'line': 1,
          'module': 'Moment$name',
          'sha256': sha256.convert(File(file).readAsBytesSync()).toString(),
        },
        'projection': {'route': '/$name'},
        'checks': [
          {'name': 'restored', 'kind': 'restored'},
        ],
        'steps': <Object?>[],
      };
      put(p.join(app, 'lib/$name.dart'), '// $name');
    }
    if (backendSource) {
      put(
        p.join(app, 'moments/sources.json'),
        jsonEncode({
          'version': 1,
          'roots': [
            {'name': 'server', 'path': '../server'},
          ],
        }),
      );
    }
    if (dartRoots) {
      for (final name in ['a', 'b']) {
        ((manifest['screens']! as Map)['/$name'] as Map)['clientRoots'] = ['lib/$name.dart'];
      }
      put(p.join(app, 'pubspec.yaml'), 'name: impact_fixture\nenvironment:\n  sdk: ^3.13.2\n');
      put(p.join(app, 'pubspec.lock'), 'packages: {}\n');
      put(
        p.join(app, '.dart_tool/package_config.json'),
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {'name': 'impact_fixture', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.13'},
          ],
        }),
      );
    }
    save();
    git(['add', 'app', '.moments.json', if (backendSource) 'server']);
    git(['commit', '-m', 'fixture baseline']);
  }

  final String root;
  late final String app, manifestFile;
  final manifest = <String, Object?>{
    'version': 2,
    'watch': ['lib/a.dart', 'lib/b.dart'],
    'screens': <String, Object?>{},
    'moments': <String, Object?>{},
  };
  Map<String, Object?> get moments => (manifest['moments']! as Map).cast();
  Map<String, Object?> moment(String name) => (moments[name]! as Map).cast();

  void put(String file, String text) {
    Directory(p.dirname(file)).createSync(recursive: true);
    File(file).writeAsStringSync(text);
  }

  void save() => put(manifestFile, jsonEncode(manifest));

  String git(List<String> args) {
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
    return result.stdout as String;
  }

  void changeDeclaration(String name) {
    final source = (moment(name)['source']! as Map).cast<String, Object?>();
    final file = p.normalize(p.join(p.dirname(manifestFile), source['file']! as String));
    put(file, '# changed $name\n');
    source['sha256'] = sha256.convert(File(file).readAsBytesSync()).toString();
    moment(name)['source'] = source;
    save();
  }

  Future<Map<String, Object?>> affected() => affectedMoments(app);
}

List<Object?> names(Map<String, Object?> result) => [
  for (final s in (result['selected']! as List).cast<Map>()) s['name'],
];
List<Map> reasons(Map<String, Object?> result) => (result['reasons']! as List).cast<Map>();

void main() {
  setUpAll(() async {
    try {
      importsBinary();
    } on Object {
      await buildImportsTool();
    }
    await compileCli();
  });

  test('fresh declaration delta narrows by exported identity, never by refresh watch alone', () async {
    final f = Fixture();
    expect((await f.affected())['selected'], <Object?>[]);
    f.changeDeclaration('a');
    var result = await f.affected();
    expect(result['status'], 'planned');
    expect(result['executed'], false);
    expect(names(result), ['a']);
    expect(result['omitted'], ['b']);
    expect(result['precision'], 'exported-declarations');
    f.put(p.join(f.app, 'lib/a.dart'), '// shared usage is unknown');
    result = await f.affected();
    expect(names(result), ['a', 'b']);
    expect(result['precision'], 'whole-catalog');
  });

  test('staged, unstaged, renamed, deleted and untracked paths all participate without line parsing', () async {
    final f = Fixture();
    File(p.join(f.app, 'lib/a.dart')).renameSync(p.join(f.app, 'lib/renamed a.dart'));
    f.git(['add', 'app/lib/a.dart', 'app/lib/renamed a.dart']);
    f.put(p.join(f.app, 'lib/b.dart'), '// unstaged');
    f.put(p.join(f.root, 'shared', 'odd\nname.dart'), '// untracked shared package');
    final result = await f.affected();
    expect(result['changed'], ['app/lib/a.dart', 'app/lib/b.dart', 'app/lib/renamed a.dart', 'shared/odd\nname.dart']);
    expect(names(result), ['a', 'b']);
  });

  test('a stale source blocks a trustworthy plan instead of producing an empty selection', () async {
    final f = Fixture();
    f.put(p.join(f.app, 'moments/ash/lib/a.ex'), '# not exported');
    final result = await f.affected();
    expect(result['status'], 'unavailable');
    expect(result['exitCode'], 2);
    expect(
      (result['issues']! as List).cast<Map>().any((i) => i['name'] == 'a' && i['reason'] == 'stale-declaration'),
      isTrue,
    );
    expect((result['selected']! as List).length, 2);
  });

  test('co-located backend declarations widen selection because the file can change resource behaviour', () async {
    final f = Fixture(backendSource: true);
    f.changeDeclaration('a');
    final result = await f.affected();
    expect(result['status'], 'planned');
    expect((result['selected']! as List).length, 2);
    expect(reasons(result).any((r) => (r['paths'] as List).contains('server/a.ex')), isTrue);
  });

  test('removing a Moment and changing global watch inventory cannot silently reduce verification', () async {
    final f = Fixture();
    f.moments.remove('a');
    f.save();
    var result = await f.affected();
    expect(result['removed'], ['a']);
    expect(names(result), ['b']);
    (f.manifest['watch']! as List).add('lib/extra.dart');
    f.save();
    result = await f.affected();
    expect(reasons(result).any((r) => r['code'] == 'refresh-inventory-change'), isTrue);
  });

  test('actual CLI plans offline, preserves files and reports invalid bases without starting a runtime', () async {
    final f = Fixture();
    f.changeDeclaration('a');
    final privateFile = p.join(f.app, 'moments/.backend/ui-session.json');
    f.put(privateFile, 'PRIVATE-SESSION-SENTINEL');
    f.put(p.join(f.root, '.gitignore'), 'app/moments/.backend/\n');
    f.git(['add', '.gitignore']);
    f.git(['commit', '-m', 'ignore private session']);
    final before = File(privateFile).readAsStringSync();
    final run = await moments(['affected', '--base', 'HEAD', '--json'], cwd: f.root);
    final result = (jsonDecode(run.stdout) as Map).cast<String, Object?>();
    expect(result['executed'], false);
    expect(names(result), ['a']);
    expect(run.stdout.contains(before), isFalse);
    expect(File(privateFile).readAsStringSync(), before);
    final missing = await moments(['affected', '--base', 'missing-ref', '--json'], cwd: f.root);
    expect(missing.code, 2);
    expect((jsonDecode(missing.stdout) as Map)['status'], 'unavailable');
    for (final args in [
      ['run', 'a', '--base', 'HEAD'],
      ['affected', '--base'],
      ['affected', '--base', 'HEAD', '--base', 'HEAD~1'],
      ['affected', '--fresh'],
    ]) {
      expect(() => parseArgs(args), throwsA(anything), reason: '$args');
    }
  });

  test('Dart delta selects only roots that transitively import it; global code still widens', () async {
    final f = Fixture(dartRoots: true);
    f.put(p.join(f.app, 'lib/helper.dart'), 'const value=1;');
    f.put(p.join(f.app, 'lib/a.dart'), "export 'helper.dart';");
    f.git(['add', 'app/lib']);
    f.git(['commit', '-m', 'import graph baseline']);
    f.put(p.join(f.app, 'lib/helper.dart'), 'const value=2;');
    final result = await f.affected();
    expect(result['precision'], 'dart-imports');
    expect(names(result), ['a']);
    expect(result['omitted'], ['b']);
    expect(result['executed'], false);
    f.put(p.join(f.app, 'lib/main.dart'), "import 'a.dart'; import 'b.dart'; void main(){}");
    expect((await f.affected())['precision'], 'whole-catalog');
  });

  test(
    'changes another app or an unresolved nested package cannot reach are ignored; a resolved shared package widens',
    () async {
      final f = Fixture(dartRoots: true);
      f.put(p.join(f.app, 'lib/helper.dart'), 'const value=1;');
      f.put(p.join(f.app, 'lib/a.dart'), "export 'helper.dart';");
      f.put(p.join(f.root, 'other/pubspec.yaml'), 'name: other\n');
      f.put(p.join(f.root, 'other/lib/x.dart'), '// other app');
      f.put(p.join(f.app, 'packages/legacy/pubspec.yaml'), 'name: legacy\n');
      f.put(p.join(f.app, 'packages/legacy/lib/api.dart'), '// old');
      f.put(p.join(f.root, 'shared/pubspec.yaml'), 'name: shared\n');
      f.put(p.join(f.root, 'shared/lib/s.dart'), '// v1');
      f.git(['add', '.']);
      f.git(['commit', '-m', 'neighbours']);
      f.put(p.join(f.root, 'other/lib/x.dart'), '// changed');
      f.put(p.join(f.app, 'packages/legacy/lib/api.dart'), '// changed');
      f.put(p.join(f.app, 'lib/helper.dart'), 'const value=2;');
      final narrowed = await f.affected();
      expect(narrowed['precision'], 'dart-imports');
      expect(names(narrowed), ['a']);
      expect(narrowed['ignoredChanges'], 2);
      f.put(p.join(f.root, 'deploy.toml'), '[unowned]');
      expect(reasons(await f.affected()).any((r) => (r['paths'] as List).contains('deploy.toml')), isTrue);
      File(p.join(f.root, 'deploy.toml')).deleteSync();
      final configFile = p.join(f.app, '.dart_tool/package_config.json');
      final config = (readJson(configFile)! as Map).cast<String, Object?>();
      (config['packages']! as List).add({
        'name': 'shared',
        'rootUri': '../../shared/',
        'packageUri': 'lib/',
        'languageVersion': '3.13',
      });
      f.put(configFile, jsonEncode(config));
      f.put(p.join(f.root, 'shared/lib/s.dart'), '// v2');
      final widened = await f.affected();
      expect(widened['precision'], 'whole-catalog');
      expect(
        reasons(
          widened,
        ).any((r) => r['code'] == 'shared-dart-package-change' && (r['paths'] as List).contains('shared/lib/s.dart')),
        isTrue,
      );
    },
  );

  test('conditional branches, exports and parts are included without parsing comments as directives', () async {
    final f = Fixture(dartRoots: true);
    f.put(
      p.join(f.app, 'lib/a.dart'),
      "import 'fallback.dart' if (dart.library.html) 'web.dart'; export 'barrel.dart'; part 'a_part.dart'; // import 'not-real.dart';\nconst text=\"import 'not-real.dart';\";",
    );
    for (final name in ['fallback', 'web', 'leaf']) {
      f.put(p.join(f.app, 'lib/$name.dart'), 'const value=1;');
    }
    f.put(p.join(f.app, 'lib/barrel.dart'), "export 'leaf.dart';");
    f.put(p.join(f.app, 'lib/a_part.dart'), "part of 'a.dart'; const partValue=1;");
    f.git(['add', 'app/lib']);
    f.git(['commit', '-m', 'conditional graph baseline']);
    for (final name in ['web', 'leaf', 'a_part']) {
      final file = p.join(f.app, 'lib/$name.dart'), before = File(file).readAsStringSync();
      f.put(file, '$before\n// changed');
      final result = await f.affected();
      expect(result['precision'], 'dart-imports', reason: name);
      expect(names(result), ['a']);
      f.put(file, before);
    }
  });

  test('shared dependencies select every importing root; deleted, unresolved and invalid syntax stay broad', () async {
    final f = Fixture(dartRoots: true);
    f.put(p.join(f.app, 'lib/helper.dart'), 'const value=1;');
    for (final name in ['a', 'b']) {
      f.put(p.join(f.app, 'lib/$name.dart'), "import 'helper.dart';");
    }
    f.git(['add', 'app/lib']);
    f.git(['commit', '-m', 'shared graph baseline']);
    f.put(p.join(f.app, 'lib/helper.dart'), 'const value=2;');
    final result = await f.affected();
    expect(result['precision'], 'dart-imports');
    expect(names(result), ['a', 'b']);
    File(p.join(f.app, 'lib/helper.dart')).deleteSync();
    expect((await f.affected())['precision'], 'whole-catalog');
    f.put(p.join(f.app, 'lib/helper.dart'), 'const value=;');
    expect((await f.affected())['precision'], 'whole-catalog');
    f.put(p.join(f.app, 'lib/helper.dart'), "import 'package:unknown/api.dart';");
    expect((await f.affected())['precision'], 'whole-catalog');
  });

  test('changing roots or Pub metadata cannot claim narrow impact', () async {
    final f = Fixture(dartRoots: true);
    f.put(p.join(f.app, 'lib/a.dart'), 'const a=1;');
    ((f.manifest['screens']! as Map)['/a'] as Map)['clientRoots'] = ['lib/b.dart'];
    f.save();
    expect((await f.affected())['precision'], 'whole-catalog');
    ((f.manifest['screens']! as Map)['/a'] as Map)['clientRoots'] = ['lib/a.dart'];
    f.save();
    f.put(p.join(f.app, 'pubspec.yaml'), 'name: renamed\n');
    expect((await f.affected())['precision'], 'whole-catalog');
  });

  test('an unavailable pinned Dart parser widens rather than silently omitting Moments', () async {
    final f = Fixture(dartRoots: true);
    final bin = temporary('mana-no-dart-');
    File(p.join(bin, 'dart')).writeAsStringSync('#!/bin/sh\nexit 2\n');
    Process.runSync('chmod', ['700', p.join(bin, 'dart')]);
    f.put(p.join(f.app, 'lib/a.dart'), 'const a=1;');
    final run = await moments(
      ['affected', '--json'],
      cwd: f.app,
      environment: {'PATH': '$bin:${Platform.environment['PATH']}'},
    );
    final result = (jsonDecode(run.stdout) as Map).cast<String, Object?>();
    expect(result['precision'], 'whole-catalog');
    expect(names(result), ['a', 'b']);
    expect(reasons(result).any((r) => r['code'] == 'dart-impact-unavailable'), isTrue);
  });

  test('affected navigation-only Moments remain selected without inventing test criteria', () async {
    final f = Fixture();
    f.moment('a')['checks'] = <Object?>[];
    f.moment('a')['steps'] = [
      {'name': 'edit', 'kind': 'fill', 'target': 'title', 'inputRef': 'draft.title', 'until': <Object?>[]},
    ];
    f.save();
    final result = await f.affected();
    expect(result['executed'], false);
    expect((result['selected']! as List).cast<Map>().firstWhere((x) => x['name'] == 'a')['operation'], 'navigate');
    f.moment('a')['steps'] = <Object?>[];
    f.save();
    expect(
      ((await f.affected())['selected']! as List).cast<Map>().firstWhere((x) => x['name'] == 'a')['operation'],
      'navigate',
    );
  });
}
