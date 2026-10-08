import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mana/mana.dart' show Instance, identityJson, processIdentity, savePrivateState, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'lifecycle.dart';
import 'private_fs.dart';

typedef LayerHandle = Map<String, Object?>;

/// What a layer driver needs besides its directories: the owned database
/// cluster, the runtime access to grant, and the writer stop check.
final class LayerOptions {
  const LayerOptions({this.instance, this.runtimeAccess, this.assertStopped});
  final Instance? instance;
  final ({List<String> schemas, int connectionLimit})? runtimeAccess;
  final FutureOr<void> Function(LayerHandle handle)? assertStopped;
}

/// One kind of captured state. A snapshot is captured from a source or an
/// instance, materialized into instances, and every copy is disposable and
/// recoverable from its own durable record.
abstract interface class LayerDriver {
  String get type;
  Future<void> capture({required LayerHandle handle, required String out, LayerOptions opts});
  Future<LayerHandle> materialize({required String dir, required String from, LayerOptions opts});
  Future<void> dispose({required LayerHandle handle, LayerOptions opts});
  Future<void> forget({required String dir, LayerOptions opts});
  Future<Map<String, Object?>> recover({required String dir, LayerOptions opts, bool pending});
}

typedef Layer = ({String name, LayerDriver driver, String root, LayerOptions opts});

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

bool _supervisorShape(Object? value) =>
    value is Map &&
    value['pid'] is int &&
    (value['pid']! as int) >= 1 &&
    RegExp(r'^\d+$').hasMatch('${value['start'] ?? ''}') &&
    isUuid(value['boot']);

Map<String, Object?> _supervisor() {
  final identity = processIdentity(pid);
  if (identity == null) throw const MomentsError('Layer creator identity unavailable');
  return identityJson(identity);
}

Future<void> _stopped(LayerHandle handle, LayerOptions opts, String message) async {
  final check = opts.assertStopped;
  if (check == null) throw MomentsError(message);
  await check(handle);
}

bool _creatorAlive(Map<String, Object?> record) {
  final supervisor = (record['supervisor']! as Map).cast<String, Object?>();
  return sameProcess(supervisor) &&
      !(supervisor['pid'] == pid && const ['attention', 'disposing', 'disposed'].contains(record['phase']));
}

/// Bounded, opaque private JSON for captured local effects. Never exposed to
/// the browser. Runtime adapters must quiesce writers before capture or disposal.
final class PrivateJsonLayer implements LayerDriver {
  const PrivateJsonLayer();

  @override
  String get type => 'private-json';

  static void _directory(String dir) =>
      requireDirectory(dir, 'Private JSON directory must be real and private', privateOnly: true);

  static List<int> _file(String dir, String name, int limit) {
    _directory(dir);
    final path = p.join(dir, name);
    if (entityType(path) != FileSystemEntityType.file || !private(path) || File(path).lengthSync() > limit) {
      throw const MomentsError('Invalid private JSON file');
    }
    return File(path).readAsBytesSync();
  }

  static ({List<int> bytes, Map<String, Object?> value}) _data(String dir) {
    final bytes = _file(dir, 'state.json', 1024 * 1024);
    final Object? value;
    try {
      value = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const MomentsError('Unreadable private JSON state');
    }
    if (value is! Map) throw const MomentsError('Private JSON state must be an object');
    return (bytes: bytes, value: value.cast());
  }

  static Map<String, Object?> _record(String dir) {
    final Object? value;
    try {
      value = jsonDecode(utf8.decode(_file(dir, 'private-json-layer.json', 16384)));
    } on Object {
      throw const MomentsError('Invalid private JSON ownership');
    }
    if (value is! Map ||
        value['version'] != 1 ||
        !isUuid(value['id']) ||
        !const ['snapshot', 'instance'].contains(value['kind']) ||
        !const ['copying', 'ready', 'attention', 'disposing', 'disposed'].contains(value['phase']) ||
        !_supervisorShape(value['supervisor'])) {
      throw const MomentsError('Invalid private JSON ownership');
    }
    return value.cast();
  }

  static Map<String, Object?> _owned(LayerHandle handle) {
    final dir = handle['dir'];
    if (handle['kind'] != 'private-json' || dir is! String) throw const MomentsError('Invalid private JSON handle');
    final record = _record(dir);
    if (record['id'] != handle['id'] || record['kind'] != 'instance' || record['phase'] != 'ready') {
      throw const MomentsError('Private JSON ownership changed');
    }
    return record;
  }

