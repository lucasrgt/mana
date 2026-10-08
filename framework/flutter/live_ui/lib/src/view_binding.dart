import 'dart:async';

import 'package:flutter/widgets.dart';

import 'moments.dart';
import 'timing.dart';

/// Saves explicitly selected view state and restores it after data/layout exist.
/// Domain/session data stay with their owners; this only binds UI state.
final class MomentViewBinding {
  MomentViewBinding({
    required this.route,
    required this.scroll,
    required this.read,
    required this.restore,
  }) {
    scroll.addListener(capture);
  }
  final String route;
  final ScrollController scroll;
  final Map<String, dynamic> Function() read;
  final FutureOr<void> Function(Map<String, dynamic>) restore;
  MomentController? _controller;
  String? _restoredRevision;
  bool _restoring = false;
  bool _disposed = false;
  bool _ready = false;

  void attach(BuildContext context, {required bool ready}) {
    _ready = ready;
    final next = MomentScope.of(context);
    if (next != _controller) {
      _controller?.removeFrameReader(this);
      _controller = next;
      _restoredRevision = null;
      next?.registerFrameReader(this, _readFrame);
    }
    final controller = _controller;
    final value = controller?.projection;
    if (!ready ||
        controller == null ||
        value == null ||
        value['route'] != route ||
        controller.revision == _restoredRevision) {
      return;
    }
    _restoredRevision = controller.revision;
    _restoring = true;
    final revision = controller.revision;
    MomentTiming.mark(MomentMark.restoreScheduled);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool active() =>
          !_disposed &&
          _controller == controller &&
          controller.revision == revision;
      if (!active()) return;
      try {
        MomentTiming.mark(MomentMark.restoreStarted);
        await MomentTiming.measure(
          MomentStage.restoreFields,
          () async => restore(value),
        );
        if (!active()) return;
        await MomentTiming.measure(MomentStage.restoreLayout, () async {
          final target = (value['scrollOffset'] as num).toDouble();
          var remainingFrames = 40;
          // Filters can animate their content into place. Wait for its scroll extent
          // instead of clamping against a transient empty/loading frame.
          do {
            WidgetsBinding.instance.scheduleFrame();
            await WidgetsBinding.instance.endOfFrame;
            if (!active()) return;
          } while ((target > 0 &&
                  (!scroll.hasClients ||
                      scroll.position.maxScrollExtent < target)) &&
              --remainingFrames > 0);
          if (scroll.hasClients) {
            scroll.jumpTo(target.clamp(0, scroll.position.maxScrollExtent));
          }
          WidgetsBinding.instance.scheduleFrame();
          await WidgetsBinding.instance.endOfFrame;
          if (!active()) return;
        });
        if (!active()) return;
        _restoring = false;
        await controller.observe(_projection());
      } on Object catch (error) {
        // A rejected projection must not be acknowledged or overwritten by
        // captures of partially restored UI. A newer revision can try again.
        if (active()) {
          _restoring = true;
          controller.lastError = 'Moment restore failed: $error';
        }
      }
    });
  }

  Map<String, dynamic>? _readFrame() {
    if (_disposed ||
        _restoring ||
        !_ready ||
        _controller?.projection?['route'] != route ||
        _controller?.revision != _restoredRevision) {
      return null;
    }
    return _projection();
  }

  Map<String, dynamic> _projection() => {
    'route': route,
    ...read(),
    'scrollOffset': scroll.hasClients ? scroll.offset.clamp(0, 10000000) : 0.0,
  };

  void capture() {
    if (_disposed ||
        _restoring ||
        _controller?.projection?['route'] != route ||
        _controller?.revision != _restoredRevision) {
      return;
    }
    try {
      _controller?.capture(_projection());
    } on Object catch (error) {
      _controller?.lastError = 'Draft not saved: $error';
    }
  }

  void dispose() {
    _disposed = true;
    _controller?.removeFrameReader(this);
    scroll.removeListener(capture);
  }
}
