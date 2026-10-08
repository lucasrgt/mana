import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:moments/src/inspect_compact.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Map<String, Object?> copy(Object? value) => (jsonDecode(jsonEncode(value)) as Map).cast();

({Map<String, Object?> full, Map<String, Object?> manifest}) fixture() {
  final projection = {'route': '/inbox', 'filter': 'reservation', 'scrollOffset': 80, 'ids': 'one,two'};
  final checks = [
    {'name': 'restored', 'kind': 'restored', 'field': 'filter', 'equals': 'reservation'},
    {'name': 'unread', 'kind': 'backend_equals', 'field': 'allUnread', 'equals': true, 'match': 'ids'},
  ];
  return (
    manifest: copy({
      'version': 2,
      'watch': ['inbox.dart', 'unrelated.dart'],
      'screens': {
        '/inbox': {
          'watch': ['inbox.dart'],
        },
        '/other': {
          'watch': ['unrelated.dart'],
        },
      },
      'moments': {
        'inbox': {'description': 'Current scene', 'projection': projection, 'checks': checks},
        'other': {
          'projection': {'route': '/other'},
          'checks': <Object?>[],
        },
      },
    }),
    full: copy({
      'project': '/app',
      'inspectedAt': 'now',
      'moment': {
        'name': 'inbox',
        'revision': 'revision',
        'savedProjection': projection,
        'codeChanged': false,
        'recipeChanged': false,
      },
      'screen': {
        'status': 'last-reported',
        'liveness': 'not-probed',
        'lastReported': {'projection': projection, 'reportedAt': 'before', 'ageMs': 100, 'matchesRevision': true},
      },
      'backend': {
        'status': 'ready',
        'source': 'local-api',
        'observedAt': 'now',
        'projection': {'ids': 'one,two', 'allUnread': true, 'unneeded': 'unrelated detail'},
      },
      'sources': {
        'declaration': '/app/moments/manifest.json',
        'watched': ['inbox.dart', 'unrelated.dart'],
      },
      'editing': {
        'properties': {'unneeded': 'legacy editing context'},
      },
      'catalog': [
        {'name': 'other'},
      ],
      'supervisor': {
        'phase': 'ready',
        'pending': false,
        'held': false,
        'paths': ['inbox.dart', 'unrelated.dart'],
      },
      'commands': {
        'patch': ['legacy'],
      },
    }),
  );
}

Map<String, Object?> at(Map<String, Object?> value, String key) => (value[key]! as Map).cast();
Map<String, Object?> moments(Map<String, Object?> manifest) => at(manifest, 'moments');
Map<String, Object?> inbox(Map<String, Object?> manifest) => at(moments(manifest), 'inbox');