  static LayerHandle _create(String dir, String kind, Map<String, Object?> value) {
    makePrivateDirectory(dir);
    final record = {'version': 1, 'id': uuidV4(), 'kind': kind, 'phase': 'copying', 'supervisor': _supervisor()};
    final file = p.join(dir, 'private-json-layer.json');
    savePrivateState(file, record);
    try {
      savePrivateState(p.join(dir, 'state.json'), value);
      final (:bytes, value: _) = _data(dir);
      savePrivateState(file, {...record, 'phase': 'ready', 'sha256': _digest(bytes)});
    } on Object {
      savePrivateState(file, {...record, 'phase': 'attention'});
      rethrow;
    }
    return {'kind': 'private-json', 'id': record['id'], 'dir': dir};
  }

  static void _erase(String dir, Map<String, Object?> record) {
    const allowed = {
      'state.json',
      'state.json.tmp',
      'private-json-layer.json',
      'private-json-layer.json.tmp',
      '.operation.lock',
    };
    for (final entry in Directory(dir).listSync(followLinks: false)) {
      if (!allowed.contains(p.basename(entry.path))) throw const MomentsError('Unexpected private JSON layer entry');
      if (entityType(entry.path) != FileSystemEntityType.file)
        throw const MomentsError('Unsafe private JSON layer entry');
    }
    final file = p.join(dir, 'private-json-layer.json');
    savePrivateState(file, {...record, 'phase': 'disposing'});
    for (final name in ['state.json', 'state.json.tmp', 'private-json-layer.json.tmp']) {
      if (exists(p.join(dir, name))) File(p.join(dir, name)).deleteSync();
    }
    savePrivateState(file, {...record, 'phase': 'disposed'});
  }

  static LayerHandle sourceHandle(String dir) {
    final root = p.normalize(p.absolute(dir));
    _data(root);
    return {'kind': 'private-json-source', 'dir': root};
  }

  static Map<String, Object?> readState(LayerHandle handle) {
    _owned(handle);
    return _data(handle['dir']! as String).value;
  }

  static void writeState(LayerHandle handle, Map<String, Object?> value) {
    _owned(handle);
    if (utf8.encode('${const JsonEncoder.withIndent('  ').convert(value)}\n').length > 1024 * 1024) {
      throw const MomentsError('Invalid bounded private JSON state');
    }
    savePrivateState(p.join(handle['dir']! as String, 'state.json'), value);
  }

  @override
  Future<void> capture({
    required LayerHandle handle,
    required String out,
    LayerOptions opts = const LayerOptions(),
  }) async {
    if (handle['kind'] == 'private-json') {
      _owned(handle);
    } else if (handle['kind'] != 'private-json-source') {
      throw const MomentsError('Invalid private JSON source');
    }
    await _stopped(handle, opts, 'Private JSON requires an explicit writer stop check');
    _create(p.normalize(p.absolute(out)), 'snapshot', _data(handle['dir']! as String).value);
  }

  @override
  Future<LayerHandle> materialize({
    required String dir,
    required String from,
    LayerOptions opts = const LayerOptions(),
  }) async {
    final root = p.normalize(p.absolute(from));
    final record = _record(root), state = _data(root);
    if (record['kind'] != 'snapshot' || record['phase'] != 'ready' || record['sha256'] != _digest(state.bytes)) {
      throw const MomentsError('Private JSON snapshot changed or incomplete');
    }
    return _create(p.normalize(p.absolute(dir)), 'instance', state.value);
  }

  @override
  Future<void> dispose({required LayerHandle handle, LayerOptions opts = const LayerOptions()}) async {
    final record = _owned(handle);
    await _stopped(handle, opts, 'Private JSON requires an explicit writer stop check');
    _erase(handle['dir']! as String, record);
  }

  @override
  Future<void> forget({required String dir, LayerOptions opts = const LayerOptions()}) async {
    final root = p.normalize(p.absolute(dir));
    final record = _record(root);
    if (record['kind'] != 'snapshot' || record['phase'] != 'ready')
      throw const MomentsError('Invalid private JSON snapshot');
    _erase(root, record);
  }

