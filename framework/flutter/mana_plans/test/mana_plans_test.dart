import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_plans/mana_plans.dart';

const _catalog = ManaPlanCatalog(
  tiers: [
    ManaPlanTier(
      id: 'free',
      name: 'Free',
      monthlyPrices: {'BRL': 0, 'USD': 0, 'EUR': 0},
      capabilities: {'mcp_read'},
      limits: {'active_customers': 10, 'monthly_reminders': 50},
    ),
    ManaPlanTier(
      id: 'pro',
      name: 'Pro',
      highlighted: true,
      monthlyPrices: {'BRL': 79, 'USD': 19, 'EUR': 17},
      capabilities: {
        'mcp_read',
        'mcp_write',
        'whatsapp_automation',
        'stripe_gateway',
      },
      limits: {'active_customers': 100, 'monthly_reminders': 1000},
    ),
    ManaPlanTier(
      id: 'scale',
      name: 'Scale',
      monthlyPrices: {'BRL': 199, 'USD': 49, 'EUR': 45},
      capabilities: {
        'mcp_read',
        'mcp_write',
        'whatsapp_automation',
        'stripe_gateway',
        'custom_domain',
      },
      limits: {'active_customers': -1, 'monthly_reminders': -1},
    ),
  ],
);

void main() {
  test('resolves capabilities, required tiers, and overrides cleanly', () {
    const free = ManaEntitlements(
      catalog: _catalog,
      planId: 'free',
      status: ManaPlanStatus.free,
      usage: {'active_customers': 8},
    );

    expect(free.can('mcp_read'), isTrue);
    expect(free.can('mcp_write'), isFalse);
    expect(free.requiredTierFor('mcp_write')?.id, 'pro');
    expect(free.requiredTierFor('custom_domain')?.id, 'scale');

    final granted = free.copyWith(overrideCapabilities: {'mcp_write'});
    expect(granted.can('mcp_write'), isTrue);

    final revoked = granted.copyWith(revokedCapabilities: {'mcp_write'});
    expect(revoked.can('mcp_write'), isFalse);
  });

  test('evaluates bounded, warning, exceeded, and unlimited quotas', () {
    const free = ManaEntitlements(
      catalog: _catalog,
      planId: 'free',
      status: ManaPlanStatus.free,
      usage: {'active_customers': 8, 'monthly_reminders': 50},
    );

    final customers = free.quota('active_customers');
    expect(customers.used, 8);
    expect(customers.limit, 10);
    expect(customers.remaining, 2);
    expect(customers.isWarning, isTrue);
    expect(customers.isExceeded, isFalse);
    expect(customers.canConsume(2), isTrue);
    expect(customers.canConsume(3), isFalse);

    final reminders = free.quota('monthly_reminders');
    expect(reminders.isExceeded, isTrue);
    expect(reminders.canConsume(), isFalse);
    expect(free.nextTierForQuota('monthly_reminders')?.id, 'pro');

    const scale = ManaEntitlements(
      catalog: _catalog,
      planId: 'scale',
      status: ManaPlanStatus.active,
      usage: {'active_customers': 5000},
    );
    expect(scale.quota('active_customers').isUnlimited, isTrue);
    expect(scale.canConsume('active_customers', 10000), isTrue);
  });

  test('serializes and parses Ash backend snapshots cleanly', () {
    final original = ManaEntitlements(
      catalog: _catalog,
      planId: 'pro',
      status: ManaPlanStatus.active,
      usage: const {'active_customers': 24, 'monthly_reminders': 142},
      overrideCapabilities: const {'custom_domain'},
      renewsAt: DateTime.utc(2026, 12, 10),
    );

    final snapshot = original.toSnapshot();
    final parsed = ManaEntitlements.fromSnapshot(snapshot, catalog: _catalog);

    expect(parsed, original);
    expect(parsed.can('mcp_write'), isTrue);
    expect(parsed.can('custom_domain'), isTrue);
    expect(parsed.quota('active_customers').remaining, 76);
  });

  testWidgets('ManaPlanScope, ManaCapabilityGate, and ManaQuotaGate work', (
    tester,
  ) async {
    const free = ManaEntitlements(
      catalog: _catalog,
      planId: 'free',
      status: ManaPlanStatus.free,
      usage: {'active_customers': 10},
    );

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ManaPlanScope(
          entitlements: free,
          child: Column(
            children: [
              ManaCapabilityGate(
                capability: 'mcp_write',
                allowed: (_) => const Text('unlocked'),
                locked: (_, tier) => Text('upgrade:${tier?.id}'),
              ),
              ManaQuotaGate(
                metric: 'active_customers',
                allowed: (_, q) => Text('ok:${q.remaining}'),
                exceeded: (_, q, next) => Text('full:${next?.id}'),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('upgrade:pro'), findsOneWidget);
    expect(find.text('full:pro'), findsOneWidget);
  });
}
