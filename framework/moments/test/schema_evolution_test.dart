import 'dart:convert';
import 'dart:io';

import 'package:moments/src/bridge.dart';
import 'package:moments/src/manifest.dart';
import 'package:moments/src/runtime.dart';
import 'package:moments/src/session_projection.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

/// One `inbox` Moment whose saved draft has `filter: done`.
final class Fixture {
  Fixture() : root = temporary('moment-schema-') {
    Directory(p.join(root, 'lib')).createSync();
    Directory(p.join(root, 'moments')).createSync();
    File(p.join(root, 'lib/app.dart')).writeAsStringSync('void main() {}');
    write();
    open();
    disk = (readJson(saved)! as Map).cast<String, Object?>();
    inbox['projection'] = {...(inbox['projection']! as Map).cast<String, Object?>(), 'filter': 'done'};
    writeJson(saved, disk);
  }

  final String root;
  late Map<String, Object?> disk;
  final manifest = <String, Object?>{
    'version': 1,
    'watch': ['lib/app.dart'],
    'properties': <String, Object?>{
      'route': <String, Object?>{
        'enum': ['/tasks'],
      },
      'filter': <String, Object?>{
        'enum': ['all', 'done'],
      },
      'actor': {'type': 'string', 'maxLength': 36, 'restore': false},
    },
    'moments': <String, Object?>{
      'inbox': <String, Object?>{
        'projection': <String, Object?>{'route': '/tasks', 'filter': 'all', 'actor': 'none'},
      },
    },
  };

  String get file => p.join(root, 'moments/manifest.json');
  String get saved => p.join(root, 'moments/.session.json');
  Map<String, Object?> get properties => (manifest['properties']! as Map).cast();
  Map<String, Object?> get moments => (manifest['moments']! as Map).cast();
  Map<String, Object?> get states => (disk['states']! as Map).cast();
  Map<String, Object?> get inbox => (states['inbox']! as Map).cast();

  void write() => writeJson(file, manifest);
  void save() => writeJson(saved, disk);
  Moments open({bool fresh = false}) =>
      Moments.create(root, MomentsOptions(manifestFile: file, initialName: 'inbox', openName: 'inbox', fresh: fresh))!;
  List<int> bytes() => File(saved).readAsBytesSync();

  void addOther({Map<String, Object?>? projection}) {
    moments['other'] = <String, Object?>{
      'projection': <String, Object?>{'route': '/tasks', 'filter': 'all', 'actor': 'none'},
      'backend': {'recipe': 'other'},
    };
  }

  Future<Bridge> bridge({
    Future<void> Function(String name)? prepare,
    Future<void> Function(String name)? afterPreparedOpen,
  }) async {
    final bridge = await Bridge.start(
      directory: p.join(root, 'live-ui'),
      port: 0,
      momentsOptions: MomentsOptions(manifestFile: file, prepare: prepare, afterPreparedOpen: afterPreparedOpen),
    );
    addTearDown(bridge.close);
    return bridge;
  }
}

