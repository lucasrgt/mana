import 'package:flutter/foundation.dart';

enum ManaToolTraceTone { neutral, accent, positive, warning, danger }

/// Headless tool execution trace attached to an assistant turn.
@immutable
final class ManaToolTrace {
  const ManaToolTrace({
    required this.label,
    this.toolName,
    this.resultLabel,
    this.tone = ManaToolTraceTone.positive,
    this.running = false,
  });

  final String label;
  final String? toolName;
  final String? resultLabel;
  final ManaToolTraceTone tone;
  final bool running;
}

/// Headless structured record returned inline inside an assistant turn.
@immutable
final class ManaAssistantRecord {
  const ManaAssistantRecord({
    required this.title,
    this.subtitle,
    this.value,
    this.badgeLabel,
    this.badgeTone = ManaToolTraceTone.neutral,
    this.targetType,
    this.targetId,
  });

  final String title;
  final String? subtitle;
  final String? value;
  final String? badgeLabel;
  final ManaToolTraceTone badgeTone;
  final String? targetType;
  final String? targetId;
}

/// Headless executable action intent proposed by an assistant turn.
@immutable
final class ManaAssistantIntent {
  const ManaAssistantIntent({
    required this.id,
    required this.label,
    required this.actionKey,
    this.payload = const {},
    this.primary = false,
    this.completed = false,
  });

  final String id;
  final String label;
  final String actionKey;
  final Map<String, Object?> payload;
  final bool primary;
  final bool completed;

  ManaAssistantIntent copyWith({bool? completed}) => ManaAssistantIntent(
    id: id,
    label: label,
    actionKey: actionKey,
    payload: payload,
    primary: primary,
    completed: completed ?? this.completed,
  );
}

/// Single user or assistant turn inside a [ManaChatThread].
@immutable
final class ManaChatTurn {
  const ManaChatTurn({
    required this.id,
    required this.isUser,
    required this.text,
    required this.createdAt,
    this.toolTraces = const [],
    this.records = const [],
    this.intents = const [],
    this.thinking = false,
  });

  final String id;
  final bool isUser;
  final String text;
  final DateTime createdAt;
  final List<ManaToolTrace> toolTraces;
  final List<ManaAssistantRecord> records;
  final List<ManaAssistantIntent> intents;
  final bool thinking;

  ManaChatTurn copyWith({
    String? text,
    List<ManaToolTrace>? toolTraces,
    List<ManaAssistantRecord>? records,
    List<ManaAssistantIntent>? intents,
    bool? thinking,
  }) => ManaChatTurn(
    id: id,
    isUser: isUser,
    text: text ?? this.text,
    createdAt: createdAt,
    toolTraces: toolTraces ?? this.toolTraces,
    records: records ?? this.records,
    intents: intents ?? this.intents,
    thinking: thinking ?? this.thinking,
  );
}

/// Single conversation thread managed by [ManaAssistantController].
@immutable
final class ManaChatThread {
  const ManaChatThread({
    required this.id,
    required this.title,
    required this.updatedAt,
    this.turns = const [],
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final List<ManaChatTurn> turns;

  bool get isEmpty => turns.isEmpty;

  ManaChatThread copyWith({
    String? title,
    DateTime? updatedAt,
    List<ManaChatTurn>? turns,
  }) => ManaChatThread(
    id: id,
    title: title ?? this.title,
    updatedAt: updatedAt ?? this.updatedAt,
    turns: turns ?? this.turns,
  );
}
