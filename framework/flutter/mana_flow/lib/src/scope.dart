import 'package:flutter/widgets.dart';

import 'controller.dart';

/// Reactive [InheritedNotifier] exposing a [ManaFlowController] down the tree.
final class ManaFlowScope<T> extends InheritedNotifier<ManaFlowController<T>> {
  const ManaFlowScope({
    required ManaFlowController<T> controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);

  static ManaFlowController<T> of<T>(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ManaFlowScope<T>>();
    assert(
      scope != null && scope.notifier != null,
      'No ManaFlowScope<$T> found in context.',
    );
    return scope!.notifier!;
  }
}
