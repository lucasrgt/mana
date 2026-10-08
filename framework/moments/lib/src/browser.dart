import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show identityJson, processIdentity, savePrivateState, syncDirectory, uuidV4;
import 'package:path/path.dart' as p;

import 'errors.dart';
import 'lifecycle.dart';
import 'private_fs.dart';

typedef BrowserResult = Map<String, Object?>;

/// Browser operations supplied by a host (e.g. a computer-use tool). Each
/// operation is optional; callers require the ones they need.
final class BrowserProvider {
  BrowserProvider({required this.id, this.open, this.resolve, this.inspect, this.reveal, this.close, this.find});
  final String id;
  final Future<BrowserResult> Function(String url)? open, resolve, find;
  final Future<BrowserResult> Function(String tabId)? inspect, reveal;
  final Future<void> Function(String tabId)? close;
}

bool _key(Object? value) => value is String && value.isNotEmpty && value.length <= 256;

/// The WHATWG href of an http(s) URL without its fragment: browsers report
/// tab locations in this form.
String href(Uri url) {
  final value = url.removeFragment();
  return (value.path.isEmpty ? value.replace(path: '/') : value).toString();
}

Uri? _parse(Object? value) {
  if (value is! String) return null;
  final url = Uri.tryParse(value);
  return url != null && url.hasScheme && url.host.isNotEmpty ? url : null;
}

/// The canonical location of an actor tab: http(s), no credentials and
/// exactly one `momentsActor` nonce.
String actorBrowserLocation(Object? url) {
  if (url is! String || url.length > 2048) throw const MomentsError('Invalid actor browser URL');
  final value = _parse(url);
  if (value == null) throw const MomentsError('Invalid actor browser URL');
  final actors = value.queryParametersAll['momentsActor'] ?? const [];
  if (!const ['http', 'https'].contains(value.scheme) ||
      value.userInfo.isNotEmpty ||
      actors.length != 1 ||
      !isUuid(actors.single)) {
    throw const MomentsError('Browser host requires a scoped actor URL');
  }
  return href(value);
}

String _origin(String value) {
  final url = _parse(value);
  if (url == null ||
      '${url.scheme}://${url.host}:${url.port}' != value ||
      url.scheme != 'http' ||
      url.host != '127.0.0.1' ||
      !url.hasPort) {
    throw const MomentsError('Browser opening requires explicit loopback origins');
  }
  return value;
}

String _originOf(String url) {
  final value = Uri.parse(url);
  return '${value.scheme}://${value.host}${value.hasPort ? ':${value.port}' : ''}';
}

/// The intent is durable before the host's UI side effect. An ambiguous
/// opening can only be reconciled by its nonce, never repeated because a reply
/// was lost.
final class BrowserOpenings {
  BrowserOpenings({
    required String directory,
    required this.provider,
    required List<String> origins,
    required this.bind,
  }) : _home = p.join(directory, 'browser-openings') {
    if (origins.length > 128 ||
        origins.toSet().length != origins.length ||
        !_key(provider.id) ||
        (origins.isNotEmpty && (provider.open == null || provider.find == null))) {
      throw const MomentsError('Invalid browser opening adapter');
    }
    _allowed = origins.map(_origin).toSet();
    if (!exists(_home)) makePrivateDirectory(_home);
    if (entityType(_home) != FileSystemEntityType.directory || !private(_home)) {
      throw const MomentsError('Browser opening journal must be private and owned');
    }
    final files = Directory(_home).listSync();
    if (files.length > 256) throw const MomentsError('Browser opening journal exceeds its bound');
    for (final entry in files) {
      if (!RegExp(r'^[a-f0-9-]{36}\.json$').hasMatch(p.basename(entry.path))) continue;
      final record = _read(entry.path);
      if (record['tabId'] case final String tab) bind(tab, record['url']! as String);
    }
  }

  final BrowserProvider provider;
  final void Function(String id, String url) bind;
  final String _home;
  late final Set<String> _allowed;

  String _fileFor(String canonical) => p.join(_home, '${Uri.parse(canonical).queryParameters['momentsActor']}.json');

  int _records() => Directory(_home).listSync().where((e) => e.path.endsWith('.json')).length;

