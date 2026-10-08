import 'dart:convert';
import 'dart:io';

import 'package:moments/src/dart_sources.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/runtime.dart';
import 'package:moments/src/watch.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// An app depending on a local `shared` package by path.
final class Fixture {
  Fixture() : root = temporary('dart-sources-') {
    project = p.join(root, 'app');
    dependency = p.join(root, 'shared');
    for (final dir in [
      p.join(project, 'lib'),
      p.join(project, '.dart_tool'),
      p.join(project, 'moments'),
      p.join(dependency, 'lib'),
    ]) {
      Directory(dir).createSync(recursive: true);
    }
    put(p.join(project, 'pubspec.yaml'), 'name: app\ndependencies:\n  shared:\n    path: ../shared\n');
    put(p.join(dependency, 'pubspec.yaml'), 'name: shared\nversion: 1.0.0\n');
    put(
      p.join(project, 'pubspec.lock'),
      'packages:\n  shared:\n    source: path\n    version: "1.0.0"\n    description:\n      path: ../shared\n      relative: true\n',
    );
    config = p.join(project, '.dart_tool/package_config.json');
    put(
      config,
      jsonEncode({
        'configVersion': 2,
        'generatorVersion': '3.13.2',
        'packages': [
          {'name': 'app', 'rootUri': '../', 'packageUri': 'lib/', 'languageVersion': '3.13'},
          {'name': 'shared', 'rootUri': '../../shared', 'packageUri': 'lib/', 'languageVersion': '3.13'},
        ],
      }),
    );
    put(p.join(project, 'lib/main.dart'), '// app');
    put(p.join(project, 'lib/helper.dart'), '// helper outside explicit watch');
    put(p.join(dependency, 'lib/shared.dart'), '// PRIVATE SOURCE CONTENT');
    writeJson(p.join(project, 'moments/manifest.json'), {
      'version': 1,
      'properties': {
        'route': {
          'enum': ['/inbox'],
        },
      },
      'watch': ['lib/main.dart'],
      'moments': {
        'inbox': {
          'projection': {'route': '/inbox'},
          'checks': [
            {'name': 'ready', 'kind': 'restored'},
          ],
        },
      },
    });
    inventory = DartSources(project, const ['lib/main.dart']);
  }

  final String root;
  late final String project, dependency, config;
  late final DartSources inventory;

  void put(String file, String text) => File(file).writeAsStringSync(text);
  String digest({bool fresh = false}) => inventory.snapshot(fresh: fresh)['digest']! as String;
}

final class Machine implements WatchedMachine {
  var runs = 0;
  @override
  bool ready() => true;
  @override
  Future<Object?> restart({bool fullRestart = true}) async => runs++;
}

final class Runtime implements WatchedMoments {
  Runtime(this.fingerprint);
  final String Function() fingerprint;
  @override
  String sourceFingerprint() => fingerprint();
  @override
  bool hasRuntimeClaim() => true;
  @override
  bool hasObservedRuntime() => true;
  @override
  bool canReload() => false;
  @override
  Map<String, Object?> checkpoint() => const {};
  @override
  Future<void Function()> prepareRestart() async => () {};
  @override
  String requestFrame(Map<String, Object?> checkpoint) => throw const MomentsError('No frames');
  @override
  void cancelFrame(String id) {}
  @override
  Map<String, Object?>? blockerAfter(Map<String, Object?> checkpoint, {bool fullRestart = false, String? frameId}) =>
      null;
  @override
  Map<String, Object?>? restorationAfter(Map<String, Object?> checkpoint) => {'name': 'inbox'};
  @override
  Map<String, Object?>? frameAfter(String id) => null;
  @override
  void markCodeApplied(Map<String, Object?> checkpoint) {}
}