Future<({int code, String text})> openOther(Bridge bridge, Map<String, Object?> data) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(Uri.parse('${bridge.url}/moments/open'));
    request.headers
      ..set('Authorization', 'Bearer ${bridge.token}')
      ..set('Content-Type', 'application/json');
    request.add(utf8.encode(jsonEncode({'name': 'other', ...data})));
    final response = await request.close();
    return (code: response.statusCode, text: await utf8.decoder.bind(response).join());
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('additive default restores old presentation without turning observations into inputs', () {
    final f = Fixture();
    f.properties['draft'] = {'type': 'string', 'maxLength': 120};
    ((f.moments['inbox']! as Map)['projection'] as Map)['draft'] = '';
    f.write();
    final projection = (f.open().inspect()['state']! as Map)['projection'];
    expect(projection, {'route': '/tasks', 'filter': 'done', 'draft': ''});
    final saved = readJson(f.saved)! as Map;
    expect((((saved['states'] as Map)['inbox'] as Map)['projection'] as Map).containsKey('actor'), isFalse);
  });

  test('missing fields in an unchanged declaration remain invalid and disk stays intact', () {
    final f = Fixture();
    (f.inbox['projection']! as Map).remove('filter');
    f.save();
    final before = f.bytes();
    expect(f.open, throwing('Unexpected screen state properties'));
    expect(f.bytes(), before);
  });

  test('changed declaration never overwrites retired values or silently drops unknown fields', () {
    final f = Fixture();
    (f.properties['filter']! as Map)['enum'] = ['all'];
    f.write();
    final before = f.bytes();
    expect(f.open, throwing('Unsupported filter'));
    expect(f.bytes(), before);
    (f.properties['filter']! as Map)['enum'] = ['all', 'done'];
    (f.moments['inbox']! as Map)['description'] = 'new';
    f.write();
    (f.inbox['projection']! as Map)['retired'] = 'old';
    f.save();
    expect(f.open, throwing('Unexpected screen state properties'));
  });

  test('a route change requires explicit fresh intent and cannot graft old view data onto a new route', () {
    final f = Fixture();
    (f.properties['route']! as Map)['enum'] = ['/other'];
    ((f.moments['inbox']! as Map)['projection'] as Map)['route'] = '/other';
    f.write();
    expect(f.open, throwing('Unsupported route'));
    final current = Moments.create(f.root, MomentsOptions(manifestFile: f.file, openName: 'inbox', fresh: true))!;
    expect(((current.inspect()['state']! as Map)['projection'] as Map)['route'], '/other');
  });

  test('an incompatible inactive saved Moment is rejected before backend preparation', () async {
    final f = Fixture();
    f.addOther();
    (f.inbox['projection']! as Map)['filter'] = 'all';
    f.states['other'] = {
      ...f.inbox,
      'name': 'other',
      'projection': {'route': '/tasks', 'filter': 'done'},
    };
    f.save();
    (f.properties['filter']! as Map)['enum'] = ['all'];
    f.write();
    var prepared = 0, restarted = 0;
    final bridge = await f.bridge(prepare: (_) async => prepared++, afterPreparedOpen: (_) async => restarted++);
    final before = f.bytes(), state = bridge.moments!.inspect()['state'];
    for (final options in <Map<String, Object?>>[
      {},
      {'prepare': false},
    ]) {
      expect((await openOther(bridge, options)).code, 400);
      expect(prepared, 0, reason: 'A schema-incompatible draft must fail before its backend recipe');
      expect(restarted, 0);
      expect(f.bytes(), before);
      expect(bridge.moments!.inspect()['state'], state);
    }
    final fresh = await openOther(bridge, {'fresh': true});
    expect(fresh.code, 200);
    expect(prepared, 1);
    expect(restarted, 1);
    final value = jsonDecode(fresh.text) as Map;
    expect((value['state'] as Map)['name'], 'other');
    expect(((value['state'] as Map)['projection'] as Map)['filter'], 'all');
    expect(((readJson(f.saved)! as Map)['states'] as Map)['inbox'], f.inbox);
  });

  test('a compatible inactive draft gains declared defaults and keeps values through prepared open', () async {
    final f = Fixture();
    f.addOther();
    f.states['other'] = {...f.inbox, 'name': 'other'};
    f.save();
    f.properties['draft'] = {'type': 'string', 'maxLength': 120};
    for (final scene in f.moments.values) {
      ((scene! as Map)['projection'] as Map)['draft'] = 'new default';
    }
    f.write();
    var prepared = 0;
    final bridge = await f.bridge(prepare: (_) async => prepared++);
    final response = await openOther(bridge, {});
    expect(response.code, 200);
    expect(prepared, 1);
    expect(((jsonDecode(response.text) as Map)['state'] as Map)['projection'], {
      'route': '/tasks',
      'filter': 'done',
      'draft': 'new default',
    });
    final saved = (readJson(f.saved)! as Map)['states'] as Map;
    expect(saved['inbox'], f.inbox);
    expect(((saved['other'] as Map)['projection'] as Map).containsKey('actor'), isFalse);
  });

  test('unknown persisted session versions are preserved byte-for-byte and never auto-migrated', () {
    final f = Fixture();
    for (final version in <Object>[1, 3, '2']) {
      writeJson(f.saved, {...f.disk, 'version': version});
      final before = f.bytes();
      expect(f.open, throwing('Unsupported Moments session version'), reason: '$version');
      expect(f.bytes(), before);
    }
  });

  test('declaration drift during preparation reports uncertain effects without moving or replaying', () async {
    final f = Fixture();
    f.addOther();
    f.write();
    var prepared = 0, restarted = 0;
    final bridge = await f.bridge(
      prepare: (_) async {
        prepared++;
        (f.moments['other']! as Map)['description'] = 'changed during preparation';
        f.write();
      },
      afterPreparedOpen: (_) async => restarted++,
    );
    final before = f.bytes(), state = bridge.moments!.inspect()['state'];
    final response = await openOther(bridge, {});
    expect(response.code, 400);
    expect(response.text, contains('effects may have occurred'));
    expect(response.text, contains('Inspect backend state'));
    expect(response.text, isNot(contains('open again')));
    expect(prepared, 1);
    expect(restarted, 0);
    expect(f.bytes(), before);
    expect(bridge.moments!.inspect()['state'], state);
  });

  test('cold launcher rejects an incompatible saved destination before infrastructure ownership', () async {
    await compileCli();
    final f = Fixture();
    final directory = p.join(f.root, 'moments/.backend');
    Directory(directory).createSync();
    Process.runSync('chmod', ['700', directory]);
    f.addOther();
    (f.properties['filter']! as Map)['enum'] = ['all'];
    f.write();
    final saved = {
      ...f.disk,
      'active': 'inbox',
      'states': {
        ...f.states,
        'other': {...(jsonDecode(jsonEncode(f.inbox)) as Map).cast<String, Object?>(), 'name': 'other'},
      },
    };
    (((saved['states']! as Map)['inbox'] as Map)['projection'] as Map)['filter'] = 'all';
    final file = p.join(directory, 'ui-session.json');
    writeJson(file, saved);
    final before = File(file).readAsBytesSync();
    writeJson(p.join(f.root, 'moments/backend.json'), {
      'version': 1,
      'name': 'other',
      'ports': {'web': 0, 'bridge': 0, 'api': 0},
    });
    // Only chmod is reachable: a regression must fail without ever reaching
    // the machine's real Docker, Flutter or systemd tools.
    final tools = temporary('moment-schema-tools-');
    Link(
      p.join(tools, 'chmod'),
    ).createSync((await Process.run('sh', ['-c', 'command -v chmod'])).stdout.toString().trim());
    final result = await moments(['up', 'other', '--project', f.root], cwd: f.root, environment: {'PATH': tools});
    expect(result.code, isNot(0));
    expect(result.stdout + result.stderr, contains('Unsupported filter'));
    expect(File(file).readAsBytesSync(), before);
    for (final name in ['running.json', 'instance.json']) {
      expect(File(p.join(directory, name)).existsSync(), isFalse);
    }
    // Fresh is explicit replacement of the destination UI, never an implicit
    // conversion or rewrite of retained files during the compatibility check.
    validateSavedOpening(readManifest(f.file), file, 'other', fresh: true);
    expect(File(file).readAsBytesSync(), before);
  });
}
