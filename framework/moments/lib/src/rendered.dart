import 'dart:async';
import 'dart:io';

import 'package:mana/mana.dart' show uuidV4;

import 'errors.dart';
import 'gestures.dart' show ObservedMoments;
import 'http_server.dart';

final class _Capture {
  _Capture(this.id, this.revision, this.client, this.codeHash, this.kinds, this.response);
  final String id;
  final Object? revision, client, codeHash;
  final List<String> kinds;
  final HttpResponse response;
  Timer? timer;
}

/// One requested snapshot of the rendered tree, owned by the same runtime that
/// owns the Moment. No background tree polling, retained history, UI mutation
/// or model calls.
final class RenderedChannel {
  RenderedChannel({
    required this.moments,
    this.timeout = const Duration(milliseconds: 8000),
    this.sourceMode = 'original',
  });

  final ObservedMoments? moments;
  final Duration timeout;
  final String sourceMode;
  _Capture? _job;
  final _waiters = <({String client, HttpResponse response})>{};

  bool _matches() {
    final job = _job;
    try {
      return job != null &&
          moments?.inspect()['revision'] == job.revision &&
          moments!.checkpoint()['client'] == job.client &&
          moments!.checkpoint()['codeHash'] == job.codeHash;
    } on Object {
      return false;
    }
  }

  void _finish(int code, Object? data) {
    final done = _job;
    if (done == null) return;
    _job = null;
    done.timer?.cancel();
    reply(done.response, code, data);
  }

  Future<bool> handle(HttpRequest request, Uri url, Body body) async {
    if (!url.path.startsWith('/render/')) return false;
    final response = request.response, method = request.method;
    if (url.path == '/render/capture' && method == 'POST') {
      if (_job != null) throw const MomentsError('A rendered capture is already pending');
      final input = await body();
      final kinds = input['kinds'];
      if (kinds is! List ||
          kinds.isEmpty ||
          kinds.length > 64 ||
          kinds.any((k) => k is! String || !RegExp(r'^[_a-zA-Z]\w{0,79}$').hasMatch(k))) {
        throw const MomentsError('Expected bounded widget type names');
      }
      final context = moments?.inspect(), checkpoint = moments?.checkpoint();
      final observed = context?['observed'] as Map?;
      if (observed == null ||
          observed['revision'] != context!['revision'] ||
          observed['client'] != checkpoint!['client'] ||
          context['codeChanged'] == true) {
        throw const MomentsError('Restore the current source in the active Moment runtime before inspecting');
      }
      final job = _Capture(
        uuidV4(),
        context['revision'],
        checkpoint['client'],
        checkpoint['codeHash'],
        kinds.cast<String>().toSet().toList(),
        response,
      );
      _job = job;
      job.timer = Timer(
        timeout,
        () => _finish(408, {'error': 'Active Flutter runtime did not report a rendered snapshot'}),
      );
      trackClose(response, () {
        if (identical(_job, job)) {
          job.timer?.cancel();
          _job = null;
        }
      });
      for (final waiting in _waiters) {
        if (waiting.client == job.client) {
          reply(waiting.response, 200, {'id': job.id, 'revision': job.revision, 'kinds': job.kinds});
        } else {
          reply(waiting.response, 409, {'error': 'Another runtime owns the Moment'});
        }
      }
      _waiters.clear();
    } else if (url.path == '/render/next' && method == 'GET') {
      final client = url.queryParameters['client'];
      if (client == null || client.isEmpty || client.length > 100) throw const MomentsError('Runtime client required');
      final owner = moments?.checkpoint()['client'];
      if (owner != null && owner != client) {
        reply(response, 409, {'error': 'Another runtime owns the Moment'});
        return true;
      }
      final job = _job;
      if (job?.client == client) {
        reply(response, 200, {'id': job!.id, 'revision': job.revision, 'kinds': job.kinds});
      } else {
        final item = (client: client, response: response);
        _waiters.add(item);
        final timer = Timer(const Duration(seconds: 20), () => reply(response, 204));
        trackClose(response, () {
          timer.cancel();
          _waiters.remove(item);
        });
      }
    } else if (url.path == '/render/result' && method == 'POST') {
      final input = await body();
      final job = _job;
      if (job == null || input['id'] != job.id || input['client'] != job.client) {
        throw const MomentsError('Unknown or superseded rendered capture');
      }
      if (!_matches() || input['revision'] != job.revision) {
        _finish(409, {'error': 'Moment, source or active runtime changed during capture'});
        reply(response, 409, {'error': 'Stale rendered capture'});
        return true;
      }
      final report = input['report'];
      if (report is Map && report['error'] != null) {
        _finish(422, {'error': 'Flutter could not inspect its current tree'});
      } else {
        final Map<String, Object?> sanitized;
        try {
          sanitized = sanitizeReport(report);
        } on MomentsError catch (error) {
          _finish(422, {'error': error.message});
          rethrow;
        }
        _finish(200, {
          ...sanitized,
          'id': job.id,
          'revision': job.revision,
          'client': job.client,
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
          'codeHash': job.codeHash,
          'sourceMode': sourceMode,
        });
      }
      reply(response, 200, {'received': true});
    } else {
      reply(response, 404, {'error': 'Unknown rendered operation'});
    }
    return true;
  }

