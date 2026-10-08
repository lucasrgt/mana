import 'dart:async';
import 'dart:io';

import 'action_evidence.dart';
import 'errors.dart';
import 'http_server.dart';
import 'json.dart';
import 'timing.dart';

final _target = RegExp(r'^[a-zA-Z0-9_.:-]{1,160}$');

final class _Job {
  _Job({
    required this.id,
    required this.journeyId,
    required this.target,
    required this.kind,
    required this.text,
    required this.revision,
    required this.client,
    required this.codeHash,
    required this.response,
    required this.expiresAt,
  });
  final String id;
  final Object? journeyId;
  final String target, kind;
  String? text;
  final Object? revision, client, codeHash;
  final HttpResponse response;
  final int expiresAt;
  bool delivered = false;
  final double startedAt = nowMs();
  double? deliveredAt;
  Timer? timer;
  Map<String, Object?>? timing;
}

typedef _Waiting = ({String client, HttpResponse response});

/// A single-use dispatch channel. Delivery loss is uncertain, never retried.
/// The active Moment and runtime identity a channel checks before acting.
abstract interface class ObservedMoments {
  Map<String, Object?> inspect();
  Map<String, Object?> checkpoint();
}

/// What the gesture channel reads from the Moments runtime.
abstract interface class GestureMoments implements ObservedMoments {
  bool inputAllowed(String reference, String target, [String kind]);
}

final class GestureChannel {
  GestureChannel({
    required this.moments,
    bool Function()? ready,
    void Function(Object? journeyId)? authorize,
    void Function(Map<String, Object?> dispatch)? onDispatch,
    this.resolveInput,
    this.timeout = const Duration(milliseconds: 8000),
  }) : _ready = ready ?? (() => true),
       _authorize = authorize ?? ((_) {}),
       _onDispatch = onDispatch ?? ((_) {});

  final GestureMoments? moments;
  final bool Function() _ready;
  final void Function(Object? journeyId) _authorize;
  final void Function(Map<String, Object?> dispatch) _onDispatch;
  final String Function(String reference)? resolveInput;
  final Duration timeout;
  _Job? _job;
  final _seen = <String>{};
  final _waiters = <_Waiting>{};
  final _dispatched = <String, Map<String, Object?>>{};
  final _receipts = <Object?, Map<String, Object?>>{};
  var _evidenceOverflow = false;
  Object? _evidenceJourney;

  void _finish(String status, [String? reason]) {
    final done = _job;
    if (done == null) return;
    _job = null;
    done.timer?.cancel();
    reply(done.response, 200, {
      'id': done.id,
      'status': status,
      'reason': ?reason,
      'revision': done.revision,
      'client': done.client,
      'codeHash': done.codeHash,
      'delivered': done.delivered,
      'transport': done.kind == 'fill'
          ? 'flutter-text-input'
          : done.kind == 'reveal'
          ? 'flutter-scroll'
          : 'flutter-pointer',
      'timing': {
        'clock': 'node-monotonic',
        'queueMs': (done.deliveredAt ?? nowMs()) - done.startedAt,
        'deliveryToReceiptMs': done.deliveredAt == null ? null : nowMs() - done.deliveredAt!,
        'runtime': done.timing,
      },
    });
  }

  bool _matches() {
    final job = _job;
    try {
      _authorize(job?.journeyId);
      final context = moments?.inspect(), checkpoint = moments?.checkpoint();
      return job != null &&
          _ready() &&
          context?['revision'] == job.revision &&
          context?['codeChanged'] != true &&
          context?['recipeChanged'] != true &&
          context?['preparing'] != true &&
          checkpoint?['client'] == job.client &&
          checkpoint?['codeHash'] == job.codeHash;
    } on Object {
      return false;
    }
  }

