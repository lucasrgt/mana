import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  compileFixtures();
  setUpAll(installToolchain);

  test(
    'the client is generated on the pinned Java runtime, not a java on the PATH',
    () {
      final work = Directory.systemTemp.createTempSync('mana-java-');
      addTearDown(() => work.deleteSync(recursive: true));
      // A java that always fails comes first on the PATH, whatever this
      // machine has installed.
      final shim = Directory(p.join(work.path, 'bin'))..createSync();
      File(
        p.join(shim.path, 'java'),
      ).writeAsStringSync('#!/bin/sh\necho "java on the PATH" >&2\nexit 1\n');
      Process.runSync('chmod', ['+x', p.join(shim.path, 'java')]);
      final path = [
        shim.path,
        p.dirname(Platform.resolvedExecutable),
        Platform.environment['PATH']!,
      ].join(':');
      final result = invoke(
        work.path,
        [
          'client',
          'generate',
          '--input',
          p.absolute('test/fixtures/client/contract.json'),
          '--output',
          p.join(work.path, 'packages/api'),
          '--name',
          'fixture_api',
        ],
        {'PATH': path, 'MANA_FRAMEWORK': frameworkRoot()},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final provenance =
          jsonDecode(
                File(
                  p.join(work.path, 'packages/api/.mana/client.json'),
                ).readAsStringSync(),
              )
              as Map;
      expect(provenance['generator'], containsPair('version', '7.25.0'));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('the pinned Java runtime is the version toolchain.json names', () {
    final version = Process.runSync(javaBinary(), ['-version']);
    expect(version.exitCode, 0);
    expect(
      version.stderr,
      contains('Temurin-${(pinnedToolchain()['java']! as Map)['version']}'),
    );
  });

  test(
    'a tree digest covers bytes, the owner execute bit and link targets',
    () {
      final tree = Directory.systemTemp.createTempSync('mana-tree-');
      addTearDown(() => tree.deleteSync(recursive: true));
      final file = File(p.join(tree.path, 'bin/tool'))
        ..createSync(recursive: true)
        ..writeAsStringSync('a');
      final link = Link(p.join(tree.path, 'lib'))..createSync('bin');
      final digest = treeSha256(tree.path);
      for (final (change, undo) in [
        (() => file.writeAsStringSync('b'), () => file.writeAsStringSync('a')),
        (
          () => Process.runSync('chmod', ['u+x', file.path]),
          () => Process.runSync('chmod', ['u-x', file.path]),
        ),
        (() => link.updateSync('bin/tool'), () => link.updateSync('bin')),
        (
          () => Directory(p.join(tree.path, 'empty')).createSync(),
          () => Directory(p.join(tree.path, 'empty')).deleteSync(),
        ),
      ]) {
        change();
        expect(treeSha256(tree.path), isNot(digest));
        undo();
        expect(treeSha256(tree.path), digest);
      }
      // Group and others' bits follow the umask, not the archive.
      Process.runSync('chmod', ['go-r', file.path]);
      expect(treeSha256(tree.path), digest);
    },
  );

  test('a Java runtime changed after install is refused by name', () {
    final home = Directory.systemTemp.createTempSync('mana-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    final installed = cacheDirectory(['contracts', 'java']);
    final copy = p.join(home.path, '.cache/mana/contracts/java');
    Directory(copy).createSync(recursive: true);
    Process.runSync('cp', ['-R', '$installed/.', copy]);
    final release = Directory(copy)
        .listSync(recursive: true)
        .whereType<File>()
        .firstWhere((file) => p.basename(file.path) == 'release');
    final env = {'HOME': home.path, 'MANA_FRAMEWORK': frameworkRoot()};
    String gaps() =>
        invoke(home.path, [
              'client',
              'generate',
              '--jar',
              generatorJar(),
              '--input',
              'missing.json',
              '--output',
              'api',
              '--name',
              'api',
            ], env).stderr
            as String;
    expect(gaps(), isNot(contains('Java runtime')));
    release.writeAsStringSync('${release.readAsStringSync()}\n');
    expect(
      gaps(),
      contains(
        'Pinned Java runtime is missing or changed; run mana contracts install',
      ),
    );
  });
}
