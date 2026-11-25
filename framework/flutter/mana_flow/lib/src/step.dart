import 'package:flutter/foundation.dart';

/// Declarative definition of a single step inside a [ManaFlowController].
@immutable
final class ManaFlowStep<T> {
  const ManaFlowStep({
    required this.id,
    this.validate,
    this.canAdvance,
    this.skipIf,
    this.summary,
  });

  /// Stable identifier for jumping back to edit this step.
  final String id;

  /// Returns a localized validation message if the step cannot proceed, or `null`.
  final String? Function(T draft)? validate;

  /// Optional fast readiness check used to enable/disable the Next button.
  final bool Function(T draft)? canAdvance;

  /// When returning `true`, this step is omitted dynamically from the flow.
  final bool Function(T draft)? skipIf;

  /// Short human-readable summary of the user's answer for this step, rendered
  /// in the conversational answered trail so the user can tap to jump back.
  final String? Function(T draft)? summary;
}

/// Summary chip entry for a completed prior step in a guided flow.
@immutable
final class ManaFlowAnswer {
  const ManaFlowAnswer({required this.stepId, required this.text});

  final String stepId;
  final String text;
}