void main() {
  test('scopes sources and backend fields, keeps criteria, and does not duplicate identical UI state', () {
    final (:full, :manifest) = fixture();
    final before = copy(full);
    final value = compactInspection(full, manifest);
    expect(at(value, 'sources')['watched'], ['inbox.dart']);
    expect(at(value, 'moment')['savedProjection'], at(full, 'moment')['savedProjection']);
    final reported = at(at(value, 'screen'), 'lastReported');
    expect(reported['matchesSaved'], true);
    expect(reported.containsKey('projection'), isFalse);
    expect(at(value, 'backend')['projection'], {'ids': 'one,two', 'allUnread': true});
    expect(value['criteria'], {'status': 'declared', 'executed': false, 'items': inbox(manifest)['checks']});
    expect(jsonEncode(value).contains('unrelated'), isFalse);
    expect(value.containsKey('editing'), isFalse);
    expect(value.containsKey('catalog'), isFalse);
    expect(full, before, reason: 'Inspection must not modify its input');
  });

  test('a differing or stale UI observation is retained, never promoted to an approval', () {
    final (:full, :manifest) = fixture();
    final screen = at(full, 'screen');
    screen['lastReported'] = {
      ...at(screen, 'lastReported'),
      'projection': {...at(at(full, 'moment'), 'savedProjection'), 'scrollOffset': 0},
      'matchesRevision': false,
      'ageMs': 900000,
    };
    final value = compactInspection(full, manifest);
    final reported = at(at(value, 'screen'), 'lastReported');
    expect(reported['matchesSaved'], false);
    expect(at(reported, 'projection')['scrollOffset'], 0);
    expect(reported['matchesRevision'], false);
    expect(reported['ageMs'], 900000);
    expect(at(value, 'screen')['liveness'], 'not-probed');
    expect(at(value, 'criteria')['executed'], false);
  });

  test('no UI observation and unavailable backend remain explicitly unavailable', () {
    final (:full, :manifest) = fixture();
    at(full, 'screen')
      ..['lastReported'] = null
      ..['status'] = 'awaiting-runtime';
    full['backend'] = {'status': 'unavailable', 'reason': 'Local backend unavailable'};
    final value = compactInspection(full, manifest);
    expect(at(value, 'screen')['lastReported'], isNull);
    expect(at(value, 'backend')['reason'], 'Local backend unavailable');
    expect(at(value, 'criteria')['executed'], false);
  });

  test('declared scene without checks differs from a missing declaration', () {
    final (:full, :manifest) = fixture();
    inbox(manifest)['checks'] = <Object?>[];
    expect(at(compactInspection(full, manifest), 'criteria')['status'], 'none');
    moments(manifest).remove('inbox');
    final missing = compactInspection(full, manifest);
    expect(at(missing, 'criteria')['status'], 'unavailable');
    expect(at(missing, 'sources')['watched'], <Object?>[]);
    expect(at(missing, 'sources')['issue'], isNotNull);
  });

  test('route mismatch cannot select unrelated screen sources or checks', () {
    final (:full, :manifest) = fixture();
    inbox(manifest)['projection'] = {'route': '/other'};
    final value = compactInspection(full, manifest);
    expect(at(value, 'sources')['watched'], <Object?>[]);
    expect(at(value, 'criteria')['status'], 'unavailable');
  });

  test('idle inspection and legacy single-screen declarations remain supported', () {
    final (:full, :manifest) = fixture();
    final legacy = {
      'version': 1,
      'watch': ['inbox.dart'],
      'properties': {
        'route': {
          'enum': ['/inbox'],
        },
      },
      'moments': manifest['moments'],
    };
    expect(at(compactInspection(full, legacy), 'sources')['watched'], ['inbox.dart']);
    full['moment'] = null;
    at(full, 'screen')
      ..['lastReported'] = null
      ..['status'] = 'idle';
    final idle = compactInspection(full, manifest);
    expect(idle['moment'], isNull);
    expect(at(idle, 'criteria')['status'], 'unavailable');
    expect(at(idle, 'sources')['watched'], <Object?>[]);
  });

  test('Ash location resolves in the local checkout and detects unsynced edits and missing files', () {
    final root = temporary('moment-ash-origin-');
    final file = p.join(root, 'moments/ash/lib/inbox.ex');
    Directory(p.dirname(file)).createSync(recursive: true);
    const text = 'defmodule Inbox do\n  moment :inbox do\n  end\nend\n';
    File(file).writeAsStringSync(text);
    final (:full, :manifest) = fixture();
    full['project'] = root;
    at(full, 'sources')['declaration'] = p.join(root, 'moments/manifest.json');
    inbox(manifest)['source'] = {
      'file': 'ash/lib/inbox.ex',
      'line': 2,
      'module': 'Inbox',
      'sha256': sha256.convert(utf8.encode(text)).toString(),
    };
    Map<String, Object?> origin() => at(at(compactInspection(full, manifest), 'sources'), 'ash');
    expect(origin(), {'file': file, 'line': 2, 'module': 'Inbox', 'status': 'current'});
    File(file).writeAsStringSync('# inserted line\n$text');
    expect(origin()['status'], 'stale');
    expect(origin()['reason'], contains('moments sync'));
    expect(at(compactInspection(full, manifest), 'criteria')['executed'], false);
    File(file).deleteSync();
    expect(origin()['status'], 'unavailable');
    expect(origin()['file'], file);
  });

  test('old or malformed metadata never invents an Ash source location', () {
    final (:full, :manifest) = fixture();
    expect(at(at(compactInspection(full, manifest), 'sources'), 'ash')['status'], 'unavailable');
    for (final source in [
      {'file': '/workspace/private.ex', 'line': 1},
      {'file': 'wrong.txt', 'line': 1},
      {'file': 'ash/lib/view.ex', 'line': 0},
    ]) {
      inbox(manifest)['source'] = source;
      final origin = at(at(compactInspection(full, manifest), 'sources'), 'ash');
      expect(origin['status'], 'unavailable');
      expect(origin.containsKey('file'), isFalse);
    }
  });
}
