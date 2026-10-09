import 'runtime_configuration.dart';
import 'configuration.dart';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'rendered_tree.dart';
import 'moment_gestures.dart';
import 'restart_frames.dart';
import 'timing.dart';

enum MomentBlockReason {
  authenticationRequired('authentication-required'),
  sessionUnavailable('session-unavailable');

  const MomentBlockReason(this.wire);
  final String wire;
}

final class MomentRuntimeBlocked implements Exception {
  const MomentRuntimeBlocked(this.reason);
  final MomentBlockReason reason;
}

/// Development-only transport. Screens explicitly choose restorable fields.
final class MomentController extends ChangeNotifier {
  MomentController({
    required this.navigate,
    this.resolveRoute,
    http.Client? client,
  }) : _client = client ?? http.Client();

  final void Function(String route) navigate;
  final String Function(Map<String, dynamic> projection)? resolveRoute;
  final http.Client _client;
  final String clientId = DateTime.now().microsecondsSinceEpoch.toString();
  String revision = '';
  Map<String, dynamic>? projection;
  String? name;
  String? lastError;
  Uri? _endpoint;
  Map<String, String> _headers = const {};
  Timer? _pending;
  final _restartFrames = RestartFrames();
  bool _disposed = false;
  int _sequence = 0;
  final _frameReaders = <Object, Map<String, dynamic>? Function()>{};
  final _blockers = <Object, MomentBlockReason>{};
  Future<void> _blockerWrites = Future.value();
  int _blockerSequence = 0;
  String? _reportedBlocker;
  bool _blockerScheduled = false;
  bool _supportsBlocker = false;

  void setBlocker(Object owner, MomentBlockReason? reason) {
    if (_disposed) return;
    if (reason == null) {
      _blockers.remove(owner);
    } else {
      _blockers[owner] = reason;
    }
    if (_blockerScheduled) return;
    _blockerScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _blockerScheduled = false;
      unawaited(
        _reportBlocker().catchError((Object error) {
          if (!_disposed) lastError = 'Runtime availability report failed';
        }),
      );
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _reportBlocker({String? frameId}) {
    final next = _blockerWrites.catchError((_) {}).then((_) async {
      if (_disposed ||
          !_supportsBlocker ||
          _endpoint == null ||
          revision.isEmpty) {
        return;
      }
      final reason = _blockers.values.firstOrNull?.wire;
      final key = '$revision:$reason:$frameId';
      if (_reportedBlocker == key) return;
      final atRevision = revision;
      final response = await _client
          .post(
            _endpoint!.resolve('/moments/blocker'),
            headers: _headers,
            body: jsonEncode({
              'revision': atRevision,
              'client': clientId,
              'sequence': ++_blockerSequence,
              'reason': reason,
              'frameId': ?frameId,
            }),
          )
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        throw StateError('Runtime availability rejected');
      }
      if (!_disposed && revision == atRevision) _reportedBlocker = key;
    });
    _blockerWrites = next;
    return next;
  }

  /// A binding reads only its declared projection, never the widget tree or secrets.
  void registerFrameReader(
    Object owner,
    Map<String, dynamic>? Function() read,
  ) {
    _frameReaders[owner] = read;
  }

  void removeFrameReader(Object owner) => _frameReaders.remove(owner);

  /// Called after compilation, without restoring a recipe or invoking domain actions.
  Future<Map<String, dynamic>> readFrame(String atRevision) async {
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame;
    if (_disposed || atRevision != revision) {
      throw StateError('Moment changed before frame observation');
    }
    if (_blockers.values.firstOrNull case final reason?) {
      throw MomentRuntimeBlocked(reason);
    }
    final values = _frameReaders.values
        .map((read) => read())
        .whereType<Map<String, dynamic>>()
        .where((value) => value['route'] == projection?['route'])
        .toList();
    if (values.length != 1) {
      throw StateError(
        'Expected one ready Moment binding; found ${values.length}',
      );
    }
    return values.single;
  }

