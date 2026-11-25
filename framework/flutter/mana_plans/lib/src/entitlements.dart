import 'package:flutter/foundation.dart';

import 'models.dart';

/// Resolved plan entitlements & live usage snapshot for the active workspace.
///
/// Mirrors the server-authoritative snapshot emitted by Ash (`Mana.Plans`),
/// combining the declared [catalog], active [planId], lifecycle [status],
/// live [usage] counters, and optional per-tenant overrides.
@immutable
final class ManaEntitlements {
  const ManaEntitlements({
    required this.catalog,
    required this.planId,
    this.status = ManaPlanStatus.active,
    this.usage = const {},
    this.overrideCapabilities = const {},
    this.revokedCapabilities = const {},
    this.overrideLimits = const {},
    this.renewsAt,
    this.trialEndsAt,
    this.graceOnPastDue = true,
  });

  final ManaPlanCatalog catalog;
  final String planId;
  final ManaPlanStatus status;
  final Map<String, int> usage;

  /// Explicit tenant-level capability grants (e.g. beta access or enterprise add-on).
  final Set<String> overrideCapabilities;

  /// Explicit tenant-level revocations (e.g. compliance hold).
  final Set<String> revokedCapabilities;

  /// Explicit tenant-level quota overrides (`< 0` = unlimited).
  final Map<String, int> overrideLimits;

  final DateTime? renewsAt;
  final DateTime? trialEndsAt;

  /// Whether `pastDue` subscriptions retain paid access during dunning grace.
  final bool graceOnPastDue;

  ManaPlanTier get currentTier => catalog.tierById(planId);

  /// Whether paid tier capabilities remain active right now.
  ///
  /// Note: `canceled` subscriptions keep access until [renewsAt] (end of
  /// billing cycle) when [renewsAt] is in the future; otherwise only `free`
  /// capabilities remain active.
  bool get hasPaidAccess {
    switch (status) {
      case ManaPlanStatus.active:
      case ManaPlanStatus.trialing:
        return true;
      case ManaPlanStatus.pastDue:
        return graceOnPastDue;
      case ManaPlanStatus.canceled:
        if (renewsAt == null) return true;
        return renewsAt!.isAfter(DateTime.now());
      case ManaPlanStatus.free:
        return currentTier.isFree;
    }
  }

  /// Checks whether the active workspace can use [capability].
  bool can(String capability) {
    if (revokedCapabilities.contains(capability)) return false;
    if (overrideCapabilities.contains(capability)) return true;
    if (!hasPaidAccess && !currentTier.isFree) {
      return catalog.tiers.first.hasCapability(capability);
    }
    return currentTier.hasCapability(capability);
  }

  /// Resolves the live [ManaQuotaStatus] for [metric].
  ManaQuotaStatus quota(String metric) {
    final used = usage[metric] ?? 0;
    int? limit;
    if (overrideLimits.containsKey(metric)) {
      final raw = overrideLimits[metric]!;
      limit = raw < 0 ? null : raw;
    } else if (!hasPaidAccess && !currentTier.isFree) {
      limit = catalog.tiers.first.limitFor(metric);
    } else {
      limit = currentTier.limitFor(metric);
    }
    return ManaQuotaStatus(metric: metric, used: used, limit: limit);
  }

  /// Returns `true` if consuming [amount] more units of [metric] is permitted.
  bool canConsume(String metric, [int amount = 1]) =>
      quota(metric).canConsume(amount);

  /// Lowest tier in [catalog] that unlocks [capability].
  ManaPlanTier? requiredTierFor(String capability) =>
      catalog.requiredTierFor(capability);

  /// Next higher tier in [catalog] that raises or removes the cap on [metric].
  ManaPlanTier? nextTierForQuota(String metric) =>
      catalog.nextTierForQuota(metric, currentTier.id);

