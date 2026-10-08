import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mana/mana.dart' show openPrivate, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'gestures.dart';
import 'http_server.dart';
import 'inspect.dart';
import 'journey_lease.dart';
import 'json.dart';
import 'private_store.dart';
import 'rendered.dart';
import 'runtime.dart';

void validateOverrides(Object? values, Map<String, Object?> schema) {
  if (values is! Map) throw const MomentsError('Expected a property map');
  for (final MapEntry(:key, :value) in values.entries) {
    final field = schema[key] as Map?;
    if (field == null) throw MomentsError('Unknown property: $key');
    if (value == null) continue;
    if (value is! String) throw MomentsError('$key: expected a string or null');
    final allowed = field['enum'] as List?;
    if (allowed != null && !allowed.contains(value)) throw MomentsError('$key: expected ${allowed.join(', ')}');
    final maxLength = field['maxLength'];
    if (field['type'] == 'text' && (value.trim().isEmpty || (maxLength is num && value.length > maxLength))) {
      throw MomentsError('$key: expected 1–${field['maxLength']} characters');
    }
  }
}

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
/// runner: presentation overrides, `/moments/*`, gestures, rendered
/// captures, journey ownership and the development supervisor.
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
    required String directory,
    String? sessionDirectory,
    int port = 18740,
    bool momentsEnabled = true,
    MomentsOptions momentsOptions = const MomentsOptions(),
    Object? Function()? bootstrap,
    Development? development,
    String Function(String reference)? resolveInput,
    Map<String, Object?> extraSchema = const {},
    String? overridesFile,
    List<String>? privateStores,
  }) async {
    sessionDirectory ??= directory;
    Directory(directory).createSync(recursive: true);
    Directory(sessionDirectory).createSync(recursive: true);
    Process.runSync('chmod', ['700', sessionDirectory]);
    final runtimeFile = p.join(sessionDirectory, '.runtime.json');
    final definesFile = p.join(sessionDirectory, '.defines.json');
    if (File(runtimeFile).existsSync())
      throw const MomentsError('Bridge session already exists; stop its supervisor first');
    final waiters = <HttpResponse>{};
    final privateStore = privateStores != null
        ? PrivateStore(file: p.join(sessionDirectory, 'actor-state.json'), keys: privateStores)
        : null;
    late final RenderedChannel rendered;
    late final GestureChannel gestures;
    final moments = momentsEnabled
        ? Moments.create(
            p.dirname(p.normalize(p.absolute(directory))),
            momentsOptions.copyWith(
              onRuntimeClaim: (client) {
                // Hot restart discards Dart futures, not necessarily their
                // open HTTP polls. Release legacy presentation polls and
                // retire inspectors from old runtimes before they fill the
                // browser's per-origin HTTP connection pool.
                for (final waiter in waiters) {
                  reply(waiter, 204);
                }
                waiters.clear();
                rendered.retireOthers(client);
                gestures.retireOthers(client);
              },
            ),
          )
        : null;
    rendered = RenderedChannel(moments: moments, sourceMode: extraSchema.isNotEmpty ? 'virtual' : 'original');
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
    final file = overridesFile ?? p.join(directory, 'overrides.json');
    final schemaFile = File(p.join(directory, 'schema.json'));
    final schema = schemaFile.existsSync()
        ? (jsonDecode(schemaFile.readAsStringSync()) as Map).cast<String, Object?>()
        : <String, Object?>{};
    for (final MapEntry(:key, :value) in extraSchema.entries) {
      final allowed = (value as Map?)?['enum'];
      if (!RegExp(r'^virtual\.slot_[a-f0-9]{16}$').hasMatch(key) ||
          schema.containsKey(key) ||
          allowed is! List ||
          allowed.isEmpty) {
        throw const MomentsError('Invalid virtual property schema');
      }
      schema[key] = value;
    }
    final saved = File(file).existsSync()
        ? jsonDecode(File(file).readAsStringSync()) as Map
        : {'version': 1, 'values': <String, Object?>{}};
    if (saved['version'] != 1) throw const MomentsError('Unsupported overrides version');
    validateOverrides(saved['values'], schema);
    var values = <String, Object?>{
      for (final MapEntry(:key, :value) in (saved['values'] as Map).cast<String, Object?>().entries)
        if (value != null) key: value,
    };
    var revision = uuidV4();
    final token = _token();
    final history = <String, double?>{revision: null};
    final acknowledgments = <Map<String, Object?>>[];
    var closed = false;
    Map<String, Object?> snapshot() => {'revision': revision, 'values': values};

    Future<void> handle(HttpRequest request) async {
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
              '/patch',
              '/reset',
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
              project: p.dirname(p.normalize(p.absolute(directory))),
              moments: moments,
              schema: schema,
              values: values,
              revision: revision,
              acknowledgments: acknowledgments,
              development: development,
            ),
          );
        }
        if (moments != null && await moments.handle(request, url, body)) return;
        if (method == 'GET' && url.path == '/state')
          return reply(response, 200, {...snapshot(), 'schema': schema, 'acknowledgments': acknowledgments});
        if (method == 'GET' && url.path == '/changes') {
          if (url.queryParameters['since'] != revision) return reply(response, 200, snapshot());
          waiters.add(response);
          final timer = Timer(const Duration(seconds: 20), () => reply(response, 204));
          trackClose(response, () {
            timer.cancel();
            waiters.remove(response);
          });
          return;
        }
        if (method == 'POST' && (url.path == '/patch' || url.path == '/reset')) {
          final patch = url.path == '/reset' ? <String, Object?>{} : await body();
          validateOverrides(patch, schema);
          final next = url.path == '/reset' ? <String, Object?>{} : {...values};
          for (final MapEntry(:key, :value) in patch.entries) {
            if (value == null) {
              next.remove(key);
            } else {
              next[key] = value;
            }
          }
          final started = nowMs();
          // Synchronous atomic replace avoids interleaved lost writes.
          File(
            '$file.tmp',
          ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({'version': 1, 'values': next})}\n');
          File('$file.tmp').renameSync(file);
          values = next;
          revision = uuidV4();
          history[revision] = started;
          if (history.length > 100) history.remove(history.keys.first);
          for (final waiter in waiters) {
            reply(waiter, 200, snapshot());
          }
          waiters.clear();
          return reply(response, 200, {...snapshot(), 'persisted': true});
        }
        if (method == 'POST' && url.path == '/ack') {
          final ack = await body();
          final applied = ack['applyToFrameMs'];
          if (!history.containsKey(ack['revision']) ||
              ack['session'] is! String ||
              (ack['session'] as String).length > 100 ||
              applied is! num ||
              !applied.isFinite ||
              applied < 0) {
            return reply(response, 400, {'error': 'Invalid frame acknowledgment'});
          }
          final started = history[ack['revision']];
          acknowledgments.add({
            'revision': ack['revision'],
            'session': ack['session'],
            'applyToFrameMs': applied,
            'patchToAckMs': started == null ? null : nowMs() - started,
          });
          if (acknowledgments.length > 100) acknowledgments.removeAt(0);
          return reply(response, 200, {'received': true});
        }
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
      for (final waiter in waiters) {
        reply(waiter, 503, {'error': 'Bridge stopped'});
      }
      await server.close(force: true);
      for (final name in [runtimeFile, definesFile]) {
        if (File(name).existsSync()) File(name).deleteSync();
      }
    });
  }
}
