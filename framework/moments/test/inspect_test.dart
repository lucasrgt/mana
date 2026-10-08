import 'dart:io';

import 'package:moments/src/bridge.dart';
import 'package:moments/src/errors.dart';
import 'package:moments/src/inspect.dart';
import 'package:moments/src/runtime.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

final class Idle implements Renewal {
  @override
  Map<String, Object?> status() => {'phase': 'idle'};
  @override
  Map<String, Object?> start(Object? name) => throw const MomentsError('Not in this test');
  @override
  bool canRenew(String name) => true;
}

final class Dev implements Development {
  Dev(this._inspect);
  final Future<Map<String, Object?>> Function() _inspect;
  @override
  Map<String, Object?> status() => {'phase': 'idle'};
  @override
  Future<Map<String, Object?>> Function()? get inspect => _inspect;
  @override
  Map<String, Object?> Function(Map<String, Object?> input)? get refresh => null;
  @override
  Future<void> Function()? get stop => null;
  @override
  Renewal? get renewal => Idle();
}

Future<int> status(Bridge bridge, String path, Map<String, String> headers) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('${bridge.url}$path'));
    headers.forEach(request.headers.set);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

Map<String, Object?> at(Map<String, Object?> value, String key) => (value[key]! as Map).cast();

void main() {
  test(
    'inspect scopes source context, separates evidence, and never mutates the session or reveals bootstrap',
    () async {
      final root = temporary('moment-inspect-');
      for (final dir in ['lib', 'moments', 'live-ui']) {
        Directory(p.join(root, dir)).createSync();
      }
      final initial = {'route': '/reservations', 'filter': 'all'};
      writeJson(p.join(root, 'moments/manifest.json'), {
        'version': 1,
        'liveUiPrefix': 'reservations.',
        'watch': ['lib/view.dart'],
        'properties': {
          'route': {
            'enum': ['/reservations'],
          },
          'filter': {
            'enum': ['all', 'confirmed'],
          },
        },
        'moments': {
          'checkout': {'description': 'Local reservation', 'projection': initial},
        },
      });
      File(p.join(root, 'lib/view.dart')).writeAsStringSync('const gap = SpaceToken.md;');
      writeJson(p.join(root, 'lib/text.arb'), {'title': 'Source title'});
      writeJson(p.join(root, 'live-ui/schema.json'), {
        'reservations.title': {'type': 'text', 'maxLength': 80},
        'reservations.gap': {
          'enum': ['md', 'lg'],
        },
        'signup.title': {'type': 'text'},
      });
      writeJson(p.join(root, 'live-ui/targets.json'), {
        'reservations.title': {'kind': 'arb', 'file': 'lib/text.arb', 'key': 'title'},
        'reservations.gap': {'kind': 'dartEnum', 'file': 'lib/view.dart', 'symbol': 'gap', 'type': 'SpaceToken'},
      });
      writeJson(p.join(root, 'live-ui/overrides.json'), {
        'version': 1,
        'values': {'reservations.title': 'Preview title', 'signup.title': 'Unrelated surface'},
      });
      var reads = 0, backendAvailable = true;
      final bridge = await Bridge.start(
        directory: p.join(root, 'live-ui'),
        port: 0,
        momentsOptions: MomentsOptions(
          directory: p.join(root, 'moments'),
          manifestFile: p.join(root, 'moments/manifest.json'),
          initialName: 'checkout',
        ),
        bootstrap: () => {
          'account': {'password': 'private-bootstrap'},
          'apiUrl': 'http://127.0.0.1:5187',
        },
        development: Dev(() async {
          reads++;
          if (!backendAvailable) throw Exception('private-backend-error');
          return {
            'status': 'ready',
            'source': 'isolated-postgres',
            'observedAt': DateTime.now().toUtc().toIso8601String(),
          };
        }),
      );
      addTearDown(bridge.close);
      Future<Map<String, Object?>> request(String path, [Map<String, Object?>? data]) async {
        final answer = await call(bridge.url, bridge.token, path, data);
        expect(answer.code, 200);
        return answer.value;
      }

      expect(await status(bridge, '/moments/inspect', {}), 401);
      expect(
        await status(bridge, '/moments/inspect', {
          'Authorization': 'Bearer ${bridge.token}',
          'Origin': 'https://outside.example',
        }),
        403,
      );
      expect(reads, 0);
      expect(at(await request('/moments/inspect'), 'screen')['status'], 'awaiting-runtime');
      final runtime = await request('/moments/changes?since=&client=screen');
      await request('/moments/observe', {'client': 'screen', 'revision': runtime['revision'], 'projection': initial});
      final sessionBefore = File(p.join(root, 'moments/.session.json')).readAsStringSync();
      final previewBefore = File(p.join(root, 'live-ui/overrides.json')).readAsStringSync();
      final context = await request('/moments/inspect');
      expect(at(context, 'moment')['name'], 'checkout');
      final screen = at(context, 'screen');
      expect(screen['status'], 'last-reported');
      expect(screen['liveness'], 'not-probed');
      expect(at(screen, 'lastReported')['matchesRevision'], true);
      expect(at(screen, 'lastReported')['ageMs'] as num, greaterThanOrEqualTo(0));
      final properties = at(at(context, 'editing'), 'properties');
      expect(properties.keys, ['reservations.title', 'reservations.gap']);
      expect(at(properties, 'reservations.title')['sourceDefault'], 'Source title');
      expect(at(properties, 'reservations.title')['configuredValue'], 'Preview title');
      expect(at(properties, 'reservations.gap')['sourceDefault'], 'md');
      expect(at(context, 'editing')['previewAcknowledged'], false);
      expect(at(context, 'commands')['renew'], ['renew', 'checkout']);
      expect(at(context, 'commands')['incorporate'], ['live', 'incorporate', '--write', '--prefix', 'reservations.']);
      final serialized = context.toString();
      for (final secret in ['private-bootstrap', bridge.token, 'Unrelated surface']) {
        expect(serialized.contains(secret), isFalse, reason: secret);
      }
      expect(File(p.join(root, 'moments/.session.json')).readAsStringSync(), sessionBefore);
      expect(File(p.join(root, 'live-ui/overrides.json')).readAsStringSync(), previewBefore);
      backendAvailable = false;
      final partial = await request('/moments/inspect');
      expect(at(partial, 'backend')['status'], 'unavailable');
      expect(at(partial, 'moment')['name'], 'checkout');
      expect(partial.toString().contains('private-backend-error'), isFalse);
      File(p.join(root, 'outside.txt')).writeAsStringSync('{"title":"must-not-read"}');
      File(p.join(root, 'lib/text.arb')).deleteSync();
      Link(p.join(root, 'lib/text.arb')).createSync(p.join(root, 'outside.txt'));
      final missing = await request('/moments/inspect');
      final title = at(at(at(missing, 'editing'), 'properties'), 'reservations.title');
      expect(title['sourceDefault'], isNull);
      expect(title['issue'], isNotNull);
      expect(missing.toString().contains('must-not-read'), isFalse);
      File(p.join(root, 'lib/view.dart')).deleteSync();
      final broken = await request('/moments/inspect');
      expect(at(broken, 'moment')['codeChanged'], isNull);
      expect(at(broken, 'moment')['sourceIssue'], isNotNull);
      expect(at(at(at(broken, 'editing'), 'properties'), 'reservations.gap')['sourceDefault'], isNull);
    },
  );
}
