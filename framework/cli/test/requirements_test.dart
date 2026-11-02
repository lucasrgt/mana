import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// A project with an Ash backend, a Flutter app and a generated client, run
/// with only [tools] (name → script body) on the PATH and an empty HOME.
({String root, Map<String, String> env}) _project(Map<String, String> tools) {
  final (:root, :config) = fixture();
  config['products'] = {
    'demo': {
      'backend': 'backend',
      'frontend': ['app', 'packages/api'],
    },
  };
  save(root, config);
  for (final (path, body) in [
    ('backend/mix.exs', ''),
    ('app/pubspec.yaml', 'name: app\n'),
    ('packages/api/.mana/contract.json', '{}'),
  ]) {
    File(p.join(root, path))
      ..createSync(recursive: true)
      ..writeAsStringSync(body);
  }
  final bin = Directory(p.join(root, '.bin'))..createSync();
  for (final MapEntry(key: name, value: body) in tools.entries) {
    final tool = File(p.join(bin.path, name))
      ..writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['+x', tool.path]);
  }
  final home = Directory(p.join(root, '.home'))..createSync();
  return (
    root: root,
    env: {
      'PATH': bin.path,
      'HOME': home.path,
      'MANA_FRAMEWORK': frameworkRoot(),
    },
  );
}

void main() {
  compileFixtures();

  test('doctor names every tool the project needs that this machine lacks', () {
    final project = _project({});
    final result = invoke(project.root, ['doctor'], project.env);
    expect(result.exitCode, 1);
    final stderr = result.stderr as String;
    for (final gap in [
      'git is not on the PATH',
      'flutter is not on the PATH',
      'docker is not on the PATH',
      'oasdiff 1.33.0 is missing or changed: run mana contracts install',
      'OpenAPI Generator 7.25.0 is missing or changed: run mana contracts install',
      'Java runtime 21.0.13+9 (for OpenAPI Generator) is missing or changed: run mana contracts install',
    ]) {
      expect(stderr, contains(gap));
    }
  });

  test('doctor tells an unreachable Docker daemon from a missing one', () {
    final project = _project({
      'git': 'exit 0',
      'flutter': 'exit 0',
      'docker': 'echo "Cannot connect to the Docker daemon" >&2; exit 1',
    });
    final stderr = invoke(project.root, ['doctor'], project.env).stderr;
    expect(
      stderr,
      contains('Docker cannot reach its daemon (Cannot connect to the Docker'),
    );
    expect(stderr, isNot(contains('git is not')));
    expect(stderr, isNot(contains('flutter is not')));
  });

  test('with MANA_ELIXIR=local the backend needs mix, not Docker', () {
    final project = _project({'git': 'exit 0', 'flutter': 'exit 0'});
    final stderr = invoke(
      project.root,
      ['doctor'],
      {...project.env, 'MANA_ELIXIR': 'local'},
    ).stderr;
    expect(stderr, contains('MANA_ELIXIR=local, but mix is not on the PATH'));
    expect(stderr, isNot(contains('docker')));
  });

  test('mana new checks the machine before it writes anything', () {
    final parent = Directory.systemTemp.createTempSync('mana-new-');
    addTearDown(() => parent.deleteSync(recursive: true));
    final result = invoke(
      parent.path,
      ['new', 'demo'],
      {'PATH': p.join(parent.path, 'empty')},
    );
    expect(result.exitCode, 1);
    expect(result.stderr, contains('flutter is not on the PATH'));
    expect(result.stderr, contains('docker is not on the PATH'));
    expect(Directory(p.join(parent.path, 'demo')).existsSync(), isFalse);
  });

  test('a file found on the PATH counts only when it can run', () {
    final bin = Directory.systemTemp.createTempSync('mana-path-');
    addTearDown(() => bin.deleteSync(recursive: true));
    final tool = File(p.join(bin.path, 'tool'))..writeAsStringSync('');
    expect(onPath('tool', path: bin.path), isNull);
    Process.runSync('chmod', ['+x', tool.path]);
    expect(onPath('tool', path: '/nonexistent:${bin.path}'), tool.path);
  });
}
