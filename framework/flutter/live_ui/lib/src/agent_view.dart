import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:ui' show SemanticsAction, Tristate, CheckedState;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'moments.dart';

const _actions = {
  'tap': SemanticsAction.tap,
  'longPress': SemanticsAction.longPress,
  'setText': SemanticsAction.setText,
  'focus': SemanticsAction.focus,
  'scrollUp': SemanticsAction.scrollUp,
  'scrollDown': SemanticsAction.scrollDown,
  'scrollLeft': SemanticsAction.scrollLeft,
  'scrollRight': SemanticsAction.scrollRight,
  'increase': SemanticsAction.increase,
  'decrease': SemanticsAction.decrease,
  'dismiss': SemanticsAction.dismiss,
};

/// The agent's view of the screen, served to the Moments bridge in debug
/// builds: Flutter's semantics tree (what a screen reader is told) and its
/// actions. Semantics stay enabled once an agent has looked, so later looks
/// read the live tree instead of waiting for a rebuild.
final class AgentViewReporter {
  AgentViewReporter(this.moment, {http.Client? client})
    : _client = client ?? http.Client();
  final MomentController moment;
  final http.Client _client;
  SemanticsHandle? _semantics;
  bool _disposed = false;

  Future<void> connect(Uri endpoint, String token) async {
    if (!kDebugMode ||
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
              .resolve('/agent/next')
              .replace(queryParameters: {'client': moment.clientId}),
          headers: headers,
        );
        if (_disposed) return;
        if (response.statusCode == 409) {
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        if (response.statusCode == 204) continue;
        if (response.statusCode != 200) {
          throw StateError('Agent transport unavailable');
        }
        final request = (jsonDecode(response.body) as Map)
            .cast<String, Object?>();
        Map<String, Object?> report;
        try {
          report = request['op'] == 'act'
              ? await _act(request)
              : request['op'] == 'picture'
              ? await _picture()
              : await _look();
        } on Object catch (error) {
          report = {
            'error': error is StateError
                ? error.message
                : 'Flutter could not answer the agent',
          };
        }
        await _client.post(
          endpoint.resolve('/agent/result'),
          headers: headers,
          body: jsonEncode({
            'id': request['id'],
            'client': moment.clientId,
            'report': report,
          }),
        );
      } on Object {
        if (_disposed) return;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  SemanticsOwner? get _owner {
    for (final view in RendererBinding.instance.renderViews) {
      final owner = view.owner?.semanticsOwner;
      if (owner?.rootSemanticsNode != null) return owner;
    }
    return RendererBinding.instance.rootPipelineOwner.semanticsOwner;
  }

  Future<SemanticsNode> _root() async {
    _semantics ??= SemanticsBinding.instance.ensureSemantics();
    for (var i = 0; i < 20; i++) {
      final root = _owner?.rootSemanticsNode;
      if (root != null) return root;
      SchedulerBinding.instance.scheduleFrame();
      await SchedulerBinding.instance.endOfFrame;
    }
    throw StateError('The semantics tree is not ready');
  }

  Future<Map<String, Object?>> _look() async {
    final root = await _root();
    await SchedulerBinding.instance.endOfFrame;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final logical = view.physicalSize / view.devicePixelRatio;
    final rootRect = _global(root);
    final scale = logical.width > 0 && rootRect.width > 0
        ? rootRect.width / logical.width
        : 1.0;
    final nodes = <Map<String, Object?>>[];
    void visit(SemanticsNode node) {
      if (nodes.length >= 800) return;
      final data = node.getSemanticsData();
      final flags = data.flagsCollection;
      if (flags.isHidden) return;
      final actions = [
        for (final e in _actions.entries)
          if (data.hasAction(e.value)) e.key,
      ];
      final role = flags.isTextField
          ? 'field'
          : flags.isButton
          ? 'button'
          : flags.isLink
          ? 'link'
          : flags.isHeader
          ? 'heading'
          : flags.isSlider
          ? 'slider'
          : flags.isChecked != CheckedState.none
          ? 'checkbox'
          : flags.isToggled != Tristate.none
          ? 'switch'
          : flags.isImage
          ? 'image'
          : 'text';
      final named =
          data.label.isNotEmpty ||
          data.value.isNotEmpty ||
          data.hint.isNotEmpty ||
          data.identifier.isNotEmpty;
      if (named || actions.isNotEmpty) {
        final r = _global(node);
        nodes.add({
          'id': node.id,
          'role': role,
          if (data.label.isNotEmpty) 'label': _cut(data.label),
          if (data.value.isNotEmpty)
            'value': _cut(
              flags.isObscured ? '•' * data.value.length : data.value,
            ),
          if (data.hint.isNotEmpty) 'hint': _cut(data.hint),
          if (data.identifier.isNotEmpty) 'identifier': _cut(data.identifier),
          if (actions.isNotEmpty) 'actions': actions,
          if (flags.isChecked != CheckedState.none)
            'checked': flags.isChecked == CheckedState.isTrue,
          if (flags.isToggled != Tristate.none)
            'on': flags.isToggled == Tristate.isTrue,
          if (flags.isEnabled == Tristate.isFalse) 'disabled': true,
          if (flags.isFocused == Tristate.isTrue) 'focused': true,
          'rect': [
            for (final v in [r.left, r.top, r.width, r.height])
              double.parse((v / scale).toStringAsFixed(1)),
          ],
        });
      }
      node.visitChildren((child) {
        visit(child);
        return nodes.length < 800;
      });
    }

    visit(root);
    return {
      'nodes': nodes,
      'truncated': nodes.length >= 800,
      'viewport': [logical.width, logical.height],
    };
  }

  Future<Map<String, Object?>> _picture() async {
    await SchedulerBinding.instance.endOfFrame;
    final view = RendererBinding.instance.renderViews.firstOrNull;
    final layer = view?.debugLayer;
    if (view == null || layer is! OffsetLayer) {
      throw StateError('Nothing is painted yet');
    }
    final image = await layer.toImage(Offset.zero & view.size);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('The frame could not be encoded');
      return {
        'png': base64Encode(bytes.buffer.asUint8List()),
        'size': [image.width, image.height],
      };
    } finally {
      image.dispose();
    }
  }

  Future<Map<String, Object?>> _act(Map<String, Object?> request) async {
    await _root();
    final action = _actions[request['action']];
    final id = request['node'];
    if (action == null || id is! int) throw StateError('Unknown agent action');
    final owner = _owner;
    SemanticsNode? found;
    void find(SemanticsNode node) {
      if (node.id == id) found = node;
      if (found == null) {
        node.visitChildren((child) {
          find(child);
          return found == null;
        });
      }
    }

    final root = owner?.rootSemanticsNode;
    if (root != null) find(root);
    final node = found;
    if (node == null) {
      throw StateError('That element is no longer on the screen; look again');
    }
    if (!node.getSemanticsData().hasAction(action)) {
      throw StateError('That element does not accept ${request['action']}');
    }
    owner!.performAction(
      id,
      action,
      action == SemanticsAction.setText
          ? request['text'] as String? ?? ''
          : null,
    );
    await SchedulerBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return {'done': true};
  }

  Rect _global(SemanticsNode node) {
    var rect = node.rect;
    SemanticsNode? n = node;
    while (n != null) {
      final t = n.transform;
      if (t != null) rect = MatrixUtils.transformRect(t, rect);
      n = n.parent;
    }
    return rect;
  }

  String _cut(String s) => s.length > 300 ? '${s.substring(0, 300)}…' : s;

  void dispose() {
    _disposed = true;
    _semantics?.dispose();
    _client.close();
  }
}
