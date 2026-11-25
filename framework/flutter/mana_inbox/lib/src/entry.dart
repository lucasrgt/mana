import 'package:flutter/foundation.dart';

enum ManaInboxSeverity {
  neutral,
  accent,
  positive,
  warning,
  danger;

  static ManaInboxSeverity fromWire(String? raw) => switch (raw?.toLowerCase()) {
    'accent' => ManaInboxSeverity.accent,
    'positive' || 'success' => ManaInboxSeverity.positive,
    'warning' => ManaInboxSeverity.warning,
    'danger' || 'error' => ManaInboxSeverity.danger,
    _ => ManaInboxSeverity.neutral,
  };

  String get wireName => name;
}

/// A single notification entry stored inside [ManaInboxController].
@immutable
final class ManaInboxEntry {
  const ManaInboxEntry({
    required this.id,
    required this.title,
    required this.detail,
    required this.createdAt,
    this.severity = ManaInboxSeverity.neutral,
    this.category,
    this.unread = true,
    this.targetRoute,
    this.targetId,
  });

  final String id;
  final String title;
  final String detail;
  final DateTime createdAt;
  final ManaInboxSeverity severity;
  final String? category;
  final bool unread;
  final String? targetRoute;
  final String? targetId;

  ManaInboxEntry copyWith({
    String? title,
    String? detail,
    ManaInboxSeverity? severity,
    String? category,
    bool? unread,
    String? targetRoute,
    String? targetId,
  }) {
    return ManaInboxEntry(
      id: id,
      title: title ?? this.title,
      detail: detail ?? this.detail,
      createdAt: createdAt,
      severity: severity ?? this.severity,
      category: category ?? this.category,
      unread: unread ?? this.unread,
      targetRoute: targetRoute ?? this.targetRoute,
      targetId: targetId ?? this.targetId,
    );
  }

  factory ManaInboxEntry.fromJson(Map<String, dynamic> json) => ManaInboxEntry(
    id: json['id'] as String,
    title: json['title'] as String,
    detail: (json['detail'] as String?) ?? '',
    createdAt:
        DateTime.tryParse((json['created_at'] as String?) ?? '') ??
        DateTime.now().toUtc(),
    severity: ManaInboxSeverity.fromWire(json['severity'] as String?),
    category: json['category'] as String?,
    unread: (json['unread'] as bool?) ?? true,
    targetRoute: json['target_route'] as String?,
    targetId: json['target_id'] as String?,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'detail': detail,
    'created_at': createdAt.toIso8601String(),
    'severity': severity.wireName,
    if (category != null) 'category': category,
    'unread': unread,
    if (targetRoute != null) 'target_route': targetRoute,
    if (targetId != null) 'target_id': targetId,
  };
}
