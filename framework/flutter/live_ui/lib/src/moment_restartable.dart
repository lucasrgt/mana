import 'package:flutter/widgets.dart';

import 'configuration.dart';
import 'moments.dart' show MomentHost;
import 'timing.dart';
import 'page_reload.dart' if (dart.library.js_interop) 'page_reload_web.dart';

/// The root of an app that can be rebuilt for a newly prepared Moment without
/// reloading its code. [build] runs everything that depends on the Moment (the
/// launch, the persona's session, the starting route) and returns the app;
/// on a remount the old tree is disposed before [build] runs again, so state
/// kept in widgets starts fresh. State kept in globals outside [build] is not
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
    MomentRemount._handler = _remount;
    _load();
  }

  Future<void> _remount() async {
    final relaunch = MomentRemount._relaunch;
    if (relaunch != null) {
      MomentTiming.start();
      try {
        if (await relaunch()) {
          MomentHost.reconnect();
          return;
        }
      } on Object catch (error) {
        debugPrint('Moments: the app could not take the Moment in place ($error); rebuilding');
      }
    }
    await _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    // The old tree goes first: its reporters hold long polls to the bridge, and
    // a browser allows few connections per origin, so leaving them open would
    // queue the rebuilt app's launch and claim behind them.
    final remounting = _child != null;
    if (remounting) {
      MomentTiming.start();
      setState(() => _child = null);
      await WidgetsBinding.instance.endOfFrame;
    }
    final Widget next;
    try {
      next = await widget.build();
    } on Object {
      // Without a tree there is no runtime for the Moment; a fresh page is the
      // clean way back to one.
      if (remounting) reloadPage();
      rethrow;
    }
    if (!mounted || generation != _generation) return;
    setState(
      () => _child = KeyedSubtree(key: ValueKey(generation), child: next),
    );
  }

  @override
  void dispose() {
    if (MomentRemount._handler == _remount) MomentRemount._handler = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _child ?? const SizedBox.shrink();
}

abstract final class MomentRemount {
  static Future<void> Function()? _handler;
  static Future<bool> Function()? _relaunch;

  /// Lets the running app take a newly prepared Moment without being rebuilt,
  /// the way it would take a person signing out and in as someone else:
  /// [relaunch] applies the new launch and answers whether it could. When it
  /// cannot, or throws, the app is rebuilt. Pass null to withdraw it.
  static void relaunchInPlace(Future<bool> Function()? relaunch) =>
      _relaunch = relaunch;

  static bool get available => momentsBuild && _handler != null;

  static bool request() {
    final handler = _handler;
    if (!momentsBuild || handler == null) return false;
    handler();
    return true;
  }
}