  Future<void> _frame(Map control) async {
    final atRevision = control['revision'] as String;
    final Map<String, dynamic> value;
    try {
      value = await readFrame(atRevision);
    } on MomentRuntimeBlocked {
      await _reportBlocker(frameId: control['id'] as String);
      // Keep the challenge outstanding until the application clears its gate.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      return;
    }
    await _reportBlocker();
    if (_disposed || atRevision != revision) return;
    final capture = control['capture'] == true;
    if (capture) _pending?.cancel();
    final sequence = capture ? ++_sequence : _sequence;
    final response = await _client.post(
      _endpoint!.resolve('/moments/frame-ack'),
      headers: _headers,
      body: jsonEncode({
        'id': control['id'],
        if (capture) 'capture': true,
        if (capture) 'sequence': sequence,
        'revision': atRevision,
        'client': clientId,
        'projection': value,
      }),
    );
    if (response.statusCode != 200) {
      throw StateError('Post-compile frame observation rejected');
    }
    lastError = null;
  }

  void restore(String next, Map<String, dynamic>? state) {
    if (_disposed || next == revision) return;
    final nextProjection = state == null
        ? null
        : Map<String, dynamic>.from(state['projection'] as Map);
    final route = nextProjection == null
        ? null
        : resolveRoute?.call(
                Map<String, dynamic>.unmodifiable(nextProjection),
              ) ??
              nextProjection['route'] as String;
    if (route != null && (!route.startsWith('/') || route.startsWith('//'))) {
      throw StateError('Moment navigation must stay within the application');
    }
    _pending?.cancel();
    MomentTiming.mark(MomentMark.momentReceived);
    revision = next;
    projection = nextProjection;
    name = state?['name'] as String?;
    if (route != null) navigate(route);
    notifyListeners();
  }

