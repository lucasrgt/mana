import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _Fixture {
  _Fixture()
    : dir = Directory.systemTemp.createTempSync('mana-owned-container-').path {
    addTearDown(() => Directory(dir).deleteSync(recursive: true));
    handle = allocateOwnedContainer(dir, docker: docker);
  }

  final String dir;
  late final OwnedContainer handle;
  final events = <List<String>>[];
  Map<String, dynamic>? actual;
  String? fail;

  String get file => p.join(dir, 'container.json');
  Map<String, dynamic> record() =>
      jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;

  String docker(List<String> args) {
    final op = args.first, rest = args.sublist(1);
    events.add(args);
    if (op == 'create') {
      expect(record()['phase'], 'creating');
      final name = rest[rest.indexOf('--name') + 1],
          label = rest[rest.indexOf('--label') + 1].split('=');
      actual = {
        'Id': 'a' * 64,
        'Name': '/$name',
        'Config': {
          'Labels': {label[0]: label[1]},
        },
        'State': {'Running': false},
      };
    } else if (op == 'start') {
      actual!['State']['Running'] = true;
    } else if (op == 'stop' && fail != 'stop') {
      actual!['State']['Running'] = false;
    } else if (op == 'rm') {
      actual = null;
    }
    if (op == fail) throw StateError('Injected acknowledgement failure');
    if (op == 'ps') return actual?['Id'] as String? ?? '';
    if (op == 'inspect') return jsonEncode([actual]);
    if (op == 'create') return actual!['Id'] as String;
    return '';
  }
}

const _image = 'local-image';
const _command = ['sleep', '60'];
const _options = ['--read-only', '--network', 'none'];

void _create(OwnedContainer handle, {List<String> options = _options}) =>
    handle.create(image: _image, command: _command, options: options);

Matcher _throwing(String text) =>
    throwsA(predicate((Object error) => '$error'.contains(text), text));

void main() {
  test(
    'allocation precedes Docker effects and create/start cannot be replayed',
    () {
      final f = _Fixture();
      expect(f.events, isEmpty);
      expect(f.record()['phase'], 'allocated');
      expect(
        () => allocateOwnedContainer(f.dir, docker: f.docker),
        _throwing('exists'),
      );
      _create(f.handle);
      expect(f.actual!['State']['Running'], isFalse);
      expect(f.record()['containerId'], f.actual!['Id']);
      expect(() => _create(f.handle), _throwing('replayed'));
      f.handle.start();
      expect(f.actual!['State']['Running'], isTrue);
      expect(f.handle.start, _throwing('replayed'));
      final before = File(f.file).readAsStringSync();
      expect(f.handle.inspect(), (present: true, running: true));
      expect(File(f.file).readAsStringSync(), before);
      f.handle
        ..stop()
        ..stop();
      expect(f.actual, isNull);
      expect(f.record()['phase'], 'stopped');
      expect(
        f.events
            .where((args) => const ['start', 'stop', 'rm'].contains(args.first))
            .every((args) => args.last == 'a' * 64),
        isTrue,
      );
    },
  );

  test(
    'lost create acknowledgement leaves an inert, owned, recoverable resource',
    () {
      final f = _Fixture()..fail = 'create';
      expect(() => _create(f.handle), _throwing('acknowledgement'));
      expect(f.actual!['State']['Running'], isFalse);
      expect(f.record()['phase'], 'creating');
      expect(() => _create(f.handle), _throwing('replayed'));
      f.fail = null;
      f.handle.stop();
      expect(f.actual, isNull);
      expect(f.record()['containerId'], 'a' * 64);
      expect(f.events.where((args) => args.first == 'create'), hasLength(1));
    },
  );

  test(
    'lost start acknowledgement never permits layers to be captured as stopped',
    () {
      final f = _Fixture();
      _create(f.handle);
      f.fail = 'start';
      expect(f.handle.start, _throwing('acknowledgement'));
      expect(f.handle.inspect().running, isTrue);
      expect(f.record()['phase'], 'starting');
      expect(f.handle.start, _throwing('replayed'));
      f.fail = 'stop';
      expect(f.handle.stop, _throwing('acknowledgement'));
      expect(f.record()['phase'], 'stopping');
      expect(f.events.any((args) => args.first == 'rm'), isFalse);
      f.fail = null;
      f.handle.stop();
      expect(f.record()['phase'], 'stopped');
      expect(f.actual, isNull);
    },
  );

  test(
    'cleanup refuses foreign labels and replacement IDs without destructive calls',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (a) => a['Config']['Labels']['dev.moments.actor-owner'] = 'foreign',
        (a) => a['Id'] = 'b' * 64,
      ]) {
        final f = _Fixture();
        _create(f.handle);
        mutate(f.actual!);
        expect(f.handle.stop, _throwing('ownership changed'));
        expect(
          f.events.any((args) => args.first == 'stop' || args.first == 'rm'),
          isFalse,
        );
      }
    },
  );

  test(
    'recovery requires a dead supervisor and only allows cleanup, never replay',
    () {
      final f = _Fixture();
      _create(f.handle);
      f.handle.start();
      expect(
        () => recoverOwnedContainer(f.dir, docker: f.docker),
        _throwing('still alive'),
      );
      final record = f.record();
      record['supervisor']['pid'] = 2147483647;
      File(f.file).writeAsStringSync(jsonEncode(record));
      final recovered = recoverOwnedContainer(f.dir, docker: f.docker);
      expect(() => _create(recovered), _throwing('replayed'));
      expect(recovered.start, _throwing('replayed'));
      recovered.stop();
      expect(f.actual, isNull);
      expect(f.record()['phase'], 'stopped');
    },
  );

  test(
    'identity overrides are rejected before effects; unused allocations can be disposed',
    () {
      final f = _Fixture();
      expect(
        () => _create(f.handle, options: ['--name', 'foreign']),
        _throwing('Unsupported'),
      );
      expect(f.events, isEmpty);
      expect(f.record()['phase'], 'allocated');
      f.handle.stop();
      expect(f.record()['phase'], 'stopped');
    },
  );

  test(
    'a delayed inert creation remains cleanable after an earlier absent observation',
    () {
      final f = _Fixture()..fail = 'create';
      expect(() => _create(f.handle), _throwing('acknowledgement'));
      final delayed = f.actual;
      f
        ..actual = null
        ..fail = null;
      f.handle.stop();
      expect(f.record()['phase'], 'stopped');
      f.actual = delayed;
      expect(f.handle.inspect().running, isFalse);
      f.handle.stop();
      expect(f.actual, isNull);
      expect(f.record()['containerId'], delayed!['Id']);
      expect(f.events.where((args) => args.first == 'create'), hasLength(1));
    },
  );

  test(
    'packaged runtime hardening is allowed without opening security or identity overrides',
    () {
      final f = _Fixture();
      for (final options in [
        ['--cap-add', 'ALL'],
        ['--cap-drop', 'NET_ADMIN'],
        ['--security-opt', 'seccomp=unconfined'],
        ['--privileged'],
        ['--label', 'dev.moments.actor-owner=foreign'],
      ]) {
        expect(
          () => _create(f.handle, options: options),
          _throwing('Unsupported'),
        );
        expect(f.events, isEmpty);
      }
      _create(
        f.handle,
        options: [
          '--read-only',
          '--cap-drop',
          'ALL',
          '--security-opt',
          'no-new-privileges',
        ],
      );
      expect(f.record()['phase'], 'created');
      f.handle.stop();
    },
  );
}
