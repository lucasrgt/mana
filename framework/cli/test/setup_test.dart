import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  compileFixtures();

  test(
    'setup runs dependency argv literally, installs pinned artifact and preserves repeat setup',
    () {
      final (:root, :config) = fixture();
      final source = File(p.join(root, 'binary'))
        ..writeAsStringSync('#!/bin/sh\nexit 0\n');
      config['setup'] = {
        'artifacts': [
          {
            'source': source.path,
            'path': '.mana/bin/search',
            'sha256': digest(source.readAsBytesSync()),
          },
        ],
        'tasks': [
          {
            'name': 'deps',
            'command': [
              taskBinary,
              'write',
              'dependency-result',
              r'$(touch unwanted)',
            ],
          },
        ],
      };
      save(root, config);
      for (var i = 0; i < 2; i++) {
        final result = invoke(root, ['setup']);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          File(p.join(root, 'dependency-result')).readAsStringSync(),
          r'$(touch unwanted)',
        );
        expect(File(p.join(root, 'unwanted')).existsSync(), isFalse);
        expect(
          Link(p.join(root, '.agents/skills/local')).targetSync(),
          '../../agents/skills/local',
        );
      }
      expect(
        File(p.join(root, '.mana/bin/search')).readAsStringSync(),
        source.readAsStringSync(),
      );
      expect(invoke(root, ['doctor']).exitCode, 0);
    },
  );

  test('bad checksum and unknown fields fail before dependency execution', () {
    final (:root, :config) = fixture();
    File(p.join(root, 'source')).writeAsStringSync('bad');
    config['setup'] = {
      'artifacts': [
        {'source': 'source', 'path': '.mana/bin/search', 'sha256': '0' * 64},
      ],
      'tasks': [
        {
          'name': 'deps',
          'command': [taskBinary, 'write', 'ran', 'yes'],
        },
      ],
    };
    save(root, config);
    expect(invoke(root, ['setup']).stderr, contains('checksum mismatch'));
    expect(File(p.join(root, 'ran')).existsSync(), isFalse);
    expect(File(p.join(root, '.mana/bin/search')).existsSync(), isFalse);
    agents(config, 'claude')['skill'] = ['typo'];
    save(root, config);
    expect(
      invoke(root, ['setup']).stderr,
      contains('Unknown agents.claude.skill'),
    );
  });

  test('hand-owned and changed skills are never replaced', () {
    final (:root, :config) = fixture();
    Directory(p.join(root, '.agents/skills/local')).createSync(recursive: true);
    File(p.join(root, '.agents/skills/local/user')).writeAsStringSync('mine');
    expect(
      invoke(root, ['setup']).stderr,
      contains('Refusing to overwrite skill'),
    );
    expect(
      File(p.join(root, '.agents/skills/local/user')).readAsStringSync(),
      'mine',
    );
    Directory(p.join(root, '.agents')).deleteSync(recursive: true);
    expect(invoke(root, ['setup']).exitCode, 0);
    agents(config, 'codex')['skills'] = <String>[];
    save(root, config);
    expect(invoke(root, ['setup']).exitCode, 0);
    expect(
      FileSystemEntity.typeSync(
        p.join(root, '.agents/skills/local'),
        followLinks: false,
      ),
      FileSystemEntityType.notFound,
    );
  });

  test(
    'task failure stops later tasks and releases lock; interrupted lock never replays',
    () {
      final (:root, :config) = fixture();
      config['setup'] = {
        'tasks': [
          {
            'name': 'fail',
            'command': [taskBinary, 'exit', '7'],
          },
          {
            'name': 'later',
            'command': [taskBinary, 'write', 'ran', 'yes'],
          },
        ],
      };
      save(root, config);
      expect(invoke(root, ['setup']).stderr, contains('fail (exit 7)'));
      expect(File(p.join(root, 'ran')).existsSync(), isFalse);
      expect(File(p.join(root, '.mana/setup.lock')).existsSync(), isFalse);
      File(p.join(root, '.mana/setup.lock')).writeAsStringSync('interrupted');
      expect(invoke(root, ['setup']).stderr, contains('locked'));
      expect(
        File(p.join(root, '.mana/setup.lock')).readAsStringSync(),
        'interrupted',
      );
    },
  );

  test(
    'path traversal, dangling links, conflicting manifests and invalid TOML are rejected',
    () {
      final (:root, :config) = fixture();
      agents(config, 'claude')['mods'] = ['../outside'];
      save(root, config);
      expect(invoke(root, ['setup']).stderr, contains('escapes project'));
      agents(config, 'claude')['mods'] = ['agents/missing'];
      save(root, config);
      Link(p.join(root, 'agents/missing')).createSync('/nonexistent/mana');
      expect(invoke(root, ['setup']).stderr, contains('Symlink'));
      File(p.join(root, 'mana.json')).writeAsStringSync('{}');
      expect(invoke(root, ['setup']).stderr, contains('Both mana.toml'));
      File(p.join(root, 'mana.json')).deleteSync();
      File(p.join(root, 'mana.toml')).writeAsStringSync('version = [');
      expect(invoke(root, ['setup']).exitCode, isNot(0));
    },
  );

  test('corrupt installed artifact is rejected instead of overwritten', () {
    final (:root, :config) = fixture();
    File(p.join(root, 'source')).writeAsStringSync('valid');
    config['setup'] = {
      'artifacts': [
        {
          'source': 'source',
          'path': '.mana/bin/search',
          'sha256': digest('valid'.codeUnits),
        },
      ],
    };
    save(root, config);
    expect(invoke(root, ['setup']).exitCode, 0);
    File(p.join(root, '.mana/bin/search')).writeAsStringSync('edited');
    expect(
      invoke(root, ['setup']).stderr,
      contains('differs from pinned checksum'),
    );
    expect(
      invoke(root, ['agent', 'claude', '--print']).stderr,
      contains('differs from pinned checksum'),
    );
    expect(File(p.join(root, '.mana/bin/search')).readAsStringSync(), 'edited');
  });

  test(
    'runtime-only installs dependencies without requiring agent artifacts or writing agent settings',
    () {
      final (:root, :config) = fixture();
      config['setup'] = {
        'artifacts': [
          {
            'source': r'${MANA_TEST_UNAVAILABLE_BINARY}',
            'path': '.mana/bin/fff',
            'sha256': 'a' * 64,
          },
        ],
        'tasks': [
          {
            'name': 'runtime',
            'command': [taskBinary, 'write', 'runtime-ready', 'yes'],
          },
        ],
      };
      save(root, config);
      Directory(p.join(root, 'agents')).deleteSync(recursive: true);
      final result = invoke(root, ['setup', '--runtime-only']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(File(p.join(root, 'runtime-ready')).readAsStringSync(), 'yes');
      for (final path in [
        '.mana/bin',
        '.agents',
        '.mana/codex-skills.json',
        '.mana/setup.lock',
      ]) {
        expect(
          FileSystemEntity.typeSync(p.join(root, path)),
          FileSystemEntityType.notFound,
          reason: path,
        );
      }
      for (final args in [
        ['setup', '--runtime-only', '--agents', 'codex'],
        ['setup', '--runtime-only', '--skip-tasks'],
        ['doctor', '--runtime-only'],
        ['agent', 'codex', '--runtime-only'],
      ]) {
        expect(
          invoke(root, args).stderr,
          contains('exclusive to setup'),
          reason: '$args',
        );
      }
      // Default setup still enforces agent configuration and does not silently
      // discard a missing binary or missing authored skill.
      expect(invoke(root, ['setup']).exitCode, isNot(0));
    },
  );

  test('products declare existing backend and frontend directories', () {
    final (:root, :config) = fixture();
    Directory(p.join(root, 'backend')).createSync();
    Directory(p.join(root, 'apps/web')).createSync(recursive: true);
    config['products'] = {
      'web': {
        'backend': 'backend',
        'frontend': ['apps/web'],
      },
      'site': {'frontend': 'apps/web'},
    };
    save(root, config);
    final result = invoke(root, ['doctor']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('web: backend + apps/web'));
    config['products'] = {
      'web': {
        'backend': 'backend',
        'frontend': ['apps/missing'],
      },
    };
    save(root, config);
    expect(
      invoke(root, ['doctor']).stderr,
      contains('Missing product directory: web -> apps/missing'),
    );
    config['products'] = {'web': <String, Object?>{}};
    save(root, config);
    expect(
      invoke(root, ['doctor']).stderr,
      contains('declare a backend, a frontend or both'),
    );
  });
}
