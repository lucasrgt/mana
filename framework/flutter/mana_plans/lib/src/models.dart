import 'package:flutter/foundation.dart';

/// Lifecycle status of a workspace or user subscription.
enum ManaPlanStatus {
  free,
  trialing,
  active,
  pastDue,
  canceled;

  /// Parses a backend wire string (`"active"`, `"past_due"`, `"trialing"`, etc.).
  static ManaPlanStatus fromWire(String? raw) => switch (raw?.toLowerCase()) {
    'trialing' => ManaPlanStatus.trialing,
    'active' => ManaPlanStatus.active,
    'past_due' || 'pastdue' => ManaPlanStatus.pastDue,
    'canceled' || 'cancelled' => ManaPlanStatus.canceled,
    _ => ManaPlanStatus.free,
  };

  /// Canonical snake_case wire format matching Ash/Elixir backend snapshots.
  String get wireName => switch (this) {
    ManaPlanStatus.free => 'free',
    ManaPlanStatus.trialing => 'trialing',
    ManaPlanStatus.active => 'active',
    ManaPlanStatus.pastDue => 'past_due',
    ManaPlanStatus.canceled => 'canceled',
  };
}

/// Declarative definition of a single product tier (e.g. `free`, `pro`, `scale`).
@immutable
final class ManaPlanTier {
  const ManaPlanTier({
    required this.id,
    required this.name,
    this.tagline,
    this.monthlyPrices = const {},
    this.yearlyPrices = const {},
    this.capabilities = const {},
    this.limits = const {},
    this.highlighted = false,
  });

  final String id;
  final String name;
  final String? tagline;

  /// Monthly recurring prices keyed by ISO currency code (`BRL`, `USD`, `EUR`).
  final Map<String, double> monthlyPrices;

  /// Optional annual recurring prices (per month or total per app convention).
  final Map<String, double> yearlyPrices;

  /// Boolean feature flags unlocked by this tier (e.g. `mcp_write`, `whatsapp`).
  final Set<String> capabilities;

  /// Numeric quota limits keyed by metric name (e.g. `active_customers: 100`).
  /// A missing key or negative value (`< 0`) represents an unlimited quota.
  final Map<String, int> limits;

  final bool highlighted;

  bool get isFree =>
      monthlyPrices.isEmpty || monthlyPrices.values.every((v) => v <= 0);

  /// Returns the monthly price for [currencyCode], falling back cleanly to
  /// `USD`, `BRL`, or the first declared currency if unavailable.
  double monthlyPriceFor(String currencyCode) {
    final code = currencyCode.toUpperCase();
    if (monthlyPrices.containsKey(code)) return monthlyPrices[code]!;
    if (monthlyPrices.containsKey('USD')) return monthlyPrices['USD']!;
    if (monthlyPrices.containsKey('BRL')) return monthlyPrices['BRL']!;
    return monthlyPrices.isEmpty ? 0 : monthlyPrices.values.first;
  }

  bool hasCapability(String capability) => capabilities.contains(capability);

  /// Returns the integer limit for [metric], or `null` when unlimited.
  int? limitFor(String metric) {
    final raw = limits[metric];
    if (raw == null || raw < 0) return null;
    return raw;
  }

  factory ManaPlanTier.fromJson(Map<String, dynamic> json) {
    final rawMonthly = (json['monthly_prices'] as Map<String, dynamic>?) ?? {};
    final rawYearly = (json['yearly_prices'] as Map<String, dynamic>?) ?? {};
    final rawCaps = (json['capabilities'] as List<dynamic>?) ?? const [];
    final rawLimits = (json['limits'] as Map<String, dynamic>?) ?? {};

    return ManaPlanTier(
      id: json['id'] as String,
      name: json['name'] as String,
      tagline: json['tagline'] as String?,
      monthlyPrices: {
        for (final e in rawMonthly.entries)
          e.key.toUpperCase(): (e.value as num).toDouble(),
      },
      yearlyPrices: {
        for (final e in rawYearly.entries)
          e.key.toUpperCase(): (e.value as num).toDouble(),
      },
      capabilities: {for (final c in rawCaps) c.toString()},
      limits: {
        for (final e in rawLimits.entries)
          if (e.value != null) e.key: (e.value as num).toInt(),
      },
      highlighted: (json['highlighted'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (tagline != null) 'tagline': tagline,
    'monthly_prices': monthlyPrices,
    if (yearlyPrices.isNotEmpty) 'yearly_prices': yearlyPrices,
    'capabilities': capabilities.toList()..sort(),
    'limits': limits,
    'highlighted': highlighted,
  };
}

/// Ordered catalog of all plans offered by a product (lowest to highest tier).
@immutable
final class ManaPlanCatalog {
  const ManaPlanCatalog({required this.tiers});

  final List<ManaPlanTier> tiers;

  /// Resolves a tier by [id], falling back to the first tier if unknown.
  ManaPlanTier tierById(String id) {
    for (final tier in tiers) {
      if (tier.id == id) return tier;
    }
    return tiers.first;
  }

  /// Finds the lowest tier in [tiers] that unlocks [capability].
  ManaPlanTier? requiredTierFor(String capability) {
    for (final tier in tiers) {
      if (tier.hasCapability(capability)) return tier;
    }
    return null;
  }

  /// Finds the lowest tier after [currentTierId] that raises or removes the
  /// quota cap for [metric].
  ManaPlanTier? nextTierForQuota(String metric, String currentTierId) {
    final currentIdx = tiers.indexWhere((t) => t.id == currentTierId);
    final currentLimit = currentIdx >= 0
        ? tiers[currentIdx].limitFor(metric)
        : null;
    if (currentLimit == null) return null;

    for (var i = currentIdx + 1; i < tiers.length; i++) {
      final candidateLimit = tiers[i].limitFor(metric);
      if (candidateLimit == null || candidateLimit > currentLimit) {
        return tiers[i];
      }
    }
    return null;
  }

  factory ManaPlanCatalog.fromJson(Map<String, dynamic> json) {
    final rawTiers = (json['tiers'] as List<dynamic>?) ?? const [];
    return ManaPlanCatalog(
      tiers: [
        for (final t in rawTiers)
          ManaPlanTier.fromJson(t as Map<String, dynamic>),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    'tiers': [for (final t in tiers) t.toJson()],
  };
}

/// Evaluated state of a single numeric quota metric (e.g. `active_customers`).
@immutable
final class ManaQuotaStatus {
  const ManaQuotaStatus({
    required this.metric,
    required this.used,
    required this.limit,
  });

  final String metric;
  final int used;

  /// Maximum allowed units, or `null` when unlimited.
  final int? limit;

  bool get isUnlimited => limit == null;

  int? get remaining =>
      limit == null ? null : (limit! - used).clamp(0, limit!);

  /// Normalized fill ratio (`0.0..1.0`). Always `0.0` when unlimited.
  double get ratio {
    if (limit == null || limit! <= 0) return 0.0;
    return (used / limit!).clamp(0.0, 1.0);
  }

  bool get isWarning => !isUnlimited && ratio >= 0.8 && !isExceeded;

  bool get isExceeded => limit != null && used >= limit!;

  /// Returns `true` if consuming [amount] more units fits within the quota.
  bool canConsume([int amount = 1]) {
    if (limit == null) return true;
    return used + amount <= limit!;
  }
}
