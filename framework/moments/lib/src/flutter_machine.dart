import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errors.dart';
import 'watch.dart';

/// `flutter run --machine`: Flutter's documented IDE protocol, not simulated
/// terminal keystrokes.
final class FlutterMachine implements WatchedMachine {
  FlutterMachine(
    this._child, {
    void Function(String text)? log,
    this.timeout = const Duration(seconds: 60),
    void Function()? onStarted,
  }) : _log = log ?? print,
       _onStarted = onStarted ?? (() {}) {
    _lines = _child.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(_line);
    unawaited(_child.exitCode.then((_) => _rejectAll('Flutter process exited')));
  }

  final Process _child;
  final void Function(String text) _log;
  final void Function() _onStarted;
  final Duration timeout;
  late final StreamSubscription<String> _lines;
  String? _appId, _deviceId;
  var _started = false, _closed = false;
  var _nextId = 0;
  final _pending = <int, ({Completer<Object?> completer, Timer timer})>{};

  void _rejectAll(String message) {
    _closed = true;
    for (final request in _pending.values) {
      request.timer.cancel();
      if (!request.completer.isCompleted) request.completer.completeError(MomentsError(message));
    }
    _pending.clear();
  }

  void _line(String line) {
    List? messages;
    try {
      if (line.startsWith('[')) messages = jsonDecode(line) as List?;
    } on FormatException {
      messages = null;
    }
    if (messages == null) {
      if (line.trim().isNotEmpty) _log(line);
      return;
    }
    for (final raw in messages) {
      final message = raw as Map;
      final params = (message['params'] as Map?) ?? const {};
      final id = message['id'];
      if (id is int && _pending.containsKey(id)) {
        final request = _pending.remove(id)!;
        request.timer.cancel();
        final error = message['error'];
        if (error != null) {
          request.completer.completeError(MomentsError(error is Map ? '${error['message'] ?? error}' : '$error'));
        } else {
          request.completer.complete(message['result']);
        }
      } else if (message['event'] == 'app.start') {
        _appId = params['appId'] as String?;
        _deviceId = params['deviceId'] as String?;
      } else if (message['event'] == 'app.started' && params['appId'] == _appId) {
        _started = true;
        _onStarted();
      } else if (message['event'] == 'app.stop') {
        _started = false;
        _rejectAll('Flutter app stopped');
      } else if (message['event'] == 'daemon.logMessage' && const ['error', 'warning'].contains(params['level'])) {
        _log('${params['message']}');
      } else if (const ['app.log', 'daemon.log', 'daemon.showMessage'].contains(message['event'])) {
        _log('${params['log'] ?? params['message']}');
      }
    }
  }

  @override
  bool ready() => _started && !_closed;
  String? device() => _started && !_closed ? _deviceId : null;

  @override
  Future<Map<String, Object?>> restart({bool fullRestart = true}) async {
    if (!_started || _closed) throw const MomentsError('Flutter is not ready');
    final id = ++_nextId;
    final completer = Completer<Object?>();
    final timer = Timer(
      timeout,
      () => _rejectAll('Flutter restart timed out; stop and restart the launcher before retrying'),
    );
    _pending[id] = (completer: completer, timer: timer);
    try {
      _child.stdin.writeln(
        jsonEncode([
          {
            'id': id,
            'method': 'app.restart',
            'params': {'appId': _appId, 'fullRestart': fullRestart, 'pause': false, 'reason': 'moments-save'},
          },
        ]),
      );
    } on Object catch (error) {
      _rejectAll('$error');
    }
    final result = (await completer.future) as Map?;
    if (result?['code'] != 0) throw MomentsError('${result?['message'] ?? 'Flutter rejected the restart'}');
    return result!.cast();
  }

  void close() {
    _rejectAll('Flutter supervisor stopped');
    unawaited(_lines.cancel());
  }
}
