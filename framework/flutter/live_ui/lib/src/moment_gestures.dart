import 'dart:async';
import 'dart:convert';

import 'configuration.dart';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'moments.dart';
import 'action_trace.dart';

/// Debug-only pointer dispatch through Flutter's hit testing and gesture arena.
/// This exercises widget handlers, not OS input or a platform accessibility API.
final class MomentGestures {
  static int _pointer = 1000000;

  /// Explicit navigation through Flutter's scrollables, not an OS swipe. A
  /// target still mounting is waited for up to [patience]; one a lazy list
  /// has not built yet is searched for by paging through the mounted
  /// scrollables (see [mountLazy]).
  Future<String> reveal(
    String key, {
    required bool Function() current,
    Duration patience = const Duration(seconds: 6),
  }) async {
    final deadline = DateTime.now().add(patience);
    var searched = false;
    while (true) {
      final outcome = await _revealOnce(key, current: current);
      if (outcome != 'not-found' ||
          !current() ||
          DateTime.now().isAfter(deadline)) {
        return outcome;
      }
      if (!searched) {
        searched = true;
        if (await mountLazy(key, current: current)) continue;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  /// Builds and lays out what a scroll changed, so a lazy list mounts the
  /// children now in view: at once between frames, or by the next frame.
  static Future<void> _layOut() async {
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.idle &&
        binding.rootElement != null) {
      binding.buildOwner!.buildScope(binding.rootElement!);
      binding.rootPipelineOwner.flushLayout();
      binding.scheduleFrame();
      return;
    }
    binding.scheduleFrame();
    await binding.endOfFrame;
  }

  static List<Element> _find(String key) {
    final matches = <Element>[];
    var visited = 0;
    void visit(Element element) {
      if (++visited > 20000) return;
      if (element.widget.key == ValueKey<String>(key)) matches.add(element);
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return matches;
  }

  /// A target a lazy list (a `ListView.builder`, a select menu) has not built
  /// yet: pages through each mounted scrollable, the latest mounted (a popup
  /// over the screen) first, until the target mounts, then leaves it there.
  /// A scrollable where it never appears goes back to where it was. Paging
  /// can trigger a list's own loading, as a person scrolling would; at most
  /// [pages] pages are turned in all.
  Future<bool> mountLazy(
    String key, {
    required bool Function() current,
    int pages = 200,
  }) async {
    if (!momentsBuild) return false;
    final scrollables = <ScrollableState>[];
    var visited = 0;
    void visit(Element element) {
      if (++visited > 20000) return;
      if (element is StatefulElement && element.state is ScrollableState) {
        scrollables.add(element.state as ScrollableState);
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    var turned = 0;
    for (final scrollable in scrollables.reversed) {
      if (!scrollable.mounted) continue;
      final position = scrollable.position;
      if (!position.hasContentDimensions || !position.hasViewportDimension) {
        continue;
      }
      final start = position.pixels;
      var offset = position.minScrollExtent;
      while (turned < pages && current() && scrollable.mounted) {
        position.jumpTo(
          offset.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
        turned++;
        await _layOut();
        if (_find(key).isNotEmpty) return true;
        if (offset >= position.maxScrollExtent) break;
        offset += position.viewportDimension * 0.8;
      }
      if (scrollable.mounted) position.jumpTo(start);
    }
    return false;
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
    await _layOut();
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
    final lazyAfter = DateTime.now().add(const Duration(milliseconds: 300));
    var searched = false;
    while (true) {
      final outcome = await _fillOnce(key, text, current: current);
      if (outcome != 'not-found' ||
          !current() ||
          DateTime.now().isAfter(deadline)) {
        return outcome;
      }
      if (!searched && DateTime.now().isAfter(lazyAfter)) {
        searched = true;
        if (await mountLazy(key, current: current)) continue;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Future<String> _fillOnce(
    String key,
    String text, {
    required bool Function() current,
  }) async {
    if (!momentsBuild || text.isEmpty || text.length > 4096) {
      return 'unsupported';
    }
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
    bool probeOnly = false,
  }) async {
    final deadline = DateTime.now().add(patience);
    final lazyAfter = DateTime.now().add(const Duration(milliseconds: 300));
    var scrolled = false;
    var searched = false;
    while (true) {
      final outcome = await _tapOnce(
        key,
        current: current,
        probeOnly: probeOnly,
      );
      if (!_notYet.contains(outcome) ||
          !current() ||
          DateTime.now().isAfter(deadline)) {
        return outcome;
      }
      if (outcome == 'not-visible' && !scrolled) {
        scrolled = await _revealOnce(key, current: current) == 'dispatched';
      }
      if (outcome == 'not-found' &&
          !searched &&
          DateTime.now().isAfter(lazyAfter)) {
        searched = true;
        if (await mountLazy(key, current: current)) {
          await _revealOnce(key, current: current);
          continue;
        }
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

  /// [probeOnly] answers whether a tap would land (`dispatched`) without
  /// sending one, for gestures that press the same place their own way.
  Future<String> _tapOnce(
    String key, {
    required bool Function() current,
    bool probeOnly = false,
  }) async {
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
    if (probeOnly) return 'dispatched';
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

  /// The platform's back: the `popRoute` message the system button sends on
  /// `flutter/navigation`, so the app's back handling (a dialog, a sheet, a
  /// pushed page, a router's back dispatcher) answers it as it would the
  /// button. Nothing is targeted.
  Future<String> back({required bool Function() current}) async {
    if (!momentsBuild) return 'unsupported';
    if (!current()) return 'stale';
    final answered = Completer<void>();
    // ignore: deprecated_member_use
    await ServicesBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      SystemChannels.navigation.codec.encodeMethodCall(
        const MethodCall('popRoute'),
      ),
      (_) => answered.complete(),
    );
    await answered.future.timeout(const Duration(seconds: 2), onTimeout: () {});
    return 'dispatched';
  }

  /// Drags the target's centre across 60% of its size towards [direction]
  /// (`left`, `right`, `up`, `down`) in pointer moves over ~160 ms, so a
  /// page view, a dismissible or a list scrolls as under a finger. The
  /// target is found, revealed and waited for as [tap] does.
  Future<String> swipe(
    String key,
    String direction, {
    required bool Function() current,
    Duration patience = const Duration(seconds: 6),
  }) async {
    final unit = switch (direction) {
      'left' => const Offset(-1, 0),
      'right' => const Offset(1, 0),
      'up' => const Offset(0, -1),
      'down' => const Offset(0, 1),
      _ => null,
    };
    if (unit == null) return 'unsupported';
    return _press(key, current: current, patience: patience, (
      binding,
      pointer,
      center,
      size,
      viewId,
      time,
    ) async {
      final distance = Offset(
        unit.dx * size.width * 0.6,
        unit.dy * size.height * 0.6,
      );
      const moves = 10;
      for (var step = 1; step <= moves; step++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        if (!current()) return false;
        binding.handlePointerEvent(
          PointerMoveEvent(
            pointer: pointer,
            position: center + distance * (step / moves),
            delta: distance / moves.toDouble(),
            viewId: viewId,
            timeStamp: time + Duration(milliseconds: 16 * step),
          ),
        );
      }
      binding.handlePointerEvent(
        PointerUpEvent(
          pointer: pointer,
          position: center + distance,
          viewId: viewId,
          timeStamp: time + const Duration(milliseconds: 16 * (moves + 1)),
        ),
      );
      return true;
    });
  }

  /// Holds the target's centre past the long-press timeout, then lifts.
  Future<String> longPress(
    String key, {
    required bool Function() current,
    Duration patience = const Duration(seconds: 6),
  }) => _press(key, current: current, patience: patience, (
    binding,
    pointer,
    center,
    size,
    viewId,
    time,
  ) async {
    const hold = Duration(milliseconds: 600);
    await Future<void>.delayed(hold);
    if (!current()) return false;
    binding.handlePointerEvent(
      PointerUpEvent(
        pointer: pointer,
        position: center,
        viewId: viewId,
        timeStamp: time + hold,
      ),
    );
    return true;
  });

  /// The keyboard's action key on a text field (done, next, search, send),
  /// through `EditableTextState.performAction` with the field's own
  /// `textInputAction`, after focusing it with a tap; so `onSubmitted` and
  /// focus traversal run as from the keyboard.
  Future<String> submit(
    String key, {
    required bool Function() current,
    Duration patience = const Duration(seconds: 6),
  }) async {
    if (!momentsBuild) return 'unsupported';
    final focused = await tap(key, current: current, patience: patience);
    if (focused != 'dispatched') return focused;
    final targets = _find(key);
    if (targets.length != 1) return 'dispatch-unknown';
    final editors = <EditableTextState>[];
    void editable(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        editors.add(element.state as EditableTextState);
      }
      element.visitChildren(editable);
    }

    editable(targets.single);
    if (editors.length != 1) return 'unsupported';
    await Future<void>.delayed(Duration.zero);
    if (!current() || !editors.single.mounted) return 'dispatch-unknown';
    final editor = editors.single;
    editor.performAction(
      editor.widget.textInputAction ??
          (editor.widget.maxLines == 1
              ? TextInputAction.done
              : TextInputAction.newline),
    );
    return 'dispatched';
  }

  /// A pointer that goes down on the target's centre once [tap] would land
  /// there, and whatever [gesture] does before it lifts (the gesture ends it
  /// with its own up event, or returns false to cancel).
  Future<String> _press(
    String key,
    Future<bool> Function(
      GestureBinding binding,
      int pointer,
      Offset center,
      Size size,
      int viewId,
      Duration time,
    )
    gesture, {
    required bool Function() current,
    required Duration patience,
  }) async {
    if (!momentsBuild) return 'unsupported';
    final ready = await tap(
      key,
      current: current,
      patience: patience,
      probeOnly: true,
    );
    if (ready != 'dispatched') return ready;
    final targets = _find(key);
    if (targets.length != 1) return 'dispatch-unknown';
    final render = targets.single.findRenderObject()! as RenderBox;
    final center = render.localToGlobal(render.size.center(Offset.zero));
    final viewId = View.of(targets.single).viewId;
    final pointer = ++_pointer;
    final time = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
    final binding = GestureBinding.instance;
    var ended = false;
    try {
      binding.handlePointerEvent(
        PointerAddedEvent(pointer: pointer, position: center, viewId: viewId),
      );
      binding.handlePointerEvent(
        PointerDownEvent(
          pointer: pointer,
          position: center,
          viewId: viewId,
          timeStamp: time,
        ),
      );
      ended = await gesture(
        binding,
        pointer,
        center,
        render.size,
        viewId,
        time,
      );
      return ended ? 'dispatched' : 'dispatch-unknown';
    } finally {
      if (!ended) {
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
                } else if (request['kind'] == 'back') {
                  outcome = await _gestures.back(current: current);
                } else if (request['kind'] == 'swipe') {
                  outcome = await _gestures.swipe(
                    request['target'] as String,
                    request['direction'] as String,
                    current: current,
                  );
                } else if (request['kind'] == 'long_press') {
                  outcome = await _gestures.longPress(
                    request['target'] as String,
                    current: current,
                  );
                } else if (request['kind'] == 'submit') {
                  outcome = await _gestures.submit(
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