  Future<void> connect(Uri endpoint, String token) async {
    if (!momentsBuild || _endpoint != null || _disposed) return;
    if (endpoint.scheme != 'http' ||
        !const ['localhost', '127.0.0.1', '::1'].contains(endpoint.host)) {
      throw ArgumentError('Moments requires loopback HTTP');
    }
    _endpoint = endpoint;
    _headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    while (!_disposed) {
      try {
        final response = await _client.get(
          endpoint
              .resolve('/moments/changes')
              .replace(
                queryParameters: {
                  'since': revision,
                  'client': clientId,
                  'frame': '1',
                  'captureFrame': '1',
                },
              ),
          headers: _headers,
        );
        if (_disposed) return;
        if (response.statusCode == 204) continue;
        if (response.statusCode == 409) {
          _pending?.cancel();
          lastError = 'Another runtime owns the Moments session.';
          return;
        }
        if (response.statusCode != 200) {
          throw StateError('Moments: ${response.statusCode}');
        }
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _supportsBlocker = _supportsBlocker || data['runtimeBlocker'] == 1;
        if (data['restart'] case final Map control) {
          await _restart(control);
          if (_disposed) return;
        }
        restore(
          data['revision'] as String,
          data['state'] as Map<String, dynamic>?,
        );
        if (data['frame'] case final Map control) await _frame(control);
      } on Object catch (error) {
        if (_disposed) return;
        lastError = error.toString();
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _restart(Map control) async {
    final id = control['id'] as String;
    final pausing = control['phase'] == 'pause';
    if (!pausing && control['phase'] != 'resume') {
      throw StateError('Unsupported restart control');
    }
    if (pausing) {
      final lease = control['leaseMs'] as int;
      if (lease < 1000 || lease > 90000) {
        throw StateError('Invalid restart lease');
      }
      _restartFrames.pause(id, Duration(milliseconds: lease));
    } else {
      _restartFrames.resume(id);
    }
    try {
      final response = await _client.post(
        _endpoint!.resolve('/moments/restart-ack'),
        headers: _headers,
        body: jsonEncode({
          'id': id,
          'client': clientId,
          'phase': pausing ? 'paused' : 'resumed',
        }),
      );
      if (response.statusCode != 200) {
        throw StateError('Restart handoff rejected');
      }
    } on Object {
      _restartFrames.resume(id);
      rethrow;
    }
  }

  /// A short debounce coalesces a burst of rebuilds into one write; it sits
  /// on every journey step's path to its postcondition, so it stays small.
  void capture(Map<String, dynamic> value) {
    if (_disposed || projection == null) return;
    _pending?.cancel();
    final atRevision = revision;
    _pending = Timer(const Duration(milliseconds: 30), () {
      unawaited(_send('capture', atRevision, value));
    });
  }

  Future<void> observe(Map<String, dynamic> value) =>
      _send('observe', revision, value);

  Future<void> _send(
    String op,
    String atRevision,
    Map<String, dynamic> value,
  ) async {
    final endpoint = _endpoint;
    if (_disposed || endpoint == null || atRevision != revision) return;
    try {
      await _reportBlocker();
      if (_disposed || _blockers.isNotEmpty || atRevision != revision) return;
      if (op == 'observe') MomentTiming.mark(MomentMark.observeSent);
      final response = await _client.post(
        endpoint.resolve('/moments/$op'),
        headers: _headers,
        body: jsonEncode({
          'revision': atRevision,
          'client': clientId,
          'sequence': ++_sequence,
          'projection': value,
          if (op == 'observe') 'timing': MomentTiming.snapshot(),
        }),
      );
      if (response.statusCode != 200) {
        throw StateError('Draft not saved: ${response.statusCode}');
      }
      lastError = null;
    } on Object catch (error) {
      if (!_disposed) lastError = error.toString();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _pending?.cancel();
    _restartFrames.dispose();
    _frameReaders.clear();
    _blockers.clear();
    _client.close();
    super.dispose();
  }
}

final class MomentScope extends InheritedNotifier<MomentController> {
  const MomentScope({
    required MomentController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
  static MomentController? of(BuildContext context) => momentsBuild
      ? context.dependOnInheritedWidgetOfExactType<MomentScope>()?.notifier
      : null;
}

/// Reports an application gate; it never authenticates, navigates or captures
/// the replacement screen as the requested Moment. In release it is inert.
final class MomentRuntimeBlocker extends StatefulWidget {
  const MomentRuntimeBlocker({
    required this.reason,
    required this.child,
    super.key,
  });
  final MomentBlockReason? reason;
  final Widget child;
  @override
  State<MomentRuntimeBlocker> createState() => _MomentRuntimeBlockerState();
}

final class _MomentRuntimeBlockerState extends State<MomentRuntimeBlocker> {
  MomentController? controller;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = MomentScope.of(context);
    if (next != controller) controller?.setBlocker(this, null);
    controller = next;
    controller?.setBlocker(this, widget.reason);
  }

  @override
  void didUpdateWidget(MomentRuntimeBlocker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reason != widget.reason) {
      controller?.setBlocker(this, widget.reason);
    }
  }

  @override
  void dispose() {
    controller?.setBlocker(this, null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final class MomentHost extends StatefulWidget {
  const MomentHost({
    required this.navigate,
    this.resolveRoute,
    required this.child,
    super.key,
  });
  final void Function(String route) navigate;

  /// Select a local destination from declared view state for a multi-route flow.
  /// This callback must be pure; it never prepares data or executes an action.
  final String Function(Map<String, dynamic> projection)? resolveRoute;
  final Widget child;
  @override
  State<MomentHost> createState() => _MomentHostState();
}

final class _MomentHostState extends State<MomentHost> {
  MomentController? _controller;
  RenderedTreeReporter? _rendered;
  MomentGestureReporter? _gestures;
  @override
  void initState() {
    super.initState();
    if (momentsBuild && momentsEnabled) {
      _controller = MomentController(
        navigate: (route) => widget.navigate(route),
        resolveRoute: (projection) =>
            widget.resolveRoute?.call(projection) ??
            projection['route'] as String,
      );
      unawaited(
        _controller!.connect(
          Uri.parse(MomentRuntime.bridgeUrl),
          MomentRuntime.bridgeToken,
        ),
      );
      _rendered = RenderedTreeReporter(_controller!);
      _gestures = MomentGestureReporter(_controller!);
      unawaited(
        _gestures!.connect(
          Uri.parse(MomentRuntime.bridgeUrl),
          MomentRuntime.bridgeToken,
        ),
      );
      unawaited(
        _rendered!.connect(
          Uri.parse(MomentRuntime.bridgeUrl),
          MomentRuntime.bridgeToken,
        ),
      );
    }
  }

  @override
  void dispose() {
    _rendered?.dispose();
    _gestures?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller == null
      ? widget.child
      : MomentScope(controller: _controller!, child: widget.child);
}

/// Opt-in binding for form drafts. Controllers not listed in [fields] are never
/// captured; [clearOnRestore] can explicitly clear transient secret inputs.
final class MomentDraftBinding {
  MomentDraftBinding({
    required this.route,
    required this.fields,
    required this.focus,
    this.clearOnRestore = const [],
  }) {
    for (final field in fields.values) {
      field.addListener(_capture);
    }
    for (final node in focus.values) {
      node.addListener(_capture);
    }
  }

  final String route;
  final Map<String, TextEditingController> fields;
  final Map<String, FocusNode> focus;
  final List<TextEditingController> clearOnRestore;
  MomentController? _controller;
  String? _restoredRevision;
  bool _restoring = false;
  bool _disposed = false;

  void attach(BuildContext context) {
    final next = MomentScope.of(context);
    if (next != _controller) {
      _controller?.removeFrameReader(this);
      _controller = next;
      _restoredRevision = null;
      next?.registerFrameReader(this, _readFrame);
    }
    final controller = _controller;
    final value = controller?.projection;
    if (controller == null ||
        value == null ||
        value['route'] != route ||
        _restoredRevision == controller.revision) {
      return;
    }
    _restoredRevision = controller.revision;
    _restoring = true;
    final revision = controller.revision;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _controller?.revision != revision) return;
      final saved = value['fields'] as Map;
      for (final entry in fields.entries) {
        entry.value.text = saved[entry.key] as String;
      }
      for (final field in clearOnRestore) {
        field.clear();
      }
      final target = value['focus'] as String;
      final field = fields[target];
      if (focus[target] case final node?) {
        node.requestFocus();
      } else {
        for (final node in focus.values) {
          node.unfocus();
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed || _controller?.revision != revision) return;
        // Web/desktop may select all on focus. Restore the caret afterwards.
        if (field != null) {
          final selection = (value['selection'] as List).cast<int>();
          field.selection = TextSelection(
            baseOffset: selection[0].clamp(0, field.text.length),
            extentOffset: selection[1].clamp(0, field.text.length),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || _controller?.revision != revision) return;
          _restoring = false;
          unawaited(controller.observe(_projection()));
        });
        WidgetsBinding.instance.scheduleFrame();
      });
      WidgetsBinding.instance.scheduleFrame();
    });
  }

  Map<String, dynamic>? _readFrame() {
    if (_disposed ||
        _restoring ||
        _controller?.projection?['route'] != route ||
        _controller?.revision != _restoredRevision) {
      return null;
    }
    return _projection();
  }

  Map<String, dynamic> _projection() {
    final target =
        focus.entries
            .where((entry) => entry.value.hasFocus)
            .map((entry) => entry.key)
            .firstOrNull ??
        'none';
    final field = fields[target];
    return {
      'route': route,
      'fields': {
        for (final entry in fields.entries) entry.key: entry.value.text,
      },
      'focus': target,
      'selection': field == null
          ? [0, 0]
          : [
              field.selection.baseOffset.clamp(0, field.text.length),
              field.selection.extentOffset.clamp(0, field.text.length),
            ],
    };
  }

  void _capture() {
    // Browser/runtime teardown can blur every field before restarting. Preserve
    // the last editing focus rather than saving that transient blur.
    if (!_disposed &&
        !_restoring &&
        focus.values.any((node) => node.hasFocus)) {
      _controller?.capture(_projection());
    }
  }

  void dispose() {
    _disposed = true;
    _controller?.removeFrameReader(this);
    for (final field in fields.values) {
      field.removeListener(_capture);
    }
    for (final node in focus.values) {
      node.removeListener(_capture);
    }
  }
}