  Map<String, Object?> _read(String file) {
    final record = readJsonObject(file, 8192, 'Invalid browser opening record', privateOnly: true);
    final url = record['url'];
    final phase = record['phase'];
    if (record['version'] != 1 ||
        record['provider'] != provider.id ||
        !const ['opening', 'attached', 'cancelled'].contains(phase) ||
        (const ['opening', 'cancelled'].contains(phase) && record['tabId'] != null) ||
        (phase == 'attached' && !_key(record['tabId'])) ||
        url is! String ||
        actorBrowserLocation(url) != url ||
        (record.containsKey('rejection') && !(phase == 'cancelled' && record['rejection'] == 'origin-not-allowed')) ||
        (!_allowed.contains(_originOf(url)) && record['rejection'] != 'origin-not-allowed') ||
        file != _fileFor(url)) {
      throw const MomentsError('Browser opening identity changed');
    }
    return record;
  }

  void _create(String file, Map<String, Object?> record) {
    createExclusive(file, utf8.encode('${jsonEncode(record)}\n'));
    syncDirectory(_home);
  }

  Future<BrowserResult> _inspect(Map<String, Object?> record) async {
    final tab = record['tabId']! as String;
    bind(tab, record['url']! as String);
    final result = await provider.inspect!(tab);
    if (result['id'] != tab ||
        !const ['present', 'absent'].contains(result['status']) ||
        (result['status'] == 'present' && actorBrowserLocation(result['url']) != record['url'])) {
      throw const MomentsError('Opened browser tab identity changed');
    }
    return result['status'] == 'absent'
        ? {'id': tab, 'status': 'absent'}
        : {'id': tab, 'status': 'present', 'url': result['url']};
  }

  Future<BrowserResult> _attach(String file, Map<String, Object?> record, Object? result) async {
    final id = result is Map ? result['id'] : null;
    if (!_key(id)) throw const MomentsError('Browser opening has no tab identity');
    record
      ..['tabId'] = id
      ..['phase'] = 'attached';
    savePrivateState(file, record);
    return _inspect(record);
  }

  Future<BrowserResult> resolve(String url, {bool open = false}) async {
    final canonical = actorBrowserLocation(url);
    final file = _fileFor(canonical);
    if (!_allowed.contains(_originOf(canonical)) && !exists(file)) {
      // This host cannot dispatch the URL. Persist terminal cancellation so
      // cleanup can tell a policy refusal from a lost opening reply.
      if (_records() >= 256) throw const MomentsError('Browser cancellation capacity reached');
      _create(file, {
        'version': 1,
        'provider': provider.id,
        'url': canonical,
        'phase': 'cancelled',
        'tabId': null,
        'rejection': 'origin-not-allowed',
      });
      if (open) throw const MomentsError('Browser origin is not authorized for opening');
      return {'status': 'absent', 'unopened': true, 'url': canonical};
    }
    if (!exists(file)) {
      if (!open) throw const MomentsError('No browser opening intent exists');
      if (_records() >= 128) throw const MomentsError('Browser opening capacity reached');
      final record = <String, Object?>{
        'version': 1,
        'provider': provider.id,
        'url': canonical,
        'phase': 'opening',
        'tabId': null,
      };
      _create(file, record);
      // Never retry this call, even when the host reports a timeout.
      return _attach(file, record, await provider.open!(canonical));
    }
    final record = _read(file);
    if (record['url'] != canonical) throw const MomentsError('Actor nonce was already bound to another URL');
    if (record['phase'] == 'cancelled') return {'status': 'absent', 'unopened': true, 'url': canonical};
    if (record['tabId'] != null) return _inspect(record);
    final result = await provider.find!(canonical);
    final matches = result['matches'];
    // Stronger than an empty inventory: the host guarantees that all opens
    // for this nonce have settled and no delayed open can execute.
    if (result['settled'] == true && matches is List && matches.isEmpty) {
      record['phase'] = 'cancelled';
      savePrivateState(file, record);
      return {'status': 'absent', 'unopened': true, 'url': canonical};
    }
    if (matches is! List ||
        matches.length != 1 ||
        matches.single is! Map ||
        (matches.single as Map)['status'] != 'present' ||
        actorBrowserLocation((matches.single as Map)['url']) != canonical) {
      throw const MomentsError('Browser opening remains ambiguous; resources retained');
    }
    return _attach(file, record, matches.single);
  }
}