  void retireOthers(String client) {
    final job = _job;
    if (job != null && job.client != client) _finish(409, {'error': 'Active runtime changed during capture'});
    for (final waiting in [..._waiters]) {
      if (waiting.client == client) continue;
      reply(waiting.response, 409, {'error': 'Another runtime owns the Moment'});
      _waiters.remove(waiting);
    }
  }

  void close() {
    _finish(503, {'error': 'Inspector stopped'});
    for (final waiting in _waiters) {
      reply(waiting.response, 503, {'error': 'Inspector stopped'});
    }
    _waiters.clear();
  }
}

Map<String, Object?> sanitizeReport(Object? report) {
  bool text(Object? v, int max) => v is String && v.length <= max;
  bool rect(Object? v) =>
      v is List && v.length == 4 && v.every((n) => n is num && n.isFinite) && (v[2] as num) >= 0 && (v[3] as num) >= 0;
  if (report is! Map ||
      report['nodes'] is! List ||
      (report['nodes'] as List).length > 512 ||
      report['truncated'] is! bool ||
      report['tracking'] is! bool ||
      report['captureMs'] is! num ||
      !(report['captureMs'] as num).isFinite ||
      (report['captureMs'] as num) < 0) {
    throw const MomentsError('Invalid rendered snapshot');
  }
  final ids = <String>{};
  final nodes = [
    for (final raw in report['nodes'] as List)
      () {
        final n = raw is Map ? raw : const {};
        final location = n['location'] as Map?;
        if (!text(n['id'], 80) ||
            ids.contains(n['id']) ||
            !text(n['widget'], 80) ||
            n['inViewport'] is! bool ||
            !text(n['reason'], 40) ||
            !text(location?['file'], 2048) ||
            location!['line'] is! int ||
            (location['line'] as int) < 1 ||
            location['column'] is! int ||
            (location['column'] as int) < 1 ||
            n['ancestors'] is! List ||
            (n['ancestors'] as List).length > 8) {
          throw const MomentsError('Invalid rendered node');
        }
        ids.add(n['id'] as String);
        if ((n['bounds'] != null && !rect(n['bounds'])) ||
            (n['visibleBounds'] != null && !rect(n['visibleBounds'])) ||
            (n['inViewport'] == true && (!rect(n['bounds']) || !rect(n['visibleBounds'])))) {
          throw const MomentsError('Invalid rendered bounds');
        }
        return <String, Object?>{
          'id': n['id'],
          'widget': n['widget'],
          'location': {'file': location['file'], 'line': location['line'], 'column': location['column']},
          'inViewport': n['inViewport'],
          'reason': n['reason'],
          'layoutOnly': n['layoutOnly'] == true,
          if (n['bounds'] != null) 'bounds': n['bounds'],
          if (n['visibleBounds'] != null) 'visibleBounds': n['visibleBounds'],
          'ancestors': [
            for (final a in n['ancestors'] as List)
              () {
                if (a is! Map || !text(a['id'], 80) || !text(a['widget'], 80))
                  throw const MomentsError('Invalid ancestor');
                return {'id': a['id'], 'widget': a['widget']};
              }(),
          ],
        };
      }(),
  ];
  return {
    'nodes': nodes,
    'truncated': report['truncated'],
    'tracking': report['tracking'],
    'captureMs': report['captureMs'],
    'visibilityMeaning': 'mounted and intersects viewport after ancestor clips; occlusion not tested',
  };
}