  @override
  Future<Map<String, Object?>> recover({
    required String dir,
    LayerOptions opts = const LayerOptions(),
    bool pending = false,
  }) async {
    final root = p.normalize(p.absolute(dir));
    if (!exists(root)) return {'status': 'disposed'};
    _directory(root);
    return withInstanceLock(root, () async {
      if (!exists(p.join(root, 'private-json-layer.json'))) {
        if (!pending || Directory(root).listSync().any((e) => p.basename(e.path) != '.operation.lock')) {
          throw const MomentsError('Private JSON ownership missing');
        }
        return {'status': 'disposed', 'empty': true};
      }
      final record = _record(root);
      if (_creatorAlive(record)) throw const MomentsError('Private JSON creator is alive');
      await _stopped(
        {'kind': 'private-json', 'id': record['id'], 'dir': root},
        opts,
        'Private JSON requires an explicit writer stop check',
      );
      _erase(root, record);
      return {'status': 'disposed'};
    });
  }
}

/// The resumable UI and private actor state of one Flutter actor.
final class FlutterActorLayer implements LayerDriver {
  const FlutterActorLayer();

  static const _files = ['ui-session.json', 'actor-state.json'];

  @override
  String get type => 'flutter-actor';

  static Map<String, Object?> _metadata(String dir) =>
      (jsonDecode(File(p.join(dir, 'actor-layer.json')).readAsStringSync()) as Map).cast();

  static Map<String, List<int>> _content(String dir) {
    final result = <String, List<int>>{};
    for (final name in _files) {
      final file = p.join(dir, name);
      if (entityType(file) != FileSystemEntityType.file || File(file).lengthSync() > 1024 * 1024) {
        throw const MomentsError('Invalid Flutter actor checkpoint file');
      }
      result[name] = File(file).readAsBytesSync();
    }
    final Object? ui, actor;
    try {
      ui = jsonDecode(utf8.decode(result['ui-session.json']!));
      actor = jsonDecode(utf8.decode(result['actor-state.json']!));
    } on FormatException {
      throw const MomentsError('Invalid Flutter actor checkpoint');
    }
    final states = ui is Map ? ui['states'] : null, values = actor is Map ? actor['values'] : null;
    if (ui is! Map ||
        ui['version'] != 2 ||
        states is! Map ||
        !states.containsKey(ui['active']) ||
        states.entries.any(
          (entry) =>
              entry.value is! Map ||
              (entry.value as Map)['name'] != entry.key ||
              (entry.value as Map)['projection'] is! Map ||
              ((entry.value as Map)['projection'] as Map)['route'] is! String,
        ) ||
        actor is! Map ||
        actor['version'] != 1 ||
        values is! Map ||
        values.entries.any(
          (entry) =>
              !RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch('${entry.key}') ||
              entry.value is! String ||
              (entry.value as String).length > 8192,
        )) {
      throw const MomentsError('Invalid Flutter actor checkpoint');
    }
    return result;
  }

  static Map<String, Object?> _owned(LayerHandle handle) {
    final dir = handle['dir'];
    if (handle['kind'] != 'flutter-actor' || dir is! String || realPath(dir) != dir) {
      throw const MomentsError('Invalid Flutter actor handle');
    }
    final record = _metadata(dir);
    if (record['id'] != handle['id'] || record['phase'] != 'ready' || record['kind'] != 'instance') {
      throw const MomentsError('Flutter actor ownership mismatch');
    }
    return record;
  }

  static LayerHandle _create(String dir, String kind, Map<String, List<int>> buffers) {
    makePrivateDirectory(p.dirname(dir), recursive: true);
    makePrivateDirectory(dir);
    final id = uuidV4();
    final record = {'version': 1, 'id': id, 'kind': kind, 'phase': 'copying', 'supervisor': _supervisor()};
    final file = p.join(dir, 'actor-layer.json');
    savePrivateState(file, record);
    try {
      for (final MapEntry(key: name, value: bytes) in buffers.entries) {
        createExclusive(p.join(dir, name), bytes);
      }
      savePrivateState(file, {
        ...record,
        'phase': 'ready',
        'sha256': {for (final MapEntry(:key, :value) in buffers.entries) key: _digest(value)},
      });
    } on Object {
      savePrivateState(file, {...record, 'phase': 'attention'});
      rethrow;
    }
    return {'kind': 'flutter-actor', 'id': id, 'dir': realPath(dir)};
  }

  static LayerHandle sourceHandle(String directory) {
    final dir = realPath(directory);
    _content(dir);
    return {'kind': 'flutter-actor-source', 'dir': dir};
  }

  @override
  Future<void> capture({
    required LayerHandle handle,
    required String out,
    LayerOptions opts = const LayerOptions(),
  }) async {
    if (handle['kind'] == 'flutter-actor') {
      _owned(handle);
    } else if (handle['kind'] != 'flutter-actor-source' || realPath(handle['dir']! as String) != handle['dir']) {
      throw const MomentsError('Invalid Flutter actor source');
    }
    await _stopped(handle, opts, 'Flutter actor capture/disposal requires a runtime stop check');
    _create(p.normalize(p.absolute(out)), 'snapshot', _content(handle['dir']! as String));
  }

