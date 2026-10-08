import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'moments.dart';

/// On-demand debug inspection. Does not change Inspector selection, invoke
/// callbacks, or collect text, keys, field values or diagnostic descriptions.
final class RenderedTree {
  final _locations = _Locations();
  final _ids = Expando<String>();
  int _next = 0;

  String _id(Element e) => _ids[e] ??= 'element_${++_next}';

  Map<String, Object?> capture(Set<String> kinds, {int maxVisited = 20000}) {
    if (!kDebugMode) {
      throw StateError('Rendered inspection requires debug mode');
    }
    final watch = Stopwatch()..start();
    final nodes = <Map<String, Object?>>[];
    var visited = 0;
    var truncated = false;
    void visit(Element element) {
      if (++visited > maxVisited || nodes.length >= 512) {
        truncated = true;
        return;
      }
      final kind = element.widget.runtimeType.toString().split('<').first;
      if (kinds.contains(kind)) {
        final location = _locations.read(element);
        if (location != null) {
          final geometry = _geometry(element);
          final ancestors = <Map<String, String>>[];
          element.visitAncestorElements((ancestor) {
            // Opaque identities distinguish repeated instances without leaking
            // ValueKeys (often domain IDs) or widget diagnostic text.
            if (ancestors.length >= 8) return false;
            ancestors.add({
              'id': _id(ancestor),
              'widget': ancestor.widget.runtimeType.toString().split('<').first,
            });
            return true;
          });
          nodes.add({
            'id': _id(element),
            'widget': kind,
            'location': location,
            ...geometry,
            'ancestors': ancestors,
          });
        }
      }
      element.visitChildren(visit);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    return {
      'nodes': nodes,
      'visited': visited,
      'truncated': truncated,
      'tracking': _locations.isWidgetCreationTracked(),
      'captureMs': watch.elapsedMicroseconds / 1000,
      'visibilityMeaning': 'mounted and intersects viewport after ancestor clips; occlusion not tested',
    };
  }

  Map<String, Object?> _geometry(Element element) {
    final render = element.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) {
      return {'inViewport': false, 'reason': 'no-layout'};
    }
    final bounds = MatrixUtils.transformRect(
      render.getTransformTo(null),
      Offset.zero & render.size,
    );
    if (!bounds.isFinite) {
      return {'inViewport': false, 'reason': 'empty-bounds'};
    }
    // A SizedBox(width: gap) inside a Row has zero height but contributes a
    // real layout interval. Project that interval across its parent's cross
    // axis, retaining the actual (zero-area) bounds separately.
    var footprint = bounds;
    final layoutParent = render.parent;
    if (bounds.isEmpty && layoutParent is RenderFlex && layoutParent.hasSize) {
      final parentBounds = MatrixUtils.transformRect(
        layoutParent.getTransformTo(null),
        Offset.zero & layoutParent.size,
      );
      if (layoutParent.direction == Axis.horizontal && bounds.width > 0) {
        footprint = Rect.fromLTWH(
          bounds.left,
          parentBounds.top,
          bounds.width,
          parentBounds.height,
        );
      } else if (layoutParent.direction == Axis.vertical && bounds.height > 0) {
        footprint = Rect.fromLTWH(
          parentBounds.left,
          bounds.top,
          parentBounds.width,
          bounds.height,
        );
      }
    }
    if (footprint.isEmpty) {
      return {'inViewport': false, 'reason': 'empty-bounds'};
    }
    Rect clipped = footprint;
    RenderObject? child = render;
    while (child != null) {
      if ((child is RenderOffstage && child.offstage) ||
          (child is RenderSliverOffstage && child.offstage) ||
          (child is RenderOpacity && child.opacity == 0) ||
          (child is RenderAnimatedOpacity && child.opacity.value == 0) ||
          (child is RenderSliverOpacity && child.opacity == 0)) {
        return {
          'inViewport': false,
          'reason': 'not-painted',
          'bounds': _rect(bounds),
        };
      }
      if (child is RenderView) {
        clipped = clipped.intersect(Offset.zero & child.size);
      }
      final parent = child.parent;
      if (parent != null) {
        final clip = parent.describeApproximatePaintClip(child);
        if (clip != null) {
          clipped = clipped.intersect(
            MatrixUtils.transformRect(parent.getTransformTo(null), clip),
          );
        }
      }
      child = parent;
    }
    return {
      'inViewport': !clipped.isEmpty,
      'reason': clipped.isEmpty ? 'clipped' : 'in-viewport',
      'bounds': _rect(bounds),
      'layoutOnly': bounds.isEmpty,
      if (!clipped.isEmpty) 'visibleBounds': _rect(clipped),
    };
  }

  List<double> _rect(Rect rect) => [
    rect.left,
    rect.top,
    rect.width,
    rect.height,
  ];
}

// Own inspector instance: public mixin API, no change to the global inspector.
// Protected identity methods are called from within the mixin's subclass.
final class _Locations with WidgetInspectorService {
  Map<String, Object?>? read(Element element) {
    const group = 'moments-location';
    try {
      final id = toId(element, group)!;
      final json =
          jsonDecode(getDetailsSubtree(id, group, subtreeDepth: 0)) as Map;
      final location = json['creationLocation'];
      if (location is! Map) return null;
      return {
        'file': location['file'],
        'line': location['line'],
        'column': location['column'],
      };
    } finally {
      disposeGroup(group);
    }
  }
}

final class RenderedTreeReporter {
  RenderedTreeReporter(this.moment, {http.Client? client})
    : _client = client ?? http.Client();
  final MomentController moment;
  final http.Client _client;
  final _tree = RenderedTree();
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
              .resolve('/render/next')
              .replace(queryParameters: {'client': moment.clientId}),
          headers: headers,
        );
        if (_disposed) return;
        if (response.statusCode == 409) {
          return; // A newer runtime owns the Moment.
        }
        if (response.statusCode == 204) continue;
        if (response.statusCode != 200) {
          throw StateError('Inspection transport unavailable');
        }
        final request = jsonDecode(response.body) as Map;
        await WidgetsBinding.instance.endOfFrame;
        if (_disposed) return;
        Map<String, Object?> report;
        try {
          if (request['revision'] != moment.revision) {
            throw StateError('Moment changed');
          }
          report = _tree.capture(
            (request['kinds'] as List).cast<String>().toSet(),
          );
        } on Object {
          report = {'error': 'Could not capture the current rendered tree'};
        }
        await _client.post(
          endpoint.resolve('/render/result'),
          headers: headers,
          body: jsonEncode({
            'id': request['id'],
            'client': moment.clientId,
            'revision': moment.revision,
            'report': report,
          }),
        );
      } on Object {
        if (_disposed) return;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  void dispose() {
    _disposed = true;
    _client.close();
  }
}