void _socketParent(String path) {
  final dir = p.dirname(path);
  if (realPath(dir) != dir || entityType(dir) != FileSystemEntityType.directory || !private(dir)) {
    throw const MomentsError('Browser socket requires a private owned directory');
  }
}

void _socket(String path) {
  _socketParent(path);
  if (entityType(path) != FileSystemEntityType.unixDomainSock || !private(path)) {
    throw const MomentsError('Browser socket is not private and owned');
  }
}

/// A provider that forwards each operation over a private Unix socket to a
/// browser host. One request per connection, bounded and nonce-checked.
BrowserProvider browserSocketProvider({
  required String path,
  required String id,
  Duration timeout = const Duration(seconds: 15),
}) {
  final socketPath = p.normalize(p.absolute(path));
  if (!_key(id)) throw const MomentsError('Browser provider ID required');
  _socket(socketPath);
  Future<BrowserResult> request(String method, String target) async {
    final opening = const ['open', 'resolve'].contains(method);
    if (!opening && !_key(target)) throw const MomentsError('Invalid browser tab ID');
    final payload = opening ? {'url': actorBrowserLocation(target)} : {'tabId': target};
    final requestId = uuidV4();
    final Socket connection;
    try {
      connection = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
      ).timeout(timeout);
    } on Object {
      throw const MomentsError('Browser host unavailable; resources retained');
    }
    try {
      connection.write(
        '${jsonEncode({'version': 1, 'id': requestId, 'provider': id, 'method': method, ...payload})}\n',
      );
      final buffer = <int>[];
      final completer = Completer<BrowserResult>();
      late final StreamSubscription<List<int>> subscription;
      subscription = connection.listen(
        (chunk) {
          buffer.addAll(chunk);
          if (buffer.length > 16384) {
            if (!completer.isCompleted) completer.completeError(const MomentsError('Browser response too large'));
            return;
          }
          final end = buffer.indexOf(10);
          if (end < 0 || completer.isCompleted) return;
          try {
            final value = jsonDecode(utf8.decode(buffer.sublist(0, end)));
            if (value is! Map ||
                value['version'] != 1 ||
                value['id'] != requestId ||
                value['provider'] != id ||
                value['error'] != null ||
                value['result'] is! Map) {
              throw const MomentsError('Browser host refused or returned an invalid response');
            }
            completer.complete((value['result'] as Map).cast());
          } on Object catch (error) {
            completer.completeError(
              error is MomentsError
                  ? error
                  : const MomentsError('Browser host refused or returned an invalid response'),
            );
          }
        },
        onError: (_) {
          if (!completer.isCompleted)
            completer.completeError(const MomentsError('Browser host unavailable; resources retained'));
        },
        onDone: () {
          if (!completer.isCompleted)
            completer.completeError(const MomentsError('Browser host ended before confirmation'));
        },
      );
      try {
        return await completer.future.timeout(
          timeout,
          onTimeout: () => throw const MomentsError('Browser host timed out; resources retained'),
        );
      } finally {
        await subscription.cancel();
      }
    } finally {
      connection.destroy();
    }
  }

  return BrowserProvider(
    id: id,
    open: (url) => request('open', url),
    resolve: (url) => request('resolve', url),
    inspect: (tab) => request('inspect', tab),
    reveal: (tab) => request('reveal', tab),
    close: (tab) async {
      final result = await request('close', tab);
      if (result['id'] != tab || result['status'] != 'absent') {
        throw const MomentsError('Browser host did not confirm closure');
      }
    },
  );
}

/// A host injects browser APIs. Only tabs explicitly bound to this host may be
/// inspected or closed. New tabs require explicit local origins and a durable
/// nonce-bound intent. There is no navigation or arbitrary script RPC.
final class BrowserHost {
  BrowserHost._(this.path, this._server, this._identity);
  final String path;
  final ServerSocket _server;
  final ({int device, int inode})? _identity;
  final _connections = <Socket>{};

  static ({int device, int inode})? _stat(String path) {
    final result = Process.runSync('stat', ['-c', '%d %i', '--', path]);
    if (result.exitCode != 0) return null;
    final parts = (result.stdout as String).trim().split(' ');
    return (device: int.parse(parts[0]), inode: int.parse(parts[1]));
  }

