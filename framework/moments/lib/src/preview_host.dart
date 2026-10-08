import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mana/mana.dart' show identityJson, processIdentity, savePrivateState, uuidV4;
import 'package:path/path.dart' as p;

import 'browser.dart';
import 'errors.dart';
import 'lifecycle.dart';
import 'paths.dart';
import 'private_fs.dart';

Map<String, Object?> _read(String file) =>
    readJsonObject(file, 262144, 'Invalid private preview host record', privateOnly: true);

String _hex(int bytes) {
  final random = Random.secure();
  return [for (var i = 0; i < bytes; i++) random.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
}

Future<void> _removeStaleSocket(String path) async {
  if (!exists(path)) return;
  if (entityType(path) != FileSystemEntityType.unixDomainSock) throw const MomentsError('Unexpected preview socket');
  final before = FileStat.statSync(path);
  var absent = false;
  try {
    final socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    ).timeout(const Duration(milliseconds: 500));
    socket.destroy();
  } on SocketException catch (error) {
    final code = error.osError?.errorCode;
    absent = code == 111 || code == 2;
  } on TimeoutException {
    absent = false;
  }
  if (!absent) throw const MomentsError('Preview socket still accepts connections');
  if (exists(path)) {
    final now = FileStat.statSync(path);
    if (now.changed != before.changed || now.modified != before.modified)
      throw const MomentsError('Preview socket changed');
    File(path).deleteSync();
  }
}

bool _equal(String a, String b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return difference == 0;
}

/// A product preview surface, not remote control of arbitrary browser tabs:
/// one frontend document owns sandboxed iframes at explicitly allowed URLs.
final class PreviewHost {
  PreviewHost._(this.url, this.socket, this.provider, this._close);
  final String url, socket, provider;
  final Future<void> Function() _close;
  String get scope => 'sandboxed Flutter iframe previews owned by one browser document; not native tabs';
  Future<void> close() => _close();

  Map<String, Object?> toJson() => {'url': url, 'socket': socket, 'provider': provider, 'scope': scope};

