import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'memory.dart';

const _candidates = [
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
];

final class _Call {
  _Call(this.method);
  final String method;
  final completer = Completer<Map<String, Object?>>();
}

/// One page (tab) attached through the DevTools protocol.
final class ChromiumPage {
  ChromiumPage._(this._browser, this.sessionId, this._targetId, this._listener);
  final Chromium _browser;
  final String sessionId;
  final String _targetId;
  final void Function(Map<String, Object?> message) _listener;
  final _loads = <Completer<void>>{};
  var _closed = false;

  Future<void> navigate(String url) => _browser._send('Page.navigate', {'url': url}, sessionId);

  Future<void> load(String url, {Duration timeout = const Duration(seconds: 15)}) async {
    final loaded = Completer<void>();
    _loads.add(loaded);
    try {
      await _browser._send('Page.navigate', {'url': url}, sessionId);
      await loaded.future.timeout(timeout, onTimeout: () => throw MomentsError('Page did not load: $url'));
    } finally {
      _loads.remove(loaded);
    }
  }

  Future<Object?> evaluate(String expression) async {
    final result = await _browser._send('Runtime.evaluate', {
      'expression': expression,
      'returnByValue': true,
      'awaitPromise': true,
    }, sessionId);
    final details = result['exceptionDetails'] as Map?;
    if (details != null) throw MomentsError('${(details['exception'] as Map?)?['description'] ?? details['text']}');
    return (result['result'] as Map?)?['value'];
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _browser._listeners.remove(_listener);
    await _browser._send('Target.closeTarget', {'targetId': _targetId}).catchError((_) => <String, Object?>{});
  }
}

/// A browser context: its own cookies, storage, HTTP and code cache.
final class ChromiumContext {
  ChromiumContext._(this._browser, this._id);
  final Chromium _browser;
  final String _id;

  Future<ChromiumPage> page({void Function(String text)? onError, bool? debug}) =>
      _browser._page(_id, onError: onError ?? (_) {}, debug: debug ?? Platform.environment['MOMENTS_DEBUG'] != null);

  /// Clears the site's data, keeping the HTTP cache (compiled JavaScript) on
  /// purpose, and proves nothing survived.
  Future<void> wipe(String origin) async {
    await _browser._send('Storage.clearCookies', {'browserContextId': _id});
    final probe = await page();
    try {
      await probe.load('$origin/version.json');
      try {
        await _browser._send('Storage.clearDataForOrigin', {'origin': origin, 'storageTypes': 'all'}, probe.sessionId);
      } on MomentsError {
        await _browser._send('Storage.clearDataForOrigin', {'origin': origin, 'storageTypes': 'all'});
      }
      final left =
          await probe.evaluate(
                '(async()=>({local:localStorage.length,session:sessionStorage.length,cookies:document.cookie,'
                'databases:(await indexedDB.databases()).length,caches:(await caches.keys()).length,'
                'workers:(await navigator.serviceWorker?.getRegistrations?.()??[]).length}))()',
              )
              as Map?;
      final survived =
          left != null &&
          ((left['local'] as num? ?? 0) > 0 ||
              (left['session'] as num? ?? 0) > 0 ||
              (left['cookies'] as String? ?? '').isNotEmpty ||
              (left['databases'] as num? ?? 0) > 0 ||
              (left['caches'] as num? ?? 0) > 0 ||
              (left['workers'] as num? ?? 0) > 0);
      if (survived) throw MomentsError('Isolation check failed: site data survived the wipe ${jsonEncode(left)}');
    } finally {
      await probe.close();
    }
  }

  Future<void> close() =>
      _browser._send('Target.disposeBrowserContext', {'browserContextId': _id}).then((_) {}, onError: (_) {});
}

/// One headless browser owned by this process. A worker keeps one browser
/// context and opens a new tab per execution after wiping the site's data, so
/// compiled JavaScript is reused while no application state crosses
/// executions. The profile is private to the run; nothing is shared with the
/// user's browser.
final class Chromium {
  Chromium._(this._child, this._socket);

  final Process _child;
  final WebSocket _socket;
  var _next = 0;
  final _pending = <int, _Call>{};
  final _listeners = <void Function(Map<String, Object?> message)>{};

  int get pid => _child.pid;