  static Future<BrowserHost> serve({
    required String path,
    required BrowserProvider provider,
    List<({String id, String url})> tabs = const [],
    List<String> openOrigins = const [],
  }) async {
    final socketPath = p.normalize(p.absolute(path));
    _socketParent(socketPath);
    if (!_key(provider.id) || provider.inspect == null || provider.close == null || tabs.length > 128) {
      throw const MomentsError('Invalid browser host adapter');
    }
    final allowed = <String, String>{};
    for (final tab in tabs) {
      if (!_key(tab.id)) throw const MomentsError('Invalid host tab');
      allowed[tab.id] = actorBrowserLocation(tab.url);
    }
    if (allowed.length != tabs.length) throw const MomentsError('Duplicate host tab');
    final openings = BrowserOpenings(
      directory: p.dirname(socketPath),
      provider: provider,
      origins: openOrigins,
      bind: (id, url) {
        if (allowed.containsKey(id) && allowed[id] != url) {
          throw const MomentsError('Browser tab is already bound to another actor');
        }
        if (!allowed.containsKey(id) && allowed.length >= 256) {
          throw const MomentsError('Browser host tab capacity reached');
        }
        allowed[id] = url;
      },
    );
    Future<BrowserResult> inspect(String id) async {
      final result = await provider.inspect!(id);
      if (result['id'] != id || !const ['present', 'absent'].contains(result['status'])) {
        throw const MomentsError('Browser inspection incomplete');
      }
      if (result['status'] == 'present' && actorBrowserLocation(result['url']) != allowed[id]) {
        throw const MomentsError('Browser tab no longer matches its binding');
      }
      return result['status'] == 'absent'
          ? {'id': id, 'status': 'absent'}
          : {'id': id, 'status': 'present', 'url': result['url']};
    }

    final server = await ServerSocket.bind(InternetAddress(socketPath, type: InternetAddressType.unix), 0);
    Process.runSync('chmod', ['600', socketPath]);
    final host = BrowserHost._(socketPath, server, _stat(socketPath));
    var busy = false;
    server.listen((connection) {
      if (host._connections.length >= 4) {
        connection.destroy();
        return;
      }
      host._connections.add(connection);
      final buffer = <int>[];
      var used = false;
      final timer = Timer(const Duration(seconds: 15), connection.destroy);
      void reply(Object? message) {
        timer.cancel();
        connection
          ..write('${jsonEncode(message)}\n')
          ..close().catchError((_) => connection);
      }

      connection.listen(
        (chunk) async {
          if (used) return;
          buffer.addAll(chunk);
          if (buffer.length > 4096) {
            connection.destroy();
            return;
          }
          final end = buffer.indexOf(10);
          if (end < 0) return;
          used = true;
          Map? message;
          var entered = false;
          try {
            final decoded = jsonDecode(utf8.decode(buffer.sublist(0, end)));
            message = decoded is Map ? decoded : null;
            final method = message?['method'];
            final opening = const ['open', 'resolve'].contains(method);
            final tab = message?['tabId'];
            if (message == null ||
                message['version'] != 1 ||
                !isUuid(message['id']) ||
                message['provider'] != provider.id ||
                !const ['inspect', 'close', 'open', 'resolve', 'reveal'].contains(method) ||
                (!opening && (tab is! String || !allowed.containsKey(tab)))) {
              throw const MomentsError('Unscoped browser request');
            }
            if (busy) throw const MomentsError('Browser host is busy');
            busy = true;
            entered = true;
            var result = opening
                ? await openings.resolve('${message['url']}', open: method == 'open')
                : await inspect(tab! as String);
            if (method == 'reveal') {
              if (result['status'] != 'present' || provider.reveal == null) {
                throw const MomentsError('Host cannot reveal this surface');
              }
              await provider.reveal!(tab! as String);
              result = await inspect(tab);
              if (result['status'] != 'present') throw const MomentsError('Revealed surface is absent');
            }
            if (method == 'close' && result['status'] == 'present') {
              await provider.close!(tab! as String);
              result = await inspect(tab);
              if (result['status'] != 'absent') throw const MomentsError('Tab remains open');
            }
            reply({'version': 1, 'id': message['id'], 'provider': provider.id, 'result': result});
          } on Object {
            reply({
              'version': 1,
              'id': message?['id'],
              'provider': provider.id,
              'error': 'Browser operation unconfirmed; inspect the host',
            });
          } finally {
            if (entered) busy = false;
          }
        },
        onError: (_) {},
        onDone: () {
          timer.cancel();
          host._connections.remove(connection);
        },
      );
    });
    return host;
  }