  ManaEntitlements copyWith({
    ManaPlanCatalog? catalog,
    String? planId,
    ManaPlanStatus? status,
    Map<String, int>? usage,
    Set<String>? overrideCapabilities,
    Set<String>? revokedCapabilities,
    Map<String, int>? overrideLimits,
    DateTime? renewsAt,
    DateTime? trialEndsAt,
    bool? graceOnPastDue,
  }) {
    return ManaEntitlements(
      catalog: catalog ?? this.catalog,
      planId: planId ?? this.planId,
      status: status ?? this.status,
      usage: usage ?? this.usage,
      overrideCapabilities: overrideCapabilities ?? this.overrideCapabilities,
      revokedCapabilities: revokedCapabilities ?? this.revokedCapabilities,
      overrideLimits: overrideLimits ?? this.overrideLimits,
      renewsAt: renewsAt ?? this.renewsAt,
      trialEndsAt: trialEndsAt ?? this.trialEndsAt,
      graceOnPastDue: graceOnPastDue ?? this.graceOnPastDue,
    );
  }

  /// Parses the server snapshot payload emitted by the Ash backend alongside
  /// session / verbs (`plan_id`, `status`, `usage`, `override_capabilities`,
  /// `override_limits`, `renews_at`, `trial_ends_at`).
  factory ManaEntitlements.fromSnapshot(
    Map<String, dynamic> json, {
    required ManaPlanCatalog catalog,
  }) {
    final rawUsage = (json['usage'] as Map<String, dynamic>?) ?? const {};
    final rawOverrides =
        (json['override_capabilities'] as List<dynamic>?) ?? const [];
    final rawRevoked =
        (json['revoked_capabilities'] as List<dynamic>?) ?? const [];
    final rawLimitOverrides =
        (json['override_limits'] as Map<String, dynamic>?) ?? const {};

    DateTime? parseDate(dynamic v) =>
        v is String && v.isNotEmpty ? DateTime.tryParse(v) : null;

    return ManaEntitlements(
      catalog: catalog,
      planId: (json['plan_id'] as String?) ?? catalog.tiers.first.id,
      status: ManaPlanStatus.fromWire(json['status'] as String?),
      usage: {
        for (final e in rawUsage.entries) e.key: (e.value as num).toInt(),
      },
      overrideCapabilities: {for (final c in rawOverrides) c.toString()},
      revokedCapabilities: {for (final c in rawRevoked) c.toString()},
      overrideLimits: {
        for (final e in rawLimitOverrides.entries)
          e.key: (e.value as num).toInt(),
      },
      renewsAt: parseDate(json['renews_at']),
      trialEndsAt: parseDate(json['trial_ends_at']),
    );
  }

  Map<String, dynamic> toSnapshot() => {
    'plan_id': planId,
    'status': status.wireName,
    'usage': usage,
    if (overrideCapabilities.isNotEmpty)
      'override_capabilities': overrideCapabilities.toList()..sort(),
    if (revokedCapabilities.isNotEmpty)
      'revoked_capabilities': revokedCapabilities.toList()..sort(),
    if (overrideLimits.isNotEmpty) 'override_limits': overrideLimits,
    if (renewsAt != null) 'renews_at': renewsAt!.toIso8601String(),
    if (trialEndsAt != null) 'trial_ends_at': trialEndsAt!.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManaEntitlements &&
          other.planId == planId &&
          other.status == status &&
          other.renewsAt == renewsAt &&
          other.trialEndsAt == trialEndsAt &&
          other.graceOnPastDue == graceOnPastDue &&
          mapEquals(other.usage, usage) &&
          setEquals(other.overrideCapabilities, overrideCapabilities) &&
          setEquals(other.revokedCapabilities, revokedCapabilities) &&
          mapEquals(other.overrideLimits, overrideLimits);

  @override
  int get hashCode => Object.hash(
    planId,
    status,
    renewsAt,
    trialEndsAt,
    graceOnPastDue,
    Object.hashAllUnordered(usage.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAllUnordered(overrideCapabilities),
    Object.hashAllUnordered(revokedCapabilities),
    Object.hashAllUnordered(
      overrideLimits.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}
