import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState, uuidV4;

import 'errors.dart';
import 'json.dart';

final _id = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');
final _name = RegExp(r'^[a-z][a-z0-9-]{0,99}$');

Never _invalid() => throw const MomentsError('Invalid durable journey ownership');

Map<String, Object?>? readJourneyState(String? file) {
  if (file == null || !File(file).existsSync()) return null;
  if (File(file).lengthSync() > 16384) _invalid();
  final Object? saved;
  try {
    saved = jsonDecode(File(file).readAsStringSync());
  } on FormatException {
    _invalid();
  }
  if (saved is! Map ||
      saved['version'] != 1 ||
      saved.keys.any((k) => !const ['version', 'lease'].contains(k)) ||
      !saved.containsKey('lease')) {
    _invalid();
  }
  final lease = saved['lease'];
  if (lease == null) return null;
  if (lease is! Map ||
      lease.keys.any((k) => !const ['id', 'name', 'phase', 'expiresAt', 'reason', 'lastOperation'].contains(k)) ||
      lease['id'] is! String ||
      !_id.hasMatch(lease['id'] as String) ||
      lease['name'] is! String ||
      !_name.hasMatch(lease['name'] as String) ||
      !const ['active', 'expired', 'attention'].contains(lease['phase']) ||
      lease['expiresAt'] is! int ||
      (lease['expiresAt'] as int) < 0 ||
      (lease['reason'] != null &&
          !const ['supervisor-restarted', 'heartbeat-expired', 'criteria-incomplete'].contains(lease['reason']))) {
    _invalid();
  }
  if (lease.containsKey('lastOperation')) validateOperation(lease['lastOperation']);
  return lease.cast();
}

void validateOperation(Object? value) {
  if (value is! Map ||
      value.keys.any((k) => !const ['operation', 'id', 'target'].contains(k)) ||
      !const ['prepare', 'tap', 'fill', 'reveal'].contains(value['operation']) ||
      (value['operation'] == 'prepare' && value.length != 1) ||
      (value['operation'] != 'prepare' &&
          (value['id'] is! String ||
              !_id.hasMatch(value['id'] as String) ||
              value['target'] is! String ||
              !RegExp(r'^[a-zA-Z0-9_.:-]{1,160}$').hasMatch(value['target'] as String)))) {
    throw const MomentsError('Invalid journey operation record');
  }
}

/// Persisted before preparation/delivery. Expiry and supervisor replacement
/// retain ownership until effects are inspected; neither authorizes replay.
final class JourneyLease {
  JourneyLease({bool Function()? available, bool Function()? busy, int Function()? now, this.ttl = 60000, this.file})
    : _available = available ?? (() => true),
      _busy = busy ?? (() => false),
      _now = now ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _lease = readJourneyState(file);
    if (_lease != null) _commit({..._lease!, 'phase': 'attention', 'reason': 'supervisor-restarted'});
  }

  final bool Function() _available;
  final bool Function() _busy;
  final int Function() _now;
  final int ttl;
  final String? file;
  Map<String, Object?>? _lease;

  void _commit(Map<String, Object?>? next) {
    if (file != null) savePrivateState(file!, {'version': 1, 'lease': next});
    _lease = next;
  }

  Map<String, Object?> status() {
    final lease = _lease;
    if (lease?['phase'] == 'active' && _now() >= (lease!['expiresAt']! as int)) {
      _commit({...lease, 'phase': 'expired', 'reason': 'heartbeat-expired'});
    }
    return _lease != null ? jsonCopy(_lease!) : {'phase': 'idle'};
  }

  Map<String, Object?> _owned(Object? id) {
    if (_lease == null || id != _lease!['id']) throw const MomentsError('Journey ownership mismatch');
    return status();
  }

  void assertAccess(Object? id) {
    if (_lease == null) {
      if (id != null) throw const MomentsError('Journey lease no longer exists');
      return;
    }
    if (_owned(id)['phase'] != 'active') {
      throw const MomentsError('Journey ownership expired or needs inspection; use moments recover explicitly');
    }
  }

  Map<String, Object?> acquire(Object? name) {
    if (name is! String || !_name.hasMatch(name)) throw const MomentsError('Named journey required');
    if (_lease != null) throw const MomentsError('Another journey owns this instance; inspect moments status');
    if (!_available() || _busy()) throw const MomentsError('Instance is busy; wait before starting a journey');
    _commit({'id': uuidV4(), 'name': name, 'phase': 'active', 'expiresAt': _now() + ttl});
    return status();
  }

  void note(Object? id, Map<String, Object?> operation) {
    assertAccess(id);
    if (_lease == null) return;
    validateOperation(operation);
    _commit({..._lease!, 'lastOperation': jsonCopy(operation)});
  }

  Map<String, Object?> heartbeat(Object? id) {
    if (_owned(id)['phase'] != 'active') throw const MomentsError('Cannot renew an expired journey');
    _commit({..._lease!, 'expiresAt': _now() + ttl});
    return status();
  }

  Map<String, Object?> finish(Object? id, bool passed) {
    _owned(id);
    if (_busy()) throw const MomentsError('Journey still has an in-flight operation');
    if (passed && status()['phase'] == 'active') {
      _commit(null);
      return status();
    }
    _commit({..._lease!, 'phase': 'attention', 'reason': 'criteria-incomplete'});
    return status();
  }

  Map<String, Object?> recover(Object? id, Object? acknowledge) {
    final current = _owned(id);
    if (acknowledge != true || !const ['expired', 'attention'].contains(current['phase'])) {
      throw const MomentsError('Only an interrupted journey can be explicitly recovered');
    }
    if (_busy()) throw const MomentsError('Preparation or gesture is still in flight; inspect before recovery');
    _commit(null);
    return {'phase': 'idle', 'recovered': current['id'], 'effects': 'not-rolled-back'};
  }
}
