import 'runtime_configuration.dart';
import 'configuration.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';

final class LiveUiScope extends InheritedNotifier<LiveUiController> {
  const LiveUiScope({
    required LiveUiController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static LiveUiController? of(BuildContext context) => kDebugMode
      ? context.dependOnInheritedWidgetOfExactType<LiveUiScope>()?.notifier
      : null;
}

/// Explicit opt-in; the bridge is not connected in profile or release builds.
final class LiveUiHost extends StatefulWidget {
  const LiveUiHost({required this.child, super.key});
  final Widget child;

  @override
  State<LiveUiHost> createState() => _LiveUiHostState();
}

final class _LiveUiHostState extends State<LiveUiHost> {
  LiveUiController? _controller;

  @override
  void initState() {
    super.initState();
    if (kDebugMode && liveUiEnabled) {
      _controller = LiveUiController();
      unawaited(
        _controller!.connect(
          Uri.parse(MomentRuntime.bridgeUrl),
          MomentRuntime.bridgeToken,
        ),
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _controller == null
      ? widget.child
      : LiveUiScope(controller: _controller!, child: widget.child);
}