  Future<void> close() async {
    for (final connection in [..._connections]) {
      connection.destroy();
    }
    await _server.close();
    // Never unlink a replacement socket.
    if (exists(path) && _identity != null && _stat(path) == _identity) File(path).deleteSync();
  }
}

/// This boundary owns only an explicitly attached tab. The provider is
/// supplied by the host; a dead socket is never evidence that a tab is closed.
final class BrowserBoundary {
  BrowserBoundary._(this._dir, this._record, {this.recovered = false});

  final String _dir;
  final Map<String, Object?> _record;
  final bool recovered;

  String get phase => _record['phase']! as String;
  Map<String, Object?>? get tab {
    final value = _record['tab'] as Map?;
    return value == null ? null : {...value.cast<String, Object?>()};
  }

  String? get url => _record['url'] as String?;

  static bool _matches(Object? url, Map<String, Object?> record) {
    final actual = _parse(url), expected = _parse(record['url']);
    String path(Uri value) => value.path.isEmpty ? '/' : value.path;
    return actual != null &&
        expected != null &&
        _originOf('$actual') == _originOf('$expected') &&
        path(actual) == path(expected) &&
        actual.query == expected.query;
  }

  void _save(String phase) {
    _record['phase'] = phase;
    savePrivateState(p.join(_dir, 'browser.json'), _record);
  }

  String _begin(String url, [String? providerId]) {
    if (recovered || _record['phase'] != 'unused') throw const MomentsError('Browser opening cannot be replayed');
    final value = _parse(url);
    if (value == null || !const ['http', 'https'].contains(value.scheme) || value.userInfo.isNotEmpty) {
      throw const MomentsError('Unsupported actor browser URL');
    }
    _record['url'] = href(value.replace(queryParameters: {...value.queryParameters, 'momentsActor': _record['owner']}));
    if (providerId != null) _record['openingProvider'] = providerId;
    _save('opening');
    return _record['url']! as String;
  }

  Future<BrowserResult> _inspect(BrowserProvider? provider) async {
    final tab = _record['tab'] as Map?;
    if (provider == null || provider.id != tab?['provider'] || provider.inspect == null) {
      throw const MomentsError('Matching browser provider required');
    }
    final state = await provider.inspect!(tab!['id']! as String);
    if (state['id'] != tab['id'] || !const ['present', 'absent'].contains(state['status'])) {
      throw const MomentsError('Browser provider did not identify the tab');
    }
    if (state['status'] == 'present' && !_matches(state['url'], _record)) {
      throw const MomentsError('Browser tab identity changed; inspect before closing');
    }
    return state;
  }

  String expect(String url) => _begin(url);

  Future<({String url, Map<String, Object?>? tab})> open(String url, BrowserProvider provider) async {
    if (!_key(provider.id) || provider.open == null || provider.resolve == null || provider.inspect == null) {
      throw const MomentsError('Browser host must support opening and reconciliation');
    }
    _begin(url, provider.id);
    final result = await provider.open!(_record['url']! as String);
    await attach(provider: provider, id: result['id']);
    return (url: _record['url']! as String, tab: tab);
  }

  Future<void> attach({required BrowserProvider provider, required Object? id}) async {
    if (_record['phase'] != 'opening' ||
        !_key(provider.id) ||
        !_key(id) ||
        (_record.containsKey('openingProvider') && _record['openingProvider'] != provider.id)) {
      throw const MomentsError('Browser attachment is not pending');
    }
    // Persist the identity before inspecting, so a lost response stays owned.
    _record['tab'] = {'provider': provider.id, 'id': id};
    _save('attached');
    if ((await _inspect(provider))['status'] != 'present') throw const MomentsError('Attached browser tab is absent');
  }

