import 'package:flutter/widgets.dart';

import 'controller.dart';

/// Reactive [InheritedNotifier] exposing a [ManaInboxController] down the tree.
final class ManaInboxScope extends InheritedNotifier<ManaInboxController> {
  const ManaInboxScope({
    required ManaInboxController controller,
    required super.child,
    super.key,
  }) : super(notifier: controller);
}

abstract final class ManaInbox {
  static ManaInboxController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ManaInboxScope>();
    assert(
      scope != null && scope.notifier != null,
      'No ManaInboxScope found in context.',
    );
    return scope!.notifier!;
  }

  static ManaInboxController? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ManaInboxScope>()
        ?.notifier;
  }
}
