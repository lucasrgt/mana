import 'dart:async';

import 'package:flutter/foundation.dart';

import 'configuration.dart';
import 'package:flutter/scheduler.dart';

/// Stops the old web runtime sending frames while its engine view is torn down.
/// Debug-only, bounded and reversible; it never filters Flutter errors.
final class RestartFrames {
  String? _id;
  FrameCallback? _begin;
  VoidCallback? _draw;
  Timer? _lease;
  final _dispatcher = PlatformDispatcher.instance;

  static void _holdBegin(Duration _) {}
  static void _holdDraw() {}

  void pause(String id, Duration lease) {
    if (!momentsBuild) return;
    if (_id == id) return;
    if (_id != null) throw StateError('Another restart is being prepared');
    _id = id;
    _begin = _dispatcher.onBeginFrame;
    _draw = _dispatcher.onDrawFrame;
    // Null callbacks are reinstalled by SchedulerBinding on the next request.
    // Keep explicit no-ops until teardown, failure, or lease expiry.
    _dispatcher.onBeginFrame = _holdBegin;
    _dispatcher.onDrawFrame = _holdDraw;
    _lease = Timer(lease, () => resume(id));
  }

  void resume(String id) {
    if (_id != id) return;
    _lease?.cancel();
    _id = null;
    // Do not overwrite callbacks installed by another owner in the meantime.
    if (_dispatcher.onBeginFrame == _holdBegin) {
      _dispatcher.onBeginFrame = _begin;
    }
    if (_dispatcher.onDrawFrame == _holdDraw) {
      _dispatcher.onDrawFrame = _draw;
    }
    _begin = null;
    _draw = null;
    // A scheduled frame may have been consumed while callbacks were paused.
    SchedulerBinding.instance.scheduleForcedFrame();
  }

  void dispose() {
    if (_id case final id?) resume(id);
  }
}