  Future<Map<String, Object?>> close(BrowserProvider? provider) async {
    if (_record['phase'] == 'unused') return {'status': 'closed', 'opened': false};
    // Closure is terminal for this nonce: no supported path can reopen it.
    // A repeated cleanup must not depend on a host that has already shut down.
    if (_record['phase'] == 'closed') {
      return {'status': 'closed', 'opened': _record['unopened'] != true, if (tab != null) 'tab': tab};
    }
    if (_record['phase'] == 'opening') {
      if (_record['openingProvider'] == null) {
        throw const MomentsError('Browser opening has no tab identity; reconcile it before cleanup');
      }
      if (provider?.id != _record['openingProvider'] || provider?.resolve == null) {
        throw const MomentsError('Matching browser reconciliation provider required');
      }
      final result = await provider!.resolve!(_record['url']! as String);
      if (result['status'] == 'absent' && result['unopened'] == true && _matches(result['url'], _record)) {
        _record['unopened'] = true;
        _save('closed');
        return {'status': 'closed', 'opened': false};
      }
      if (!_key(result['id']) ||
          !const ['present', 'absent'].contains(result['status']) ||
          (result['status'] == 'present' && !_matches(result['url'], _record))) {
        throw const MomentsError('Browser opening remains unconfirmed');
      }
      _record['tab'] = {'provider': provider.id, 'id': result['id']};
      _save('attached');
    }
    final state = await _inspect(provider);
    if (state['status'] == 'present') {
      if (provider!.close == null) throw const MomentsError('Browser provider cannot close the owned tab');
      await provider.close!((_record['tab']! as Map)['id']! as String);
      if ((await _inspect(provider))['status'] != 'absent') throw const MomentsError('Owned browser tab remains open');
    }
    _save('closed');
    return {'status': 'closed', 'opened': true, 'tab': tab};
  }

  void assertClosed() {
    if (!const ['unused', 'closed'].contains(_record['phase'])) {
      throw const MomentsError('Owned browser closure is unconfirmed');
    }
  }
}

BrowserBoundary allocateBrowserBoundary(String dir) {
  final supervisor = processIdentity(pid);
  if (supervisor == null) throw const MomentsError('Cannot identify browser boundary supervisor');
  final record = <String, Object?>{
    'version': 1,
    'owner': uuidV4(),
    'supervisor': identityJson(supervisor),
    'phase': 'unused',
    'url': null,
    'tab': null,
  };
  createExclusive(p.join(dir, 'browser.json'), utf8.encode('${jsonEncode(record)}\n'));
  syncDirectory(dir);
  return BrowserBoundary._(dir, record);
}

BrowserBoundary recoverBrowserBoundary(String dir) {
  final record = readJsonObject(p.join(dir, 'browser.json'), 16384, 'Invalid browser boundary record');
  final supervisor = record['supervisor'], phase = record['phase'], tab = record['tab'];
  if (record['version'] != 1 ||
      !isUuid(record['owner']) ||
      !const ['unused', 'opening', 'attached', 'closed'].contains(phase) ||
      supervisor is! Map ||
      supervisor['pid'] is! int ||
      (supervisor['pid']! as int) < 1 ||
      !RegExp(r'^\d+$').hasMatch('${supervisor['start'] ?? ''}') ||
      !isUuid(supervisor['boot'])) {
    throw const MomentsError('Invalid browser boundary identity');
  }
  if (phase != 'unused') {
    final url = _parse(record['url']);
    if (url == null ||
        !const ['http', 'https'].contains(url.scheme) ||
        url.queryParameters['momentsActor'] != record['owner']) {
      throw const MomentsError('Invalid browser boundary URL');
    }
  }
  final unopened = record['unopened'], openingProvider = record['openingProvider'];
  final tabOk = tab is Map && _key(tab['provider']) && _key(tab['id']);
  if ((phase == 'unused' && (record['url'] != null || tab != null)) ||
      (const ['attached', 'closed'].contains(phase) &&
          !(phase == 'closed' && unopened == true && tab == null && _key(openingProvider)) &&
          !tabOk) ||
      (record.containsKey('unopened') && !(unopened == true && phase == 'closed' && tab == null)) ||
      (record.containsKey('openingProvider') &&
          (!_key(openingProvider) || phase == 'unused' || (tab is Map && tab['provider'] != openingProvider)))) {
    throw const MomentsError('Invalid browser boundary tab');
  }
  if (sameProcess(supervisor.cast())) {
    throw const MomentsError('Browser supervisor is still alive; stop it before recovery');
  }
  return BrowserBoundary._(dir, record, recovered: true);
}
