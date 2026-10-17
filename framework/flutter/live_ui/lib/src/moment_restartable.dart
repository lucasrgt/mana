import 'package:flutter/widgets.dart';

import 'configuration.dart';
import 'page_reload.dart' if (dart.library.js_interop) 'page_reload_web.dart';

/// The root of an app that can be rebuilt for a newly prepared Moment without
/// reloading its code. [build] runs everything that depends on the Moment (the
/// launch, the persona's session, the starting route) and returns the app;
/// on a remount [build] runs again while the old screen stays up, then the old
/// tree is replaced, so state kept in widgets starts fresh. State kept in globals outside [build] is not
/// reset, which is why the Moments engine falls back to a hot restart when the
/// rebuilt app does not report the Moment.
final class MomentRestartable extends StatefulWidget {
  const MomentRestartable({required this.build, super.key});
  final Future<Widget> Function() build;

  @override
  State<MomentRestartable> createState() => _MomentRestartableState();
}

final class _MomentRestartableState extends State<MomentRestartable> {
  Widget? _child;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    MomentRemount._handler = _load;
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final Widget next;
    try {
      next = await widget.build();
    } on Object {
      // The old tree has already stopped talking to the bridge, so keeping it
      // would leave the Moment without a runtime; a fresh page is the clean path.
      if (_child != null) reloadPage();
      rethrow;
    }
    if (!mounted || generation != _generation) return;
    setState(
      () => _child = KeyedSubtree(key: ValueKey(generation), child: next),
    );
  }

  @override
  void dispose() {
    if (MomentRemount._handler == _load) MomentRemount._handler = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _child ?? const SizedBox.shrink();
}

abstract final class MomentRemount {
  static Future<void> Function()? _handler;

  static bool get available => momentsBuild && _handler != null;

  static bool request() {
    final handler = _handler;
    if (!momentsBuild || handler == null) return false;
    handler();
    return true;
  }
}
