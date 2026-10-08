import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mana/mana.dart' show savePrivateState;
import 'package:path/path.dart' as p;

import 'android_transport.dart';
import 'errors.dart';
import 'lifecycle.dart';
import 'owned_process.dart';
import 'private_fs.dart';

final _application = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]*(?:\.[a-zA-Z][a-zA-Z0-9_]*)+$');

String _actorAdb(List<String> args) {
  final result = Process.runSync('adb', args);
  if (result.exitCode != 0) {
    throw const MomentsError('Android app operation unconfirmed; retain this actor for recovery');
  }
  return (result.stdout as String).trim();
}

Map<String, Object?> _read(String file) =>
    readJsonObject(file, 16384, 'Invalid private Android actor record', privateOnly: true);

Map<String, Object?> _validate(Map<String, Object?> record, Map<String, Object?> transport) {
  if (record['version'] != 1 ||
      record['owner'] != transport['owner'] ||
      record['device'] != transport['device'] ||
      record['boot'] != transport['boot'] ||
      !_application.hasMatch('${record['applicationId'] ?? ''}') ||
      !const ['prepared', 'running', 'stopped'].contains(record['phase']) ||
      jsonEncode(record['supervisor']) != jsonEncode(transport['supervisor'])) {
    throw const MomentsError('Android app and transport ownership differ');
  }
  return record;
}

void _singleUser(Adb adb, String device) {
  final users = RegExp(
    r'UserInfo\{(\d+):',
  ).allMatches(adb(['-s', device, 'shell', 'pm', 'list', 'users'])).map((m) => m[1]).toList();
  if (users.length != 1 ||
      users.single != '0' ||
      adb(['-s', device, 'shell', 'am', 'get-current-user']).trim() != '0') {
    throw const MomentsError('Android actors currently require a dedicated single-user device');
  }
}

List<int> _processes(Adb adb, String device, String applicationId) {
  final lines = adb(['-s', device, 'shell', 'ps', '-A', '-o', 'PID,NAME']).trim().split(RegExp(r'\r?\n'));
  if (lines.isEmpty || !RegExp(r'^\s*PID\s+NAME\s*$').hasMatch(lines.removeAt(0))) {
    throw const MomentsError('Unrecognized Android process inventory');
  }
  return [
    for (final line in lines)
      ...() {
        final match = RegExp(r'^\s*(\d+)\s+(.+?)\s*$').firstMatch(line);
        if (match == null) throw const MomentsError('Unrecognized Android process inventory');
        final name = match[2]!;
        return name == applicationId || name.startsWith('$applicationId:') ? [int.parse(match[1]!)] : const <int>[];
      }(),
  ];
}

/// Explicit opt-in for a dedicated device and app. The transport claim
/// excludes cooperating Mana runs; manual adb activity is outside that
/// boundary. App data is never cleared or uninstalled. This is lifecycle
/// control, not an APK/data snapshot.
final class AndroidActor {
  AndroidActor({
    required String directory,
    required this.device,
    required this.applicationId,
    required List<int> ports,
    String? owner,
    this.adb = _actorAdb,
    String? claims,
  }) {
    if (!_application.hasMatch(applicationId)) throw const MomentsError('Declare the Android application ID');
    transport = AndroidTransport(
      directory: directory,
      device: device,
      ports: ports,
      owner: owner,
      adb: adb,
      claims: claims,
    );
    this.directory = realPath(directory);
    _file = p.join(this.directory, 'android-app.json');
    _transportFile = p.join(this.directory, 'transport.json');
  }

  final String device, applicationId;
  final Adb adb;
  late final AndroidTransport transport;
  late final String directory, _file, _transportFile;

  ({Map<String, Object?> state, Map<String, Object?> record}) _own() {
    final state = transport.inspectOwnership(), record = _validate(_read(_file), state);
    if (record['applicationId'] != applicationId) throw const MomentsError('Android application identity changed');
    return (state: state, record: record);
  }

  Future<Map<String, Object?>> prepare() async {
    await transport.start();
    return withInstanceLock(directory, () async {
      if (exists(_file)) throw const MomentsError('Android actor already has a launch intent');
      final state = transport.inspectOwnership();
      _singleUser(adb, device);
      if (_processes(adb, device, applicationId).isNotEmpty) {
        throw const MomentsError('Android application is already running; it was not stopped');
      }
      if (transport.inspectOwnership()['currentBoot'] != state['boot']) {
        throw const MomentsError('Android rebooted before app launch');
      }
      final record = {
        'version': 1,
        'owner': state['owner'],
        'device': device,
        'applicationId': applicationId,
        'boot': state['boot'],
        'supervisor': state['supervisor'],
        'phase': 'prepared',
      };
      savePrivateState(_file, record);
      return record;
    });
  }

  Future<void> confirmStarted() => withInstanceLock(directory, () async {
    final (:state, :record) = _own();
    if (record['phase'] != 'prepared' || state['currentBoot'] != record['boot']) {
      throw const MomentsError('Android app launch cannot be confirmed or replayed');
    }
    _singleUser(adb, device);
    final pids = _processes(adb, device, applicationId);
    if (pids.isEmpty) throw const MomentsError('Android application did not start');
    if (transport.inspectOwnership()['currentBoot'] != record['boot']) {
      throw const MomentsError('Android rebooted during app observation');
    }
    savePrivateState(_file, {...record, 'phase': 'running', 'observedPids': pids});
  });