  static Future<PreviewHost> serve({
    required String directory,
    required int port,
    required List<String> origins,
  }) async {
    final home = p.normalize(p.absolute(directory));
    makePrivateDirectory(home, recursive: true);
    if (realPath(home) != home || entityType(home) != FileSystemEntityType.directory || !private(home)) {
      throw const MomentsError('Private preview host directory required');
    }
    if (port < 1 ||
        port > 65535 ||
        origins.isEmpty ||
        origins.length > 128 ||
        origins.toSet().length != origins.length) {
      throw const MomentsError('Declare preview port and actor origins');
    }
    for (final value in origins) {
      final url = Uri.tryParse(value);
      if (url == null ||
          '${url.scheme}://${url.host}:${url.port}' != value ||
          url.scheme != 'http' ||
          url.host != '127.0.0.1' ||
          !url.hasPort ||
          url.port == port) {
        throw const MomentsError('Preview origins must be explicit loopback ports distinct from the host');
      }
    }
    final release = await acquireInstanceLock(home);
    final origin = 'http://127.0.0.1:$port', socketPath = p.join(home, 'browser.sock');
    HttpServer? server;
    BrowserHost? rpc;
    HttpResponse? stream;
    Timer? heartbeat;
    var closing = false;
    final pending = <String, ({Completer<Map<String, Object?>> completer, Timer timer, Object? document})>{};
    late Map<String, Object?> config, state;
    void save() => savePrivateState(p.join(home, 'frontend.json'), state);
    void disconnect() {
      final current = stream;
      stream = null;
      unawaited(current?.close().catchError((_) {}));
    }

    void rejectAll(String message) {
      for (final entry in pending.values) {
        entry.timer.cancel();
        if (!entry.completer.isCompleted) entry.completer.completeError(MomentsError(message));
      }
      pending.clear();
    }

    Future<void> close() async {
      if (closing) return;
      closing = true;
      heartbeat?.cancel();
      disconnect();
      rejectAll('Preview host stopped; surfaces remain unconfirmed');
      await rpc?.close();
      await server?.close(force: true);
      await release();
    }

    try {
      final file = p.join(home, 'preview.json');
      if (exists(file)) {
        config = _read(file);
        if (config['version'] != 1 ||
            !isUuid(config['id']) ||
            config['port'] != port ||
            jsonEncode(config['origins']) != jsonEncode(origins) ||
            !sha256Pattern.hasMatch('${config['token'] ?? ''}')) {
          throw const MomentsError('Preview host configuration changed; use its original origins and port');
        }
      } else {
        config = {'version': 1, 'id': uuidV4(), 'port': port, 'origins': origins, 'token': _hex(32)};
        savePrivateState(file, config);
      }
      final frontend = p.join(home, 'frontend.json');
      state = exists(frontend)
          ? _read(frontend)
          : {'version': 2, 'document': null, 'browser': null, 'frames': <String, Object?>{}};
      final frames0 = state['frames'];
      if (!const [1, 2].contains(state['version']) ||
          (state['document'] != null && !isUuid(state['document'])) ||
          frames0 is! Map ||
          frames0.length > 128) {
        throw const MomentsError('Invalid preview frontend identity');
      }
      final frames = state['frames'] = frames0.map((k, v) => MapEntry(k as String, (v as Map).cast<String, Object?>()));
      String location(Object? value) {
        final canonical = actorBrowserLocation(value);
        final url = Uri.parse(canonical);
        if (!origins.contains('${url.scheme}://${url.host}:${url.port}'))
          throw const MomentsError('Actor origin not allowed');
        return canonical;
      }

      String actorOf(String url) => Uri.parse(url).queryParameters['momentsActor']!;
      for (final MapEntry(key: id, value: frame) in frames.entries) {
        if (!isUuid(id) ||
            actorOf(location(frame['url'])) != id ||
            !const ['pending', 'present', 'closed'].contains(frame['phase'])) {
          throw const MomentsError('Invalid preview surface record');
        }
      }
      int active() => frames.values.where((f) => f['phase'] != 'closed').length;
      // A legacy document never held a browser lock. It cannot safely be fenced
      // by the new protocol while any of its surfaces remain unconfirmed.
      if (state['version'] == 1) {
        if (active() > 0) throw const MomentsError('Close legacy previews with their original host before upgrading');
        state = {...state, 'version': 2, 'document': null, 'browser': null};
        save();
      }
      if (state['browser'] != null && !sha256Pattern.hasMatch('${state['browser']}')) {
        throw const MomentsError('Invalid preview browser binding');
      }
      final providerId = 'mana-preview-${config['id']}';
      Future<Map<String, Object?>> request(String method, Map<String, Object?> target) {
        final current = stream;
        if (current == null) {
          throw const MomentsError('Open the preview host page before materializing; its document must stay connected');
        }
        if (pending.isNotEmpty) throw const MomentsError('Preview frontend is busy');
        final id = uuidV4();
        final deadline = DateTime.now().add(const Duration(seconds: 10)).millisecondsSinceEpoch;
        final completer = Completer<Map<String, Object?>>();
        final timer = Timer(const Duration(seconds: 10), () {
          pending.remove(id);
          if (!completer.isCompleted)
            completer.completeError(const MomentsError('Preview frontend response lost; resources retained'));
        });
        pending[id] = (completer: completer, timer: timer, document: state['document']);
        current.write(
          '${jsonEncode({'version': 1, 'id': id, 'method': method, 'target': target, 'deadline': deadline})}\n',
        );
        return completer.future;
      }

      Map<String, Object?> surface(String id) => frames[id] ?? (throw const MomentsError('Unowned preview surface'));
      final browserProvider = BrowserProvider(
        id: providerId,
        open: (raw) async {
          final url = location(raw), id = actorOf(url);
          if (stream == null) throw const MomentsError('Connect the preview document before opening');
          if (frames.containsKey(id)) throw const MomentsError('Preview opening cannot be repeated');
          if (frames.length >= 128) throw const MomentsError('Preview host capacity reached');
          frames[id] = {'url': url, 'phase': 'pending'};
          save();
          final result = await request('open', {'id': id, 'url': url});
          if (result['id'] != id || result['status'] != 'present' || location(result['url']) != url) {
            throw const MomentsError('Preview opening unconfirmed');
          }
          frames[id]!['phase'] = 'present';
          save();
          return result;
        },
        find: (raw) async {
          final url = location(raw), id = actorOf(url);
          // Every UI dispatch follows a persisted intent. No record means this
          // host never dispatched an opening for this nonce.
          if (!frames.containsKey(id)) return {'matches': <Object?>[], 'settled': true};
          final record = surface(id);
          if (record['url'] != url) throw const MomentsError('Preview URL changed');
          if (record['phase'] == 'closed') return {'matches': <Object?>[], 'settled': true};
          final result = await request('find', {'id': id, 'url': url});
          final matches = result['matches'];
          if (matches is! List ||
              matches.length > 1 ||
              result['settled'] != true ||
              matches.any((v) => v is! Map || v['id'] != id || v['status'] != 'present' || location(v['url']) != url)) {
            throw const MomentsError('Preview reconciliation incomplete');
          }
          record['phase'] = matches.isNotEmpty ? 'present' : 'closed';
          save();
          return result;
        },
        inspect: (id) async {
          final record = surface(id);
          if (record['phase'] == 'closed') return {'id': id, 'status': 'absent'};
          final result = await request('inspect', {'id': id});
          if (result['id'] != id ||
              !const ['present', 'absent'].contains(result['status']) ||
              (result['status'] == 'present' && location(result['url']) != record['url'])) {
            throw const MomentsError('Preview identity changed');
          }
          record['phase'] = result['status'] == 'present' ? 'present' : 'closed';
          save();
          return result;
        },
        close: (id) async {
          final record = surface(id);
          if (record['phase'] == 'closed') return;
          final result = await request('close', {'id': id});
          if (result['id'] != id || result['status'] != 'absent')
            throw const MomentsError('Preview closure unconfirmed');
          record['phase'] = 'closed';
          save();
        },
        reveal: (id) async {
          final record = surface(id);
          if (record['phase'] != 'present') throw const MomentsError('Preview is not present');
          final result = await request('reveal', {'id': id});
          if (result['id'] != id || result['status'] != 'present' || location(result['url']) != record['url']) {
            throw const MomentsError('Preview reveal unconfirmed');
          }
          return result;
        },
      );
      bool authorized(HttpRequest request) =>
          _equal(request.headers.value('authorization') ?? '', 'Bearer ${config['token']}');
      final assets = p.join(momentsRoot(), 'preview');
      const files = {'/': 'index.html', '/host.js': 'host.js', '/host.css': 'host.css'};
      final http = server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      http.idleTimeout = const Duration(seconds: 15);
      http.listen((request) async {
        final response = request.response;
        response.headers
          ..set('Cache-Control', 'no-store')
          ..set('X-Content-Type-Options', 'nosniff')
          ..set('Referrer-Policy', 'no-referrer')
          ..set(
            'Content-Security-Policy',
            "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-src ${origins.join(' ')}; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
          );
        Future<void> reply(int code, Object? value) async {
          response
            ..statusCode = code
            ..headers.contentType = ContentType.json
            ..write(jsonEncode(value));
          await response.close();
        }

        try {
          final requestOrigin = request.headers.value('origin');
          if (request.headers.value('host') != '127.0.0.1:$port' ||
              (requestOrigin != null && requestOrigin != origin)) {
            return await reply(403, {'error': 'Origin refused'});
          }
          final path = request.uri.path;
          if (request.method == 'GET' && files.containsKey(path)) {
            response.headers.set(
              'Content-Type',
              path.endsWith('.js')
                  ? 'text/javascript'
                  : path.endsWith('.css')
                  ? 'text/css'
                  : 'text/html; charset=utf-8',
            );
            response.add(File(p.join(assets, files[path]!)).readAsBytesSync());
            await response.close();
            return;
          }
          if (request.method == 'GET' && path == '/health') {
            return await reply(200, {
              'status': stream != null ? 'connected' : 'waiting',
              'surfaces': active(),
              'provider': providerId,
              'protocol': 2,
            });
          }
          if (request.method == 'GET' && path == '/events') {
            if (!authorized(request) || request.uri.queryParameters['document'] != state['document']) {
              return await reply(403, {'error': 'Frontend identity refused'});
            }
            if (stream != null) return await reply(409, {'error': 'Frontend already connected'});
            response
              ..statusCode = 200
              ..headers.set('Content-Type', 'application/x-ndjson; charset=utf-8')
              ..bufferOutput = false
              ..write('${jsonEncode({'type': 'connected'})}\n');
            stream = response;
            unawaited(
              response.done
                  .whenComplete(() {
                    if (stream == response) stream = null;
                  })
                  .catchError((_) {}),
            );
            return;
          }
          if (request.method != 'POST' ||
              requestOrigin != origin ||
              request.headers.value('content-type') != 'application/json') {
            return await reply(403, {'error': 'Same-origin JSON required'});
          }
          final bytes = <int>[];
          await for (final chunk in request) {
            bytes.addAll(chunk);
            if (bytes.length > 16384) return await reply(413, {'error': 'Request too large'});
          }
          final message = (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();
          if (path == '/join') {
            final ownership = message['ownership'] as Map?;
            if (!isUuid(message['document'])) return await reply(400, {'error': 'Document identity required'});
            if (message['protocol'] != 2 ||
                ownership?['kind'] != 'web-lock-v1' ||
                !sha256Pattern.hasMatch('${ownership?['browserKey'] ?? ''}')) {
              return await reply(409, {
                'error': 'Use the current host page with Web Locks and local storage available.',
              });
            }
            final browser = sha256.convert(utf8.encode(ownership!['browserKey']! as String)).toString();
            if (state['browser'] != browser && (active() > 0 || stream != null)) {
              return await reply(409, {
                'error':
                    'Resume this host in the same browser profile. Another profile does not prove the previews were closed.',
              });
            }
            if (state['document'] != message['document']) {
              // The trusted bundled frontend acquired its exclusive Web Lock in
              // the SAME storage context. It never releases that lock with live
              // frames, nor steals it. This is not proof from an arbitrary HTTP
              // peer: custom clients assume the ownership contract.
              disconnect();
              rejectAll('Preview document ended; opening must be reconciled');
              final previous = state['document'], retired = active();
              for (final frame in frames.values) {
                if (frame['phase'] != 'closed') {
                  frame
                    ..['phase'] = 'closed'
                    ..['closedBy'] = 'document-replaced';
                }
              }
              state['handoff'] = {
                'previous': previous,
                'current': message['document'],
                'retired': retired,
                'at': DateTime.now().toUtc().toIso8601String(),
                'evidence': 'same-browser-exclusive-web-lock',
              };
            }
            state
              ..['document'] = message['document']
              ..['browser'] = browser;
            save();
            return await reply(200, {
              'version': 2,
              'token': config['token'],
              'origins': origins,
              'provider': providerId,
              'handoff': state['handoff'],
            });
          }
          if (!authorized(request) || message['document'] != state['document']) {
            return await reply(403, {'error': 'Frontend identity refused'});
          }
          if (path == '/reply') {
            final entry = pending[message['id']];
            if (entry == null || entry.document != state['document'])
              return await reply(409, {'error': 'Operation expired'});
            pending.remove(message['id']);
            entry.timer.cancel();
            if (message['error'] != null) {
              entry.completer.completeError(const MomentsError('Preview document refused operation'));
            } else {
              entry.completer.complete(((message['result'] as Map?) ?? const {}).cast());
            }
            return await reply(200, {'accepted': true});
          }
          return await reply(404, {'error': 'Unknown operation'});
        } on Object {
          try {
            await reply(400, {'error': 'Invalid preview request'});
          } on Object {
            // The response was already committed.
          }
        }
      });
      heartbeat = Timer.periodic(const Duration(seconds: 1), (_) => stream?.write('{"type":"ping"}\n'));
      await _removeStaleSocket(socketPath);
      rpc = await BrowserHost.serve(path: socketPath, provider: browserProvider, openOrigins: origins);
      final supervisor = processIdentity(pid);
      savePrivateState(p.join(home, 'host.json'), {
        'version': 1,
        'supervisor': supervisor == null ? null : identityJson(supervisor),
        'provider': providerId,
        'url': origin,
        'socket': socketPath,
      });
      return PreviewHost._(origin, socketPath, providerId, close);
    } on Object {
      await close();
      rethrow;
    }
  }
}
