import 'dart:async';
import 'dart:io';

import 'package:mana/mana.dart' show uuidV4;

import 'errors.dart';
import 'gestures.dart' show ObservedMoments;
import 'http_server.dart';

const agentActions = {
  'tap',
  'longPress',
  'setText',
  'focus',
  'scrollUp',
  'scrollDown',
  'scrollLeft',
  'scrollRight',
  'increase',
  'decrease',
  'dismiss',
};

final class _Job {
  _Job(this.id, this.op, this.input, this.response);
  final String id;
  final String op;
  final Map<String, Object?> input;
  final HttpResponse response;
  Timer? timer;
}

/// What an agent sees of the active Moment's screen and the actions it may
/// take on it, both through Flutter's semantics tree: the roles, labels and
/// values the app already exposes to screen readers, and the semantics
/// actions they accept. This is the agent's equivalent of a person looking at
/// the screen, so it does carry visible text, unlike the rendered capture.
/// One request at a time, answered by the runtime that owns the Moment.
final class AgentChannel {
  AgentChannel({required this.moments, this.timeout = const Duration(milliseconds: 8000)});

  final ObservedMoments? moments;
  final Duration timeout;
  _Job? _job;
  final _waiters = <({String client, HttpResponse response})>{};

  Object? _owner() {
    try {
      return moments?.checkpoint()['client'];
    } on Object {
      return null;
    }
  }

  void _finish(int code, Object? data) {
    final done = _job;
    if (done == null) return;
    _job = null;
    done.timer?.cancel();
    reply(done.response, code, data);
  }

  void _offer(_Job job) {
    final owner = _owner();
    for (final waiting in [..._waiters]) {
      if (owner == null || waiting.client == owner) {
        reply(waiting.response, 200, {'id': job.id, 'op': job.op, ...job.input});
        _waiters.remove(waiting);
        return;
      }
    }
  }

  Future<bool> handle(HttpRequest request, Uri url, Body body) async {
    if (!url.path.startsWith('/agent/')) return false;
    final response = request.response, method = request.method;
    if ((url.path == '/agent/look' || url.path == '/agent/act' || url.path == '/agent/picture') && method == 'POST') {
      if (_job != null) throw const MomentsError('An agent request is already pending');
      final input = await body();
      final op = url.path.substring('/agent/'.length);
      final Map<String, Object?> args;
      if (op == 'act') {
        final node = input['node'], action = input['action'], text = input['text'];
        if (node is! int || node < 0 || action is! String || !agentActions.contains(action)) {
          throw const MomentsError('Expected a semantics node id and a known action');
        }
        if (text != null && (text is! String || text.length > 4000)) throw const MomentsError('Text too long');
        args = {'node': node, 'action': action, if (text != null) 'text': text};
      } else if (op == 'picture') {
        final scale = input['scale'];
        if (scale != null && (scale is! num || scale < 0.05 || scale > 2)) throw const MomentsError('Scale must be between 0.05 and 2');
        args = {if (scale != null) 'scale': scale};
      } else {
        args = {};
      }
      final job = _Job(uuidV4(), op, args, response);
      _job = job;
      job.timer = Timer(timeout, () => _finish(408, {'error': 'Active Flutter runtime did not answer the agent'}));
      trackClose(response, () {
        if (identical(_job, job)) {
          job.timer?.cancel();
          _job = null;
        }
      });
      _offer(job);
    } else if (url.path == '/agent/next' && method == 'GET') {
      final client = url.queryParameters['client'];
      if (client == null || client.isEmpty || client.length > 100) throw const MomentsError('Runtime client required');
      final owner = _owner();
      if (owner != null && owner != client) {
        reply(response, 409, {'error': 'Another runtime owns the Moment'});
        return true;
      }
      final job = _job;
      if (job != null) {
        reply(response, 200, {'id': job.id, 'op': job.op, ...job.input});
      } else {
        final item = (client: client, response: response);
        _waiters.add(item);
        final timer = Timer(const Duration(seconds: 20), () {
          _waiters.remove(item);
          reply(response, 204);
        });
        trackClose(response, () {
          timer.cancel();
          _waiters.remove(item);
        });
      }
    } else if (url.path == '/agent/result' && method == 'POST') {
      final input = await body();
      final job = _job;
      if (job == null || input['id'] != job.id) throw const MomentsError('Unknown or superseded agent request');
      final report = input['report'];
      if (report is! Map) {
        _finish(422, {'error': 'Flutter answered the agent without a report'});
      } else if (report['error'] is String) {
        _finish(422, {'error': report['error']});
      } else {
        _finish(200, _bounded(report.cast<String, Object?>()));
      }
      reply(response, 200, {'received': true});
    } else {
      reply(response, 404, {'error': 'Unknown agent operation'});
    }
    return true;
  }

  Map<String, Object?> _bounded(Map<String, Object?> report) {
    final png = report['png'];
    if (png != null && (png is! String || png.length > 12 * 1024 * 1024)) throw const MomentsError('Picture too large');
    final nodes = report['nodes'];
    if (nodes is List && nodes.length > 1000) throw const MomentsError('Too many semantics nodes');
    return report;
  }

  void retireOthers(String client) {
    for (final waiting in [..._waiters]) {
      if (waiting.client == client) continue;
      reply(waiting.response, 409, {'error': 'Another runtime owns the Moment'});
      _waiters.remove(waiting);
    }
  }

  void close() {
    _finish(503, {'error': 'Agent view stopped'});
    for (final waiting in _waiters) {
      reply(waiting.response, 503, {'error': 'Agent view stopped'});
    }
    _waiters.clear();
  }
}