  Future<void> close() async {
    // Essential after SIGKILL: the host launcher must be absent before stopping
    // the package or releasing its device lease.
    if (exists(p.join(directory, 'process.json')) && inspectOwnedProcess(directory).present) {
      throw const MomentsError('Android launcher still exists; stop it before closing the app');
    }
    if (!exists(_transportFile)) return;
    await withInstanceLock(directory, () async {
      if (!exists(_file)) return;
      final saved = _read(_transportFile), record = _validate(_read(_file), saved);
      if (record['applicationId'] != applicationId) throw const MomentsError('Android application identity changed');
      if (record['phase'] == 'stopped') return;
      final (:state, record: _) = _own();
      if (state['currentBoot'] == record['boot']) {
        _singleUser(adb, device);
        if (transport.inspectOwnership()['currentBoot'] != record['boot']) {
          throw const MomentsError('Android rebooted during app cleanup');
        }
        adb(['-s', device, 'shell', 'am', 'force-stop', '--user', '0', applicationId]);
        if (transport.inspectOwnership()['currentBoot'] != record['boot']) {
          throw const MomentsError('Android rebooted before app closure was confirmed');
        }
        if (_processes(adb, device, applicationId).isNotEmpty) {
          throw const MomentsError('Android application remains active; actor retained');
        }
        savePrivateState(_file, {...record, 'phase': 'stopped', 'closure': 'processes-absent'});
      } else {
        savePrivateState(_file, {...record, 'phase': 'stopped', 'closure': 'original-boot-ended'});
      }
    });
    await transport.close();
  }

  void assertStopped() {
    if (!exists(_transportFile)) return;
    final saved = _read(_transportFile);
    if (saved['phase'] != 'disposed') throw const MomentsError('Android transport remains active');
    if (exists(_file) && _validate(_read(_file), saved)['phase'] != 'stopped') {
      throw const MomentsError('Android app closure unconfirmed');
    }
  }
}

Future<Map<String, Object?>> recoverAndroidActor(String directory, {Adb adb = _actorAdb, String? claims}) async {
  final transport = _read(p.join(directory, 'transport.json'));
  if (sameProcess((transport['supervisor'] as Map?)?.cast())) {
    throw const MomentsError('Android actor supervisor is still alive');
  }
  final file = p.join(directory, 'android-app.json');
  if (!exists(file)) return recoverAndroidTransport(directory, adb: adb, claims: claims);
  final record = _validate(_read(file), transport);
  final actor = AndroidActor(
    directory: directory,
    device: record['device']! as String,
    applicationId: record['applicationId']! as String,
    ports: [for (final entry in (transport['ports']! as List).cast<Map>()) entry['port']! as int],
    owner: record['owner']! as String,
    adb: adb,
    claims: claims,
  );
  await actor.close();
  actor.assertStopped();
  return {'status': 'stopped'};
}

String _analyze(String operation, String file) {
  final result = Process.runSync('apkanalyzer', ['manifest', operation, file]);
  if (result.exitCode != 0) throw const MomentsError('apkanalyzer failed');
  return (result.stdout as String).trim();
}

/// Local SDK inspection before any device or backend effects. The caller owns
/// source provenance; this pins identity and checks the package it can clean up.
final class AndroidBinary {
  AndroidBinary({required String file, required this.applicationId, this.inspect = _analyze})
    : file = p.normalize(p.absolute(file)) {
    if (!_application.hasMatch(applicationId)) throw const MomentsError('Invalid Android artifact declaration');
  }

  final String file, applicationId;
  final String Function(String operation, String file) inspect;
  Map<String, Object?>? _pinned;

  Map<String, Object?> read() {
    if (entityType(file) != FileSystemEntityType.file || File(file).lengthSync() == 0) {
      throw const MomentsError('Android actor requires a regular nonempty APK');
    }
    final bytes = File(file).readAsBytesSync();
    final digest = sha256.convert(bytes).toString();
    if (_pinned != null && _pinned!['sha256'] != digest)
      throw const MomentsError('Android artifact changed between actors');
    if (_pinned == null) {
      String id, debuggable;
      try {
        id = inspect('application-id', file);
        debuggable = inspect('debuggable', file);
      } on Object {
        throw const MomentsError(
          'Cannot inspect Android APK; install Android SDK apkanalyzer and inspect the private artifact',
        );
      }
      if (id != applicationId || debuggable != 'true') {
        throw const MomentsError('Android artifact must be debug and match its declared application ID');
      }
      if (sha256.convert(File(file).readAsBytesSync()).toString() != digest) {
        throw const MomentsError('Android artifact changed during inspection');
      }
      _pinned = {'sha256': digest, 'bytes': bytes.length, 'applicationId': applicationId};
    }
    return {..._pinned!};
  }
}

bool _localService(String value) {
  final url = Uri.tryParse(value);
  return url != null &&
      url.scheme == 'http' &&
      url.host == '127.0.0.1' &&
      url.hasPort &&
      url.port >= 1 &&
      url.port <= 65535 &&
      url.userInfo.isEmpty &&
      (url.path == '/' || url.path.isEmpty) &&
      !url.hasQuery &&
      !url.hasFragment;
}

/// Development-only launch envelope. It stays in owned private process logs;
/// the bridge capability never enters user-visible routes or reports.
String nativeMomentRoute({required String apiUrl, required String bridgeUrl, required String bridgeToken}) {
  if (!_localService(apiUrl) || !_localService(bridgeUrl) || !RegExp(r'^[a-f0-9]{48}$').hasMatch(bridgeToken)) {
    throw const MomentsError('Native Moment launch requires local services and an actor capability');
  }
  return '/__mana_moments?configuration=${Uri.encodeComponent(jsonEncode({'version': 1, 'apiUrl': apiUrl, 'bridgeUrl': bridgeUrl, 'bridgeToken': bridgeToken}))}';
}
