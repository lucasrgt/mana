import 'dart:async';
import 'dart:convert';

import 'configuration.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'moments.dart';
import 'action_trace.dart';

/// Debug-only pointer dispatch through Flutter's hit testing and gesture arena.
/// This exercises widget handlers, not OS input or a platform accessibility API.
final class MomentGestures {
  static int _pointer = 1000000;

  /// Explicit navigation through Flutter's scrollables, not an OS swipe. A
  /// target still mounting is waited for up to [patience]; lazy lists are not
  /// searched.
  Future<String> reveal(
    String key, {
    required bool Function() current,
    Duration patience = const Duration(seconds: 6),
  }) async {
    final deadline = DateTime.now().add(patience);
    while (true) {
      final outcome = await _revealOnce(key, current: current);
      if (outcome != 'not-found' ||
          !current() ||
          DateTime.now().isAfter(deadline)) {
        return outcome;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<String> _revealOnce(
    String key, {
    required bool Function() current,
  }) async {
    if (!momentsBuild) return 'unsupported';
    final targets = <Element>[];
    var visited = 0;
    void visit(Element element) {
      if (++visited > 20000) return;
      if (element.widget.key == ValueKey<String>(key)) targets.add(element);
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    if (visited > 20000) return 'unsupported';
    if (targets.isEmpty) return 'not-found';
    if (targets.length != 1) return 'ambiguous';
    if (!current()) return 'stale';
    await Scrollable.ensureVisible(targets.single, alignment: 0.5);
    return current() && targets.single.mounted
        ? 'dispatched'
        : 'dispatch-unknown';
  }

  /// Focus through pointer dispatch, then enter through Flutter's TextInputClient.
  /// No controller assignment or direct onChanged/onSubmitted invocation. This
  /// covers formatters and Flutter editing, not a system keyboard or an IME.
  /// A field still mounting (its screen loading) is waited for up to
  /// [patience], as [tap] does.
  Future<String> fill(
    String key,
    String text, {
    required bool Function() current,
    Duration patience = const Duration(seconds: 6),
  }) async {
    final deadline = DateTime.now().add(patience);
    while (true) {
      final outcome = await _fillOnce(key, text, current: current);
      if (outcome != 'not-found' ||
          !current() ||
          DateTime.now().isAfter(deadline)) {
        return outcome;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<String> _fillOnce(
    String key,
    String text, {
    required bool Function() current,
  }) async {
    if (!momentsBuild || text.isEmpty || text.length > 4096) return 'unsupported';
    final targets = <Element>[];
    var visited = 0;
    void visit(Element element) {
      if (++visited > 20000) return;
      if (element.widget.key == ValueKey<String>(key)) targets.add(element);
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    if (visited > 20000) return 'unsupported';
    if (targets.isEmpty) return 'not-found';
    if (targets.length != 1) return 'ambiguous';
    final editors = <EditableTextState>[];
    void editable(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        editors.add(element.state as EditableTextState);
      }
      element.visitChildren(editable);
    }

    editable(targets.single);
    if (editors.length != 1 || editors.single.widget.readOnly) {
      return 'unsupported';
    }
    final editor = editors.single;
    final focused = await tap(key, current: current);
    if (focused != 'dispatched') return focused;
    await Future<void>.delayed(Duration.zero);
    if (!current() || !editor.mounted) return 'dispatch-unknown';
    if (!editor.widget.focusNode.hasFocus) return 'unsupported';
    editor.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    return 'dispatched';
  }

  /// A target that is still loading, animating in, covered or disabled (a
  /// confirmation's countdown) is waited for, as a person would, up to
  /// [patience]; one scrolled out of view is first scrolled to. Only then does
  /// the tap report why it could not land.
  Future<String> tap(
    String key, {
    required bool Function() current,
    Duration patience = const Duration(seconds: 6),
  }) async {
    final deadline = DateTime.now().add(patience);
    var scrolled = false;
    while (true) {
      final outcome = await _tapOnce(key, current: current);
      if (!_notYet.contains(outcome) ||
          !current() ||
          DateTime.now().isAfter(deadline)) {
        return outcome;
      }
      if (outcome == 'not-visible' && !scrolled) {
        scrolled = await _revealOnce(key, current: current) == 'dispatched';
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  static const _notYet = {'not-found', 'not-visible', 'occluded', 'disabled'};

  static bool _disabled(Element target) {
    var disabled = false;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is Semantics && widget.properties.enabled == false) {
        disabled = true;
      }
      if (!disabled) element.visitChildren(visit);
    }

    visit(target);
    return disabled;
  }

  Future<String> _tapOnce(String key, {required bool Function() current}) async {
    if (!momentsBuild) return 'unsupported';
    final matches = <Element>[];
    var visited = 0;
    void visit(Element e) {
      if (++visited > 20000) return;
      if (e.widget.key == ValueKey<String>(key)) matches.add(e);
      e.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    if (visited > 20000) return 'unsupported';
    if (matches.isEmpty) return 'not-found';
    if (matches.length != 1) return 'ambiguous';
    final element = matches.single;
    final render = element.findRenderObject();
    if (render is! RenderBox ||
        !render.attached ||
        !render.hasSize ||
        render.size.isEmpty) {
      return 'not-visible';
    }
    final center = render.localToGlobal(render.size.center(Offset.zero));
    if (!center.dx.isFinite || !center.dy.isFinite) return 'not-visible';
    RenderObject? child = render;
    while (child != null) {
      if ((child is RenderOffstage && child.offstage) ||
          (child is RenderOpacity && child.opacity == 0) ||
          (child is RenderAnimatedOpacity && child.opacity.value == 0) ||
          (child is RenderSliverOffstage && child.offstage) ||
          (child is RenderSliverOpacity && child.opacity == 0)) {
        return 'not-visible';
      }
      if (child is RenderView && !(Offset.zero & child.size).contains(center)) {
        return 'not-visible';
      }
      final parent = child.parent;
      final clip = parent?.describeApproximatePaintClip(child);
      if (clip != null &&
          !MatrixUtils.transformRect(
            parent!.getTransformTo(null),
            clip,
          ).contains(center)) {
        return 'not-visible';
      }
      child = parent;
    }
    final viewId = View.of(element).viewId;
    final hit = HitTestResult();
    GestureBinding.instance.hitTestInView(hit, center, viewId);
    final hitsTarget = hit.path.any((entry) {
      final target = entry.target;
      if (target is! RenderObject) return false;
      RenderObject? node = target;
      while (node != null) {
        if (identical(node, render)) return true;
        node = node.parent;
      }
      return false;
    });
    if (!hitsTarget) return 'occluded';
    if (_disabled(element)) return 'disabled';
    if (!current()) return 'stale';
    final pointer = ++_pointer;
    final time = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
    final binding = GestureBinding.instance;
    // No lookup or direct call of onTap/onPressed: the gesture arena decides.
    var down = false;
    var ended = false;
    try {
      binding.handlePointerEvent(
        PointerAddedEvent(pointer: pointer, position: center, viewId: viewId),
      );
      down = true;
      binding.handlePointerEvent(
        PointerDownEvent(
          pointer: pointer,
          position: center,
          viewId: viewId,
          timeStamp: time,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 16));
      if (!current()) {
        return 'dispatch-unknown'; // A pointer-down handler may already have written.
      }
      binding.handlePointerEvent(
        PointerUpEvent(
          pointer: pointer,
          position: center,
          viewId: viewId,
          timeStamp: time + const Duration(milliseconds: 16),
        ),
      );
      ended = true;
      return 'dispatched';
    } finally {
      if (down && !ended) {
        binding.handlePointerEvent(
          PointerCancelEvent(
            pointer: pointer,
            position: center,
            viewId: viewId,
          ),
        );
      }
      binding.handlePointerEvent(
        PointerRemovedEvent(pointer: pointer, position: center, viewId: viewId),
      );
    }
  }
}

final class MomentGestureReporter {
  MomentGestureReporter(this.moment);
  final MomentController moment;
  final _client = http.Client();
  final _gestures = MomentGestures();
  final _seen = <String>{};
  bool _disposed = false;

  Future<void> connect(Uri endpoint, String token) async {
    if (!momentsBuild ||
        endpoint.scheme != 'http' ||
        !['127.0.0.1', 'localhost', '::1'].contains(endpoint.host)) {
      return;
    }
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    while (!_disposed) {
      try {
        if (moment.revision.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          continue;
        }
        final response = await _client.get(
          endpoint
              .resolve('/journey/next')
              .replace(queryParameters: {'client': moment.clientId}),
          headers: headers,
        );
        if (_disposed || response.statusCode == 409) return;
        if (response.statusCode == 204) continue;
        if (response.statusCode != 200) {
          throw StateError('Gesture channel unavailable');
        }
        final request = jsonDecode(response.body) as Map;
        final id = request['id'] as String;
        final timing = Stopwatch()..start();
        var frameMs = 0.0;
        var executeMs = 0.0;
        String outcome = 'dispatch-unknown';
        if (_seen.length < 2048 && _seen.add(id)) {
          bool current() =>
              !_disposed &&
              request['revision'] == moment.revision &&
              DateTime.now().millisecondsSinceEpoch <
                  (request['expiresAt'] as int);
          WidgetsBinding.instance.scheduleFrame();
          await WidgetsBinding.instance.endOfFrame;
          frameMs = timing.elapsedMicroseconds / 1000;
          try {
            outcome = await MomentActionTrace.run(
              id,
              (receipt) async {
                final response = await _client.post(
                  endpoint.resolve('/journey/actions'),
                  headers: headers,
                  body: jsonEncode({
                    'id': id,
                    'client': moment.clientId,
                    'revision': request['revision'],
                    'receipt': receipt,
                  }),
                );
                if (response.statusCode != 200) {
                  throw StateError('Action evidence unavailable');
                }
              },
              () async {
                if (!current()) {
                  outcome = 'stale';
                } else if (request['kind'] == 'fill') {
                  outcome = await _gestures.fill(
                    request['target'] as String,
                    request['text'] as String,
                    current: current,
                  );
                  request.remove('text');
                } else if (request['kind'] == 'reveal') {
                  outcome = await _gestures.reveal(
                    request['target'] as String,
                    current: current,
                  );
                } else {
                  outcome = await _gestures.tap(
                    request['target'] as String,
                    current: current,
                  );
                }
                return outcome;
              },
            );
          } on Object {
            outcome = 'dispatch-unknown';
          } finally {
            request.remove('text');
            executeMs = timing.elapsedMicroseconds / 1000 - frameMs;
          }
        }
        if (_disposed) return;
        await _client.post(
          endpoint.resolve('/journey/result'),
          headers: headers,
          body: jsonEncode({
            'id': id,
            'revision': request['revision'],
            'client': moment.clientId,
            'outcome': outcome,
            'timing': {
              'clock': 'dart-monotonic',
              'frameMs': frameMs,
              'executeMs': executeMs,
              'totalMs': timing.elapsedMicroseconds / 1000,
            },
          }),
        );
      } on Object {
        if (_disposed) return;
        // Retry transport polling only. A delivered gesture is never replayed.
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  void dispose() {
    _disposed = true;
    _client.close();
  }
}
