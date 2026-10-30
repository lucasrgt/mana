import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mana/mana.dart' show openPrivate;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'gestures.dart';
import 'http_server.dart';
import 'inspect.dart';
import 'journey_lease.dart';
import 'json.dart' show nowMs;
import 'private_store.dart';
import 'rendered.dart';
import 'runtime.dart';

String _token() {
  final random = Random.secure();
  return [for (var i = 0; i < 24; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

void _writePrivate(String path, String content, {bool exclusive = false}) {
  if (exclusive && File(path).existsSync())
    throw const MomentsError('Bridge session already exists; stop its supervisor first');
  final handle = openPrivate(path);
  try {
    handle.writeStringSync(content);
  } finally {
    handle.closeSync();
  }
}

/// The loopback HTTP hub between a running Flutter app and the Moments
/// runner: `/moments/*`, gestures, rendered captures, journey ownership and
/// the development supervisor.
final class Bridge {
  Bridge._(this.url, this.token, this.definesFile, this.moments, this._lease, this._close);

  final String url;
  final String token;
  final String definesFile;
  final Moments? moments;
  final JourneyLease _lease;
  final Future<void> Function() _close;

  Map<String, Object?> journeyStatus() => _lease.status();
  Future<void> close() => _close();

  static Future<Bridge> start({
    required String project,
    String? sessionDirectory,
    int port = 18740,
    bool momentsEnabled = true,
    MomentsOptions momentsOptions = const MomentsOptions(),
    Object? Function()? bootstrap,
    Development? development,
    String Function(String reference)? resolveInput,
    List<String>? privateStores,
  }) async {
    project = p.normalize(p.absolute(project));
    sessionDirectory ??= project;
    Directory(sessionDirectory).createSync(recursive: true);
    Process.runSync('chmod', ['700', sessionDirectory]);
    final runtimeFile = p.join(sessionDirectory, '.runtime.json');
    final definesFile = p.join(sessionDirectory, '.defines.json');
    if (File(runtimeFile).existsSync())
      throw const MomentsError('Bridge session already exists; stop its supervisor first');
    final privateStore = privateStores != null
        ? PrivateStore(file: p.join(sessionDirectory, 'actor-state.json'), keys: privateStores)
        : null;
    late final RenderedChannel rendered;
    late final GestureChannel gestures;
    final moments = momentsEnabled
        ? Moments.create(
            project,
            momentsOptions.copyWith(
              onRuntimeClaim: (client) {
                // Hot restart discards Dart futures, not necessarily their
                // open HTTP polls. Retire inspectors from old runtimes before
                // they fill the browser's per-origin HTTP connection pool.
                rendered.retireOthers(client);
                gestures.retireOthers(client);
              },
            ),
          )
        : null;
    rendered = RenderedChannel(moments: moments);
    bool ready() {
      final status = development?.status();
      return status == null ||
          (const ['idle', 'ready'].contains(status['phase']) &&
              status['pending'] != true &&
              status['held'] != true &&
              ((status['services'] as List?) ?? const []).cast<Map>().every(
                (s) => s['running'] == true && s['phase'] == 'ready' && s['codeChanged'] != true,
              ));
    }

    final lease = JourneyLease(
      file: p.join(sessionDirectory, '.journey.json'),
      available: ready,
      busy: () {
        final context = moments?.inspect();
        return gestures.pending() ||
            (moments?.hasPendingCapture() ?? false) ||
            context?['preparing'] == true ||
            context?['opening'] == true;
      },
    );
    gestures = GestureChannel(
      moments: moments,
      ready: ready,
      resolveInput: resolveInput,
      authorize: lease.assertAccess,
      onDispatch: (d) => lease.note(d['journeyId'], {'operation': d['kind'], 'id': d['id'], 'target': d['target']}),
    );
    final token = _token();
    var closed = false;

    Future<void> handle(HttpRequest request) async {
      arrivals[request] = nowMs();
      final response = request.response;
      try {
        final host = request.headers.value('host') ?? '';
        if (!RegExp(r'^127\.0\.0\.1:\d+$').hasMatch(host))
          return reply(response, 403, {'error': 'Loopback host required'});
        final origin = request.headers.value('origin');
        if (origin != null) {
          final u = Uri.parse(origin);
          if (u.scheme != 'http' || !const ['localhost', '127.0.0.1', '[::1]', '::1'].contains(u.host)) {
            return reply(response, 403, {'error': 'Loopback origin required'});
          }
          response.headers
            ..set('Access-Control-Allow-Origin', origin)
            ..set('Vary', 'Origin')
            ..set('Access-Control-Allow-Headers', 'Authorization, Content-Type')
            ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            ..set('Access-Control-Max-Age', '600');
        }
        if (request.method == 'OPTIONS') return reply(response, 204);
        if (request.headers.value('authorization') != 'Bearer $token')
          return reply(response, 401, {'error': 'Session token required'});
        final url = request.uri;
        final body = onceBody(request);
        final method = request.method;
        if (method == 'POST' &&
            const [
              '/moments/open',
              '/moments/reset',
              '/dev/refresh',
              '/dev/renew',
              '/journey/tap',
            ].contains(url.path)) {
          final input = await body();
          lease.assertAccess(input['journeyId']);
          if (url.path == '/moments/open' && input['prepare'] != false)
            lease.note(input['journeyId'], {'operation': 'prepare'});
        }
        if (url.path == '/journey/lease') {
          if (method == 'GET') return reply(response, 200, lease.status());
          if (method != 'POST') return reply(response, 405, {'error': 'POST required'});
          final input = await body();
          switch (input['operation']) {
            case 'acquire':
              moments?.validateName(input['name']);
              return reply(response, 200, lease.acquire(input['name']));
            case 'heartbeat':
              return reply(response, 200, lease.heartbeat(input['journeyId']));
            case 'finish':
              return reply(response, 200, lease.finish(input['journeyId'], input['passed'] == true));
            case 'recover':
              return reply(response, 200, lease.recover(input['journeyId'], input['acknowledge']));
          }
          throw const MomentsError('Unknown journey lease operation');
        }
        if (url.path == '/moments/settle' && method == 'POST') {
          final input = await body();
          void guard() {
            final owner = lease.status();
            if (owner['phase'] != 'active' || owner['id'] != input['journeyId']) {
              throw const MomentsError('Active journey ownership required for capture');
            }
            lease.assertAccess(input['journeyId']);
            final context = moments?.inspect();
            final observed = context?['observed'] as Map?;
            if (!ready() ||
                gestures.pending() ||
                observed == null ||
                context!['opening'] == true ||
                context['preparing'] == true ||
                context['codeChanged'] == true ||
                context['recipeChanged'] == true ||
                context['revision'] != input['revision'] ||
                observed['client'] != input['client'] ||
                observed['revision'] != input['revision']) {
              throw const MomentsError('Current settled runtime required for capture');
            }
          }

          guard();
          final checkpoint = moments!.checkpoint();
          if (checkpoint['client'] != input['client']) throw const MomentsError('Capture runtime changed');
          final id = moments.requestFrame(checkpoint, capture: true, guard: guard);
          try {
            final deadline = DateTime.now().add(const Duration(seconds: 10));
            while (true) {
              guard();
              if (moments.checkpoint()['codeHash'] != checkpoint['codeHash'])
                throw const MomentsError('Source changed while capturing UI');
              final captured = moments.capturedFrameAfter(id);
              if (captured != null) return reply(response, 200, {'status': 'captured', ...captured});
              if (answered(response) || DateTime.now().isAfter(deadline))
                throw const MomentsError('Fresh ready UI frame was not captured');
              await Future<void>.delayed(const Duration(milliseconds: 25));
            }
          } finally {
            moments.cancelFrame(id);
          }
        }
        if (await rendered.handle(request, url, onceBody(request, limit: 262144))) return;
        if (await gestures.handle(request, url, body)) return;
        if (privateStore != null && await privateStore.handle(request, url, body)) return;
        if (method == 'GET' && url.path == '/moments/bootstrap') return reply(response, 200, bootstrap?.call());
        final renewal = development?.renewal;
        if (renewal != null && url.path == '/dev/renew' && method == 'GET')
          return reply(response, 200, renewal.status());
        if (renewal != null && url.path == '/dev/renew' && method == 'POST')
          return reply(response, 202, renewal.start((await body())['name']));
        if (development != null && url.path == '/dev/status' && method == 'GET') {
          return reply(response, 200, {...development.status(), 'journey': lease.status()});
        }
        final refresh = development?.refresh;
        if (refresh != null && url.path == '/dev/refresh' && method == 'POST')
          return reply(response, 202, refresh(await body()));
        final stop = development?.stop;
        if (stop != null && url.path == '/dev/stop' && method == 'POST') {
          final input = await body();
          if (input['preserve'] != true) throw const MomentsError('Stop must preserve the Moments instance');
          reply(response, 202, {'status': 'stopping', 'preserved': true});
          unawaited(
            response.done.then(
              (_) => Future<void>(() async {
                try {
                  await stop();
                } on Object catch (error) {
                  stderr.writeln('Moments stop: $error');
                }
              }),
            ),
          );
          return;
        }
        if (moments != null && method == 'GET' && url.path == '/moments/inspect') {
          return reply(
            response,
            200,
            await inspectMoment(
              project: project,
              moments: moments,
              development: development,
            ),
          );
        }
        if (moments != null && await moments.handle(request, url, body)) return;
        reply(response, 404, {'error': 'Unknown operation'});
      } on Object catch (error) {
        reply(response, 400, {'error': error is MomentsError ? error.message : '$error'});
      }
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    server.listen(handle);
    final url = 'http://127.0.0.1:${server.port}';
    try {
      _writePrivate(runtimeFile, jsonEncode({'url': url, 'token': token, 'pid': pid}), exclusive: true);
      _writePrivate(definesFile, jsonEncode({'MANA_MOMENTS': 'true', 'LIVE_UI_URL': url, 'LIVE_UI_TOKEN': token}));
    } on Object {
      await server.close(force: true);
      rethrow;
    }
    return Bridge._(url, token, definesFile, moments, lease, () async {
      if (closed) return;
      closed = true;
      rendered.close();
      gestures.close();
      moments?.close();
      await server.close(force: true);
      for (final name in [runtimeFile, definesFile]) {
        if (File(name).existsSync()) File(name).deleteSync();
      }
    });
  }
}