  static Future<Chromium> launch({
    required String directory,
    String? executable,
    int width = 1280,
    int height = 800,
    void Function(String text)? log,
  }) async {
    final binary =
        executable ??
        Platform.environment['MOMENTS_CHROMIUM'] ??
        _candidates.where((c) => File(c).existsSync()).firstOrNull;
    if (binary == null) throw const MomentsError('Chromium not found; set MOMENTS_CHROMIUM');
    final profile = p.join(directory, 'chromium');
    Directory(profile).createSync(recursive: true);
    Process.runSync('chmod', ['700', profile]);
    final child = await Process.start(
      binary,
      [
        '--headless=new',
        '--remote-debugging-port=0',
        '--user-data-dir=$profile',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-extensions',
        '--disable-background-networking',
        '--disable-component-update',
        '--enable-unsafe-swiftshader',
        '--use-angle=swiftshader',
        '--window-size=$width,$height',
        'about:blank',
      ],
      environment: {'TMPDIR': Platform.environment['TMPDIR'] ?? directory},
    );
    unawaited(child.stdout.drain<void>());
    child.stderr.transform(utf8.decoder).listen((chunk) => log?.call(chunk));
    var exited = false;
    unawaited(child.exitCode.then((_) => exited = true));
    final portFile = File(p.join(profile, 'DevToolsActivePort'));
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (!portFile.existsSync() || portFile.readAsStringSync().split('\n').length < 2) {
      if (exited) throw const MomentsError('Chromium exited during startup');
      if (DateTime.now().isAfter(deadline)) {
        child.kill(ProcessSignal.sigkill);
        throw const MomentsError('Chromium did not open its DevTools endpoint');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final [port, path, ...] = portFile.readAsStringSync().trim().split('\n');
    final WebSocket socket;
    try {
      socket = await WebSocket.connect('ws://127.0.0.1:$port$path');
    } on Object {
      throw const MomentsError('DevTools connection failed');
    }
    final browser = Chromium._(child, socket);
    socket.listen(browser._message, onDone: browser._closedSocket, onError: (_) => browser._closedSocket());
    return browser;
  }

  void _message(Object? data) {
    final message = (jsonDecode(data! as String) as Map).cast<String, Object?>();
    final id = message['id'];
    if (id is int) {
      final call = _pending.remove(id);
      if (call == null) return;
      final error = message['error'] as Map?;
      if (error != null) {
        call.completer.completeError(MomentsError('${call.method}: ${error['message']}'));
      } else {
        call.completer.complete(((message['result'] as Map?) ?? const {}).cast());
      }
    } else {
      for (final listener in [..._listeners]) {
        listener(message);
      }
    }
  }

  void _closedSocket() {
    for (final call in _pending.values) {
      if (!call.completer.isCompleted) call.completer.completeError(const MomentsError('DevTools connection closed'));
    }
    _pending.clear();
  }

  Future<Map<String, Object?>> _send(String method, [Map<String, Object?> params = const {}, String? sessionId]) {
    final id = ++_next;
    final call = _Call(method);
    _pending[id] = call;
    _socket.add(jsonEncode({'id': id, 'method': method, 'params': params, 'sessionId': ?sessionId}));
    return call.completer.future;
  }

  Future<ChromiumPage> _page(
    String contextId, {
    required void Function(String text) onError,
    required bool debug,
  }) async {
    final targetId =
        (await _send('Target.createTarget', {'url': 'about:blank', 'browserContextId': contextId}))['targetId']!
            as String;
    final sessionId =
        (await _send('Target.attachToTarget', {'targetId': targetId, 'flatten': true}))['sessionId']! as String;
    late final ChromiumPage page;
    void listener(Map<String, Object?> message) {
      if (message['sessionId'] != sessionId) return;
      final params = (message['params'] as Map?) ?? const {};
      switch (message['method']) {
        case 'Page.loadEventFired':
          for (final load in [...page._loads]) {
            if (!load.isCompleted) load.complete();
          }
        case 'Runtime.exceptionThrown':
          final details = params['exceptionDetails'] as Map?;
          onError('${(details?['exception'] as Map?)?['description'] ?? details?['text'] ?? 'exception'}');
        case 'Runtime.consoleAPICalled' when debug && const ['error', 'warning'].contains(params['type']):
          final text = [
            for (final a in (params['args'] as List? ?? const []).cast<Map>()) a['value'] ?? a['description'] ?? '',
          ].join(' ');
          onError('console.${params['type']}: ${text.length > 500 ? text.substring(0, 500) : text}');
        case 'Network.loadingFailed' when debug:
          onError(
            'network failed: ${params['errorText']} ${params['blockedReason'] ?? (params['corsErrorStatus'] as Map?)?['corsError'] ?? ''}',
          );
        case 'Network.responseReceived' when debug && (((params['response'] as Map?)?['status'] as num?) ?? 0) >= 400:
          final response = params['response'] as Map;
          onError('http ${response['status']} ${response['url']}');
      }
    }

    page = ChromiumPage._(this, sessionId, targetId, listener);
    _listeners.add(listener);
    await _send('Runtime.enable', const {}, sessionId);
    await _send('Page.enable', const {}, sessionId);
    if (debug) await _send('Network.enable', const {}, sessionId);
    return page;
  }

  Future<ChromiumContext> context() async {
    final id = (await _send('Target.createBrowserContext', {'disposeOnDetach': true}))['browserContextId']! as String;
    return ChromiumContext._(this, id);
  }

  /// Proportional set size of the browser and every process it spawned.
  int memory() => treeMemory(_child.pid);

  Future<void> close() async {
    try {
      await _send('Browser.close').timeout(const Duration(seconds: 5));
    } on Object {
      // Already closing.
    }
    await _socket.close();
    await _child.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _child.kill(ProcessSignal.sigkill);
        return _child.exitCode;
      },
    );
  }
}
