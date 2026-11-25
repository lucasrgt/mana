# mana_plans

Declarative plans, capabilities, and usage quotas for Flutter apps built with [Mana](https://github.com/lucasrgt/mana).

Declare your product tiers once in a `ManaPlanCatalog`, bind the workspace's active subscription & live usage via `ManaPlanScope`, and gate features or quotas anywhere in the widget tree without duplicating plan checks across screens.

## Quick start

```dart
const catalog = ManaPlanCatalog(
  tiers: [
    ManaPlanTier(
      id: 'free',
      name: 'Free',
      monthlyPrices: {'BRL': 0, 'USD': 0},
      capabilities: {'mcp_read'},
      limits: {'active_customers': 10, 'monthly_reminders': 50},
    ),
    ManaPlanTier(
      id: 'pro',
      name: 'Pro',
      highlighted: true,
      monthlyPrices: {'BRL': 79, 'USD': 19},
      capabilities: {'mcp_read', 'mcp_write', 'whatsapp_automation'},
      limits: {'active_customers': 100, 'monthly_reminders': 1000},
    ),
  ],
);
```

Wrap your app with `ManaPlanScope(entitlements: ..., child: ...)` and query anywhere:

```dart
final plans = ManaPlans.of(context);
if (plans.can('mcp_write')) {
  // Unlocked on current tier
}
final customers = plans.quota('active_customers');
if (!customers.canConsume()) {
  // Show upgrade prompt targeting plans.nextTierForQuota('active_customers')
}
```