  bool _deliver(_Waiting waiting) {
    final job = _job;
    if (job == null || job.delivered || waiting.client != job.client) return false;
    if (!_matches()) {
      _finish('rejected', 'Runtime changed before dispatch');
      return false;
    }
    try {
      _onDispatch({'journeyId': job.journeyId, 'id': job.id, 'kind': job.kind, 'target': job.target});
    } on Object {
      _finish('rejected', 'Could not durably record dispatch; inspect before retrying');
      return false;
    }
    job.delivered = true;
    if (job.journeyId != null && job.journeyId != _evidenceJourney) {
      _receipts.clear();
      _evidenceOverflow = false;
      _evidenceJourney = job.journeyId;
    }
    _dispatched[job.id] = {'journeyId': job.journeyId, 'client': job.client, 'revision': job.revision};
    job.deliveredAt = nowMs();
    reply(waiting.response, 200, {
      'id': job.id,
      'revision': job.revision,
      'target': job.target,
      'kind': job.kind,
      if (job.kind == 'fill') 'text': job.text,
      'expiresAt': job.expiresAt,
    });
    job.text = null; // Never retain credential contents after one delivery.
    return true;
  }

  Future<bool> handle(HttpRequest request, Uri url, Body body) async {
    if (!url.path.startsWith('/journey/')) return false;
    final response = request.response, method = request.method;
    if (url.path == '/journey/actions' && method == 'POST') {
      final input = await body();
      final owner = _dispatched[input['id']];
      if (owner?['journeyId'] == null ||
          owner!['client'] != input['client'] ||
          owner['revision'] != input['revision'] ||
          moments?.checkpoint()['client'] != owner['client'] ||
          moments?.inspect()['revision'] != owner['revision']) {
        throw const MomentsError('Action evidence requires its original dispatched runtime');
      }
      _authorize(owner['journeyId']);
      final receipt = actionReceipt(input['receipt']);
      if (receipt['gesture'] != input['id']) throw const MomentsError('Action evidence has a different gesture');
      if (_receipts.containsKey(receipt['request'])) throw const MomentsError('Action evidence already received');
      if (_receipts.length >= 256) {
        _evidenceOverflow = true;
        throw const MomentsError('Action evidence budget exhausted');
      }
      _receipts[receipt['request']] = {'journeyId': owner['journeyId'], 'receipt': receipt};
      reply(response, 200, {'received': true});
    } else if (url.path == '/journey/actions' && method == 'GET') {
      final journeyId = url.queryParameters['journeyId'];
      if (!RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$').hasMatch(journeyId ?? '')) {
        throw const MomentsError('Journey identity required');
      }
      _authorize(journeyId);
      reply(response, 200, {
        'version': 1,
        'journeyId': journeyId,
        'overflow': _evidenceJourney == journeyId && _evidenceOverflow,
        'receipts': [
          for (final value in _receipts.values)
            if (value['journeyId'] == journeyId) value['receipt'],
        ],
      });
    } else if (const ['/journey/tap', '/journey/fill', '/journey/reveal'].contains(url.path) && method == 'POST') {
      final input = await body();
      final kind = url.pathSegments.last;
      _authorize(input['journeyId']);
      final id = input['id'], target = input['target'];
      if (id is! String || !RegExp(r'^[a-f0-9-]{36}$').hasMatch(id) || target is! String || !_target.hasMatch(target)) {
        throw const MomentsError('Invalid gesture request');
      }
      if (_seen.contains(id))
        throw const MomentsError('Gesture already submitted; inspect its outcome instead of replaying');
      if (_job != null || _seen.length >= 2048)
        throw const MomentsError('Gesture channel busy or dispatch budget exhausted');
      final context = moments?.inspect(), checkpoint = moments?.checkpoint();
      final observed = context?['observed'] as Map?;
      if (!_ready() ||
          observed == null ||
          context!['preparing'] == true ||
          context['codeChanged'] == true ||
          context['recipeChanged'] == true ||
          context['revision'] != input['revision'] ||
          checkpoint!['client'] != input['client'] ||
          observed['revision'] != context['revision'] ||
          observed['client'] != checkpoint['client']) {
        throw const MomentsError('Current restored runtime required');
      }
      String? text;
      var resolvedTarget = target;
      final inputRef = input['inputRef'];
      if (kind != 'fill' && inputRef != null) {
        if (inputRef is! String ||
            !_target.hasMatch(inputRef) ||
            !moments!.inputAllowed(inputRef, target, kind) ||
            resolveInput == null) {
          throw const MomentsError('Declared local input reference required');
        }
        final String suffix;
        try {
          suffix = resolveInput!(inputRef);
        } on Object {
          throw const MomentsError('Local input reference unavailable');
        }
        resolvedTarget = '$target$suffix';
        if (!_target.hasMatch(resolvedTarget)) throw const MomentsError('Local input reference unavailable');
      }
      if (kind == 'fill') {
        if (input.containsKey('text') ||
            inputRef is! String ||
            !_target.hasMatch(inputRef) ||
            !moments!.inputAllowed(inputRef, target) ||
            resolveInput == null) {
          throw const MomentsError('Declared local input reference required');
        }
        try {
          text = resolveInput!(inputRef);
        } on Object {
          throw const MomentsError('Local input reference unavailable');
        }
        if (text.isEmpty || text.length > 4096) throw const MomentsError('Local input reference unavailable');
      }
      _seen.add(id);
      final job = _Job(
        id: id,
        journeyId: input['journeyId'],
        target: resolvedTarget,
        kind: kind,
        text: text,
        revision: context['revision'],
        client: checkpoint['client'],
        codeHash: checkpoint['codeHash'],
        response: response,
        expiresAt: DateTime.now().millisecondsSinceEpoch + timeout.inMilliseconds,
      );
      _job = job;
      job.timer = Timer(timeout, () {
        if (identical(_job, job))
          _finish(job.delivered ? 'unknown' : 'rejected', 'Gesture deadline reached; no automatic replay');
      });
      for (final waiting in [..._waiters]) {
        if (_deliver(waiting)) {
          _waiters.remove(waiting);
          break;
        }
      }
      // Keep the job alive if the command disconnects. Otherwise an old
      // in-flight request could overlap a newly accepted write. The lease
      // bounds its life.
    } else if (url.path == '/journey/next' && method == 'GET') {
      final client = url.queryParameters['client'];
      if (client == null || client.isEmpty || client.length > 100)
        throw const MomentsError('Runtime identity required');
      if (moments?.checkpoint()['client'] != client) {
        reply(response, 409, {'error': 'Another runtime owns the Moment'});
        return true;
      }
      final waiting = (client: client, response: response);
      if (!_deliver(waiting)) {
        _waiters.add(waiting);
        final timer = Timer(const Duration(seconds: 20), () {
          _waiters.remove(waiting);
          reply(response, 204);
        });
        trackClose(response, () {
          timer.cancel();
          _waiters.remove(waiting);
        });
      }
    } else if (url.path == '/journey/result' && method == 'POST') {
      final input = await body();
      final job = _job;
      if (job == null || input['id'] != job.id || input['client'] != job.client || !job.delivered) {
        throw const MomentsError('Unknown gesture');
      }
      job.timing = sanitizeGestureTiming(input['timing']);
      final outcome = input['outcome'];
      if (!_matches() || input['revision'] != job.revision) {
        _finish('unknown', 'Runtime or source changed during gesture');
      } else if (outcome == 'dispatched') {
        _finish('dispatched');
      } else if (const [
        'not-found',
        'ambiguous',
        'not-visible',
        'occluded',
        'stale',
        'unsupported',
      ].contains(outcome)) {
        _finish('rejected', outcome as String);
      } else {
        _finish('unknown', 'Flutter could not confirm gesture dispatch');
      }
      reply(response, 200, {'received': true});
    } else {
      reply(response, 404, {'error': 'Unknown gesture operation'});
    }
    return true;
  }

  bool pending() => _job != null;

  void retireOthers(String client) {
    final job = _job;
    if (job != null && job.client != client)
      _finish(job.delivered ? 'unknown' : 'rejected', 'Runtime replaced during gesture');
    for (final waiting in [..._waiters]) {
      if (waiting.client != client) {
        reply(waiting.response, 409, {'error': 'Another runtime owns the Moment'});
        _waiters.remove(waiting);
      }
    }
  }

  void close() {
    final job = _job;
    if (job != null) _finish(job.delivered ? 'unknown' : 'rejected', 'Gesture channel stopped');
    for (final waiting in _waiters) {
      reply(waiting.response, 503, {'error': 'Gesture channel stopped'});
    }
    _waiters.clear();
  }
}