  @override
  Future<LayerHandle> materialize({
    required String dir,
    required String from,
    LayerOptions opts = const LayerOptions(),
  }) async {
    final root = p.normalize(p.absolute(from));
    final record = _metadata(root), buffers = _content(root);
    final hashes = record['sha256'] as Map?;
    if (record['version'] != 1 ||
        record['kind'] != 'snapshot' ||
        record['phase'] != 'ready' ||
        _files.any((name) => hashes?[name] != _digest(buffers[name]!))) {
      throw const MomentsError('Flutter actor snapshot changed or incomplete');
    }
    return _create(p.normalize(p.absolute(dir)), 'instance', buffers);
  }

  @override
  Future<void> dispose({required LayerHandle handle, LayerOptions opts = const LayerOptions()}) async {
    _owned(handle);
    await _stopped(handle, opts, 'Flutter actor capture/disposal requires a runtime stop check');
    Directory(handle['dir']! as String).deleteSync(recursive: true);
  }

  @override
  Future<void> forget({required String dir, LayerOptions opts = const LayerOptions()}) async {
    final root = p.normalize(p.absolute(dir));
    final record = _metadata(root);
    if (realPath(root) != root ||
        record['version'] != 1 ||
        record['kind'] != 'snapshot' ||
        record['phase'] != 'ready') {
      throw const MomentsError('Invalid Flutter actor snapshot ownership');
    }
    Directory(root).deleteSync(recursive: true);
  }

  @override
  Future<Map<String, Object?>> recover({
    required String dir,
    LayerOptions opts = const LayerOptions(),
    bool pending = false,
  }) async {
    final root = p.normalize(p.absolute(dir));
    // A missing file-only copy is already gone; no remote resource can remain.
    if (!exists(root)) return {'status': 'disposed'};
    if (realPath(root) != root) throw const MomentsError('Actor recovery refuses symbolic directories');
    return withInstanceLock(root, () async {
      final file = p.join(root, 'actor-layer.json');
      if (!exists(file)) {
        if (!pending || Directory(root).listSync().any((e) => p.basename(e.path) != '.operation.lock')) {
          throw const MomentsError('Actor layer has no ownership record');
        }
        return {'status': 'disposed', 'empty': true};
      }
      if (entityType(file) != FileSystemEntityType.file || File(file).lengthSync() > 16384) {
        throw const MomentsError('Invalid actor recovery record');
      }
      final record = _metadata(root);
      if (record['version'] != 1 ||
          !isUuid(record['id']) ||
          !const ['instance', 'snapshot'].contains(record['kind']) ||
          !const ['copying', 'ready', 'attention', 'disposing', 'disposed'].contains(record['phase'])) {
        throw const MomentsError('Invalid actor recovery ownership');
      }
      if (!_supervisorShape(record['supervisor']))
        throw const MomentsError('Actor layer creator has no recovery identity');
      if (_creatorAlive(record)) throw const MomentsError('Actor layer creator is alive; stop it before recovery');
      await _stopped(
        {'kind': 'flutter-actor', 'id': record['id'], 'dir': root},
        opts,
        'Flutter actor capture/disposal requires a runtime stop check',
      );
      // Remove only declared checkpoint files and their own in-flight temp
      // files. Unknown entries keep the directory for inspection.
      final allowed = {
        ..._files,
        for (final name in _files) '$name.tmp',
        'actor-layer.json',
        'actor-layer.json.tmp',
        '.operation.lock',
        '.runtime.json',
        '.defines.json',
        '.journey.json',
        '.journey.json.tmp',
      };
      final entries = Directory(root).listSync(followLinks: false);
      if (entries.any((entry) => !allowed.contains(p.basename(entry.path)))) {
        throw const MomentsError('Unexpected files in recovered actor layer');
      }
      if (entries.any((entry) => entityType(entry.path) != FileSystemEntityType.file)) {
        throw const MomentsError('Unsafe recovered actor layer entry');
      }
      savePrivateState(file, {...record, 'phase': 'disposing'});
      for (final entry in entries) {
        if (!const ['.operation.lock', 'actor-layer.json'].contains(p.basename(entry.path)))
          File(entry.path).deleteSync();
      }
      savePrivateState(file, {...record, 'phase': 'disposed'});
      return {'status': 'disposed'};
    });
  }
}
