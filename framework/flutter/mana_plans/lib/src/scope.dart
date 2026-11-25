import 'package:flutter/widgets.dart';

import 'entitlements.dart';
import 'models.dart';

/// Provides [ManaEntitlements] down the widget tree so any screen or component
/// can query capabilities and quotas declaratively via [ManaPlans.of].
final class ManaPlanScope extends InheritedWidget {
  const ManaPlanScope({
    required this.entitlements,
    required super.child,
    super.key,
  });

  final ManaEntitlements entitlements;

  @override
  bool updateShouldNotify(ManaPlanScope oldWidget) =>
      oldWidget.entitlements != entitlements;
}

/// Entrypoint for reading active plan entitlements from a [BuildContext].
abstract final class ManaPlans {
  static ManaEntitlements of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ManaPlanScope>();
    assert(
      scope != null,
      'No ManaPlanScope found in context. Wrap your app in ManaPlanScope.',
    );
    return scope!.entitlements;
  }

  static ManaEntitlements? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<ManaPlanScope>()
        ?.entitlements;
  }
}

/// Headless capability gate widget: renders [allowed] when the active workspace
/// holds [capability], or delegates to [locked] with the lowest [ManaPlanTier]
/// that unlocks it.
final class ManaCapabilityGate extends StatelessWidget {
  const ManaCapabilityGate({
    required this.capability,
    required this.allowed,
    required this.locked,
    super.key,
  });

  final String capability;
  final WidgetBuilder allowed;
  final Widget Function(BuildContext context, ManaPlanTier? requiredTier) locked;

  @override
  Widget build(BuildContext context) {
    final plans = ManaPlans.of(context);
    if (plans.can(capability)) {
      return allowed(context);
    }
    return locked(context, plans.requiredTierFor(capability));
  }
}

/// Headless numeric quota gate widget: renders [allowed] while [metric] has
/// capacity for [amount] more units, or [exceeded] with the [ManaQuotaStatus]
/// and suggested next [ManaPlanTier].
final class ManaQuotaGate extends StatelessWidget {
  const ManaQuotaGate({
    required this.metric,
    required this.allowed,
    required this.exceeded,
    this.amount = 1,
    super.key,
  });

  final String metric;
  final int amount;
  final Widget Function(BuildContext context, ManaQuotaStatus quota) allowed;
  final Widget Function(
    BuildContext context,
    ManaQuotaStatus quota,
    ManaPlanTier? nextTier,
  )
  exceeded;

  @override
  Widget build(BuildContext context) {
    final plans = ManaPlans.of(context);
    final status = plans.quota(metric);
    if (status.canConsume(amount)) {
      return allowed(context, status);
    }
    return exceeded(context, status, plans.nextTierForQuota(metric));
  }
}
