import 'package:flutter/widgets.dart';

import 'controller.dart';

/// Reactive [InheritedNotifier] exposing a [ManaAssistantController] down the tree.
final class ManaAssistantScope extends InheritedNotifier<ManaAssistantController> {
  const ManaAssistantScope({
    required ManaAssistantController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
}

abstract final class ManaAssistant {
  static ManaAssistantController of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<ManaAssistantScope>();
    assert(
      scope != null && scope.notifier != null,
      'No ManaAssistantScope found in context.',
    );
    return scope!.notifier!;
  }

  static ManaAssistantController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ManaAssistantScope>()
        ?.notifier;
  }
}
