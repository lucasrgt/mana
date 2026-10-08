import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mana_primitives/mana_primitives.dart';

/// A verb kept for when the network comes back.
@immutable
final class QueuedVerb {
  const QueuedVerb({
    required this.resource,
    required this.verb,
    required this.recordId,
    required this.queuedAt,
    this.params = const {},
  });

  factory QueuedVerb.fromJson(Map json) => QueuedVerb(
    resource: '${json['resource']}',
    verb: '${json['verb']}',
    recordId: '${json['record_id']}',
    queuedAt: DateTime.parse('${json['queued_at']}'),
    params: (json['params'] as Map?)?.cast<String, Object?>() ?? const {},
  );

  final String resource;
  final String verb;
  final String recordId;
  final DateTime queuedAt;
  final Map<String, Object?> params;

  bool sameAs(QueuedVerb other) =>
      resource == other.resource &&
      verb == other.verb &&
      recordId == other.recordId;

  Map<String, Object?> toJson() => {
    'resource': resource,
    'verb': verb,
    'record_id': recordId,
    'queued_at': queuedAt.toUtc().toIso8601String(),
    'params': params,
  };
}

/// Where queued verbs survive a restart.
abstract interface class VerbQueueStore {
  Future<List<QueuedVerb>> load();
  Future<void> save(List<QueuedVerb> queue);
}

/// A [VerbQueueStore] over one string slot (a preferences key, a file).
final class StringVerbQueueStore implements VerbQueueStore {
  StringVerbQueueStore({required this.read, required this.write});

  final Future<String?> Function() read;
  final Future<void> Function(String value) write;

  @override
  Future<List<QueuedVerb>> load() async {
    final raw = await read();
    if (raw == null || raw.isEmpty) return [];
    try {
      return [
        for (final item in (jsonDecode(raw) as List).cast<Map>())
          QueuedVerb.fromJson(item),
      ];
    } on FormatException {
      return [];
    }
  }

  @override
  Future<void> save(List<QueuedVerb> queue) =>
      write(jsonEncode([for (final item in queue) item.toJson()]));
}

/// A [VerbQueueStore] that forgets on restart, for tests and previews.
final class MemoryVerbQueueStore implements VerbQueueStore {
  List<QueuedVerb> _queue = [];

  @override
  Future<List<QueuedVerb>> load() async => [..._queue];

  @override
  Future<void> save(List<QueuedVerb> queue) async => _queue = [...queue];
}

enum VerbRunState { idle, sending, retrying, queued, failed }

enum VerbOutcome { done, queued, failed }

/// Runs verbs the way each one declares (`Mana.Verbs` `retry:` and
/// `offline:`), so screens never test connectivity themselves: a transient
/// failure is resent up to `retry` times; without a network an
/// `offline: :queue` verb waits in [store] and [flush] sends it later, any
/// other verb fails at once. Money never queues (the server refuses to
/// declare it). [stateOf] tells a button what to show.
final class VerbRunner extends ChangeNotifier {
  VerbRunner({
    required this.send,
    required this.isOffline,
    required this.verbs,
    VerbQueueStore? store,
    bool Function(Object error)? isTransient,
    Duration Function(int attempt)? backoff,
  }) : store = store ?? MemoryVerbQueueStore(),
       isTransient = isTransient ?? isOffline,
       backoff = backoff ?? _backoff;

  /// Performs [verb] on [recordId] against the API.
  final Future<void> Function(
    ManaVerb verb,
    String recordId,
    Map<String, Object?> params,
  )
  send;

  /// Whether [error] means there is no network.
  final bool Function(Object error) isOffline;

  /// Whether resending after [error] may succeed (timeouts, 5xx).
  final bool Function(Object error) isTransient;
  final Duration Function(int attempt) backoff;

  /// The verbs a restored queue may name.
  final List<ManaVerb> verbs;
  final VerbQueueStore store;

  final _states = <String, VerbRunState>{};
  final _errors = <String, Object>{};
  var _queue = <QueuedVerb>[];

  static Duration _backoff(int attempt) =>
      Duration(milliseconds: 200 * (1 << attempt));

  List<QueuedVerb> get queued => List.unmodifiable(_queue);

  VerbRunState stateOf(ManaVerb verb, String recordId) =>
      _states[_key(verb.resource, verb.name, recordId)] ?? VerbRunState.idle;

  Object? errorOf(ManaVerb verb, String recordId) =>
      _errors[_key(verb.resource, verb.name, recordId)];

  /// Loads verbs queued before a restart.
  Future<void> restore() async {
    _queue = await store.load();
    for (final item in _queue) {
      _states[_key(item.resource, item.verb, item.recordId)] =
          VerbRunState.queued;
    }
    notifyListeners();
  }

  Future<VerbOutcome> run(
    ManaVerb verb,
    String recordId, [
    Map<String, Object?> params = const {},
  ]) async {
    final key = _key(verb.resource, verb.name, recordId);
    _set(key, VerbRunState.sending);
    for (var attempt = 0; ; attempt++) {
      try {
        await send(verb, recordId, params);
        await _dequeue(verb.resource, verb.name, recordId);
        _errors.remove(key);
        _set(key, VerbRunState.idle);
        return VerbOutcome.done;
      } on Object catch (error) {
        if (isOffline(error) && verb.offline == VerbOffline.queue) {
          await _enqueue(
            QueuedVerb(
              resource: verb.resource,
              verb: verb.name,
              recordId: recordId,
              queuedAt: DateTime.now().toUtc(),
              params: params,
            ),
          );
          _set(key, VerbRunState.queued);
          return VerbOutcome.queued;
        }
        if (attempt < verb.retry && isTransient(error)) {
          _set(key, VerbRunState.retrying);
          await Future<void>.delayed(backoff(attempt));
          continue;
        }
        _errors[key] = error;
        _set(key, VerbRunState.failed);
        return VerbOutcome.failed;
      }
    }
  }

  /// Sends the queued verbs in order; stops at the first one still offline.
  /// Answers how many were sent.
  Future<int> flush() async {
    var sent = 0;
    for (final item in [..._queue]) {
      final verb = verbs
          .where((v) => v.resource == item.resource && v.name == item.verb)
          .firstOrNull;
      final key = _key(item.resource, item.verb, item.recordId);
      if (verb == null) {
        await _dequeue(item.resource, item.verb, item.recordId);
        _set(key, VerbRunState.idle);
        continue;
      }
      try {
        await send(verb, item.recordId, item.params);
        sent++;
        await _dequeue(item.resource, item.verb, item.recordId);
        _set(key, VerbRunState.idle);
      } on Object catch (error) {
        if (isOffline(error)) break;
        await _dequeue(item.resource, item.verb, item.recordId);
        _errors[key] = error;
        _set(key, VerbRunState.failed);
      }
    }
    return sent;
  }

  Future<void> _enqueue(QueuedVerb item) async {
    _queue = [
      for (final queued in _queue)
        if (!queued.sameAs(item)) queued,
      item,
    ];
    await store.save(_queue);
  }

  Future<void> _dequeue(String resource, String verb, String recordId) async {
    final before = _queue.length;
    _queue = [
      for (final queued in _queue)
        if (!(queued.resource == resource &&
            queued.verb == verb &&
            queued.recordId == recordId))
          queued,
    ];
    if (_queue.length != before) await store.save(_queue);
  }

  void _set(String key, VerbRunState state) {
    _states[key] = state;
    notifyListeners();
  }

  static String _key(String resource, String verb, String recordId) =>
      '$resource.$verb#$recordId';
}