void main() {
  test('resolved app and local libraries have portable identity without copying source contents', () {
    final a = Fixture(), b = Fixture();
    final first = a.inventory.snapshot();
    expect(first['packageCount'], 2);
    expect(first['fileCount'], 3);
    expect(first['digest'], b.digest());
    expect((first['files']! as Map).keys, ['lib/helper.dart', 'lib/main.dart', 'package:shared/lib/shared.dart']);
    expect(jsonEncode(first).contains('PRIVATE SOURCE CONTENT'), isFalse);
    a.put(p.join(a.dependency, 'README.md'), 'docs');
    a.put(p.join(a.dependency, '.env'), 'private');
    expect(a.digest(), first['digest']);
    a.put(p.join(a.project, 'lib/helper.dart'), '// helper edited');
    expect(a.digest(), isNot(first['digest']));
  });

  test('atomic replacement, same-size writes, additions, renames and deletions invalidate identity', () {
    final f = Fixture(), file = p.join(f.dependency, 'lib/shared.dart');
    var previous = f.digest();
    void changed() {
      final next = f.digest();
      expect(next, isNot(previous));
      previous = next;
    }

    final modified = File(file).lastModifiedSync();
    f.put(file, '// private source content');
    File(file).setLastModifiedSync(modified);
    changed();
    f.put('$file.tmp', '// replacement');
    File('$file.tmp').renameSync(file);
    changed();
    final added = p.join(f.dependency, 'lib/added.dart');
    f.put(added, '// new');
    changed();
    File(added).renameSync(p.join(f.dependency, 'lib/renamed.dart'));
    changed();
    File(p.join(f.dependency, 'lib/renamed.dart')).deleteSync();
    changed();
    expect(f.digest(fresh: true), previous);
  });

  test('missing or conflicting package resolution and symlink escapes fail closed', () {
    final f = Fixture();
    f.inventory.snapshot();
    final original = File(f.config).readAsStringSync();
    final config = (jsonDecode(original) as Map).cast<String, Object?>();
    ((config['packages']! as List)[1] as Map)['rootUri'] = '../';
    f.put(f.config, jsonEncode(config));
    expect(f.inventory.snapshot, throwing('differs from pubspec.lock'));
    f.put(f.config, original);
    Link(p.join(f.dependency, 'lib/escape.dart')).createSync(p.join(f.project, 'lib/main.dart'));
    expect(f.inventory.snapshot, throwing('Symlinks'));
    Link(p.join(f.dependency, 'lib/escape.dart')).deleteSync();
    File(f.config).deleteSync();
    expect(f.inventory.snapshot, throwing('flutter pub get'));
  });

  test('changing a cached package root is not hidden by an unchanged package_config', () {
    final f = Fixture();
    f.inventory.snapshot();
    Directory(f.dependency).renameSync('${f.dependency}-moved');
    Link(f.dependency).createSync('${f.dependency}-moved');
    expect(f.inventory.snapshot, throwing('package root changed'));
  });

  test('invalid manifests do not expose YAML source fragments in diagnostics', () {
    final f = Fixture();
    f.put(p.join(f.project, 'pubspec.yaml'), 'name: [PRIVATE_CONFIGURATION_SENTINEL');
    expect(
      f.inventory.snapshot,
      throwsA(predicate((e) => '$e'.contains('Cannot parse Pub') && !'$e'.contains('PRIVATE_CONFIGURATION_SENTINEL'))),
    );
  });

  test('runtime refuses stale shared code immediately and dependency changes require launcher restart', () {
    final f = Fixture();
    final runtime = Moments.create(
      f.project,
      MomentsOptions(manifestFile: p.join(f.project, 'moments/manifest.json'), initialName: 'inbox'),
    )!;
    addTearDown(runtime.close);
    expect(runtime.inspect()['codeChanged'], false);
    f.put(p.join(f.dependency, 'lib/shared.dart'), '// changed before watcher tick');
    expect(runtime.inspect()['codeChanged'], true);
    runtime.open('inbox', fresh: true);
    expect(runtime.inspect()['codeChanged'], true, reason: 'Opening a fresh situation cannot mark edited code applied');
    runtime.markCodeApplied(runtime.checkpoint());
    expect((runtime.inspect()['dart']! as Map)['applied'], f.digest());
    f.put(p.join(f.dependency, 'pubspec.yaml'), 'name: shared\nversion: 1.0.1\n');
    expect((runtime.inspect()['dart']! as Map)['resolutionChanged'], true);
    expect(runtime.checkpoint, throwing('restart the Moments launcher'));
    runtime.open('inbox', fresh: true);
    expect(runtime.inspect()['codeChanged'], true, reason: 'Fresh UI cannot bless unresolved dependency edits');
  });

  test('watcher uses the same inventory, including new dependency files', () async {
    final f = Fixture();
    final machine = Machine();
    final watcher = MomentWatcher(
      project: f.project,
      paths: const ['lib/main.dart'],
      machine: machine,
      moments: Runtime(() => f.digest()),
      interval: const Duration(milliseconds: 5),
      debounce: const Duration(milliseconds: 5),
      log: (_) {},
    );
    addTearDown(watcher.close);
    f.put(p.join(f.dependency, 'lib/new.dart'), '// new dependency source');
    for (var i = 0; machine.runs < 1 && i < 200; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(machine.runs, 1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(watcher.status()['phase'], 'ready');
  });
}
