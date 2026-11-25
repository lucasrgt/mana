import 'package:flutter/foundation.dart';

import 'step.dart';

/// Deterministic multi-step guided flow controller.
///
/// Manages an immutable [draft] of type [T], dynamic [visibleSteps] respecting
/// [ManaFlowStep.skipIf], validation errors, answered trail summaries, and
/// jump-back editing without prescribing any UI widgets.
final class ManaFlowController<T> extends ChangeNotifier {
  ManaFlowController({
    required T initialDraft,
    required List<ManaFlowStep<T>> steps,
  }) : assert(steps.isNotEmpty, 'ManaFlowController requires at least one step'),
       _draft = initialDraft,
       _allSteps = List.unmodifiable(steps) {
    _currentStepId = visibleSteps.first.id;
  }

  T _draft;
  final List<ManaFlowStep<T>> _allSteps;
  late String _currentStepId;
  String? _errorText;
  bool _submitting = false;

  T get draft => _draft;

  String? get errorText => _errorText;

  bool get isSubmitting => _submitting;

  /// Ordered steps currently active for [_draft] (excluding skipped steps).
  List<ManaFlowStep<T>> get visibleSteps {
    final list = [
      for (final step in _allSteps)
        if (!(step.skipIf?.call(_draft) ?? false)) step,
    ];
    return list.isEmpty ? [_allSteps.first] : list;
  }

  int get stepIndex {
    final steps = visibleSteps;
    final idx = steps.indexWhere((s) => s.id == _currentStepId);
    return idx < 0 ? 0 : idx;
  }

  int get stepCount => visibleSteps.length;

  ManaFlowStep<T> get currentStep => visibleSteps[stepIndex];

  bool get isFirst => stepIndex == 0;

  bool get isLast => stepIndex >= stepCount - 1;

  double get progress =>
      stepCount <= 0 ? 1.0 : ((stepIndex + 1) / stepCount).clamp(0.0, 1.0);

  bool get canProceed =>
      !_submitting && (currentStep.canAdvance?.call(_draft) ?? true);

  /// Summaries for all visible steps strictly before [stepIndex], plus any
  /// skipped pre-filled steps that still expose a [ManaFlowStep.summary].
  List<ManaFlowAnswer> get answeredTrail {
    final activeId = currentStep.id;
    final out = <ManaFlowAnswer>[];
    for (final step in _allSteps) {
      if (step.id == activeId) break;
      final text = step.summary?.call(_draft)?.trim();
      if (text != null && text.isNotEmpty) {
        out.add(ManaFlowAnswer(stepId: step.id, text: text));
      }
    }
    return out;
  }

  void update(T nextDraft) {
    _draft = nextDraft;
    _errorText = null;
    // Keep _currentStepId pointing to a visible step if skipIf changed.
    final steps = visibleSteps;
    if (steps.every((s) => s.id != _currentStepId)) {
      _currentStepId = steps.first.id;
    }
    notifyListeners();
  }

  /// Validates the current step and moves to the next visible step.
  /// Returns `true` if advanced cleanly, `false` if blocked by validation.
  bool next() {
    if (_submitting) return false;
    final err = currentStep.validate?.call(_draft);
    if (err != null) {
      _errorText = err;
      notifyListeners();
      return false;
    }
    _errorText = null;
    final steps = visibleSteps;
    final idx = stepIndex;
    if (idx + 1 < steps.length) {
      _currentStepId = steps[idx + 1].id;
      notifyListeners();
      return true;
    }
    notifyListeners();
    return false;
  }

  bool back() {
    if (_submitting) return false;
    final steps = visibleSteps;
    final idx = stepIndex;
    if (idx <= 0) return false;
    _errorText = null;
    _currentStepId = steps[idx - 1].id;
    notifyListeners();
    return true;
  }

  /// Jumps directly to a visible step by [stepId] (e.g. clicking an answer chip).
  bool jumpTo(String stepId) {
    if (_submitting) return false;
    final steps = visibleSteps;
    if (steps.every((s) => s.id != stepId)) return false;
    _errorText = null;
    _currentStepId = stepId;
    notifyListeners();
    return true;
  }

  /// Validates the final step and invokes [onComplete].
  Future<bool> submit(Future<void> Function(T draft) onComplete) async {
    if (_submitting) return false;
    final err = currentStep.validate?.call(_draft);
    if (err != null) {
      _errorText = err;
      notifyListeners();
      return false;
    }
    _errorText = null;
    _submitting = true;
    notifyListeners();
    try {
      await onComplete(_draft);
      return true;
    } finally {
      _submitting = false;
      notifyListeners();
    }
  }
}
