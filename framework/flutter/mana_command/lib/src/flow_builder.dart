import 'package:flutter/widgets.dart';
import 'package:mana_primitives/mana_primitives.dart';

/// The screens of a journey (`Mana.Flow`) in the order a person meets them,
/// each bound to the server step it completes or to none (a check the app
/// runs between steps, such as confirming a phone). The server keeps the
/// cursor; this only lays the screens over it.
final class FlowScreens<S> {
  const FlowScreens(this.flow, this.screens);

  final ManaFlow flow;
  final List<(S screen, String? step)> screens;

  int get length => screens.length;

  int indexOf(S screen) => screens.indexWhere((entry) => entry.$1 == screen);

  /// From 0 to 1, counting [screen] as reached.
  double progress(S screen) =>
      screens.isEmpty ? 1 : (indexOf(screen) + 1) / screens.length;

  S? previous(S screen) {
    final index = indexOf(screen);
    return index > 0 ? screens[index - 1].$1 : null;
  }

  S? next(S screen) {
    final index = indexOf(screen);
    return index >= 0 && index + 1 < screens.length
        ? screens[index + 1].$1
        : null;
  }

  /// Where to pick up for the server's [cursor]: the first screen not yet
  /// passed, or the last once the flow is done. A step behind the cursor is
  /// passed, and so is an app screen before the cursor's; [passed] may say
  /// otherwise for any screen (details already typed, a phone not proven).
  S resume(String? cursor, {bool? Function(S screen)? passed}) {
    final at = flow.isDone(cursor) ? flow.steps.length : flow.indexOf(cursor);
    final cursorScreen = screens.indexWhere((entry) => entry.$2 == cursor);
    for (final (index, (screen, step)) in screens.indexed) {
      final behind = step == null
          ? cursorScreen < 0
                ? flow.isDone(cursor)
                : index < cursorScreen
          : flow.indexOf(step) < at;
      if (!(passed?.call(screen) ?? behind)) return screen;
    }
    return screens.last.$1;
  }
}

/// Where a screen stands in its journey, for its chrome.
final class FlowPosition<S> {
  const FlowPosition({
    required this.screen,
    required this.index,
    required this.total,
    required this.previous,
  });

  final S screen;
  final int index;
  final int total;
  final S? previous;

  double get progress => total == 0 ? 1 : (index + 1) / total;
}

/// Draws the [current] screen of [screens] with its [FlowPosition]: the
/// step badge, the progress and where back leads come from the flow.
final class FlowBuilder<S> extends StatelessWidget {
  const FlowBuilder({
    required this.screens,
    required this.current,
    required this.builder,
    super.key,
  });

  final FlowScreens<S> screens;
  final S current;
  final Widget Function(BuildContext context, FlowPosition<S> position) builder;

  @override
  Widget build(BuildContext context) => builder(
    context,
    FlowPosition(
      screen: current,
      index: screens.indexOf(current),
      total: screens.length,
      previous: screens.previous(current),
    ),
  );
}
