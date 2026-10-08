import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('verbs, views and attachments from the contract become client constants', () {
    final stage = Directory.systemTemp.createTempSync('mana-client-').path;
    addTearDown(() => Directory(stage).deleteSync(recursive: true));
    Directory(p.join(stage, 'lib/src')).createSync(recursive: true);
    File(
      p.join(stage, 'lib/shop_api.dart'),
    ).writeAsStringSync("export 'package:shop_api/src/api.dart';\n");
    File(
      p.join(stage, 'pubspec.yaml'),
    ).writeAsStringSync('name: shop_api\ndependencies:\n  dio: any\n');
    final output = p.join(p.dirname(stage), 'packages', 'shop_api');
    Directory(p.join(stage, 'lib/src/model')).createSync(recursive: true);
    File(
      p.join(stage, 'lib/src/model/order_line_attributes.dart'),
    ).writeAsStringSync("""
abstract class OrderLineAttributes {
  @BuiltValueField(wireName: r'total_cents')
  int get totalCents;

  @BuiltValueField(wireName: r'verbs')
  BuiltList<String>? get verbs;
}
""");

    writePrimitives(stage, 'shop_api', output, {
      'components': {
        'schemas': {
          'order_line': {
            'x-mana-verbs': [
              {
                'name': 'add',
                'action': 'add',
                'risk': 'none',
                'idempotent': false,
                'confirm': true,
                'collection': true,
                'from': 'order',
                'field': 'order_id',
              },
              {
                'name': 'apply_coupon',
                'action': 'apply_coupon',
                'risk': 'money',
                'idempotent': true,
                'retry': 2,
                'inverse': 'remove_coupon',
                'describe': r'Say "$5" off',
                'inputs': [
                  {
                    'name': 'code',
                    'required': true,
                    'type': 'string',
                    'max_length': 12,
                    'match': r'^[A-Z0-9$]+$',
                  },
                  {
                    'name': 'tags',
                    'required': false,
                    'type': 'array',
                    'items': {
                      'type': 'string',
                      'one_of': ['a', 'b'],
                    },
                  },
                  {
                    'name': 'percent',
                    'type': 'number',
                    'min': 0.5,
                    'max': 90,
                    'unique': true,
                  },
                ],
              },
              {
                'name': 'mark_seen',
                'action': 'mark_seen',
                'risk': 'none',
                'idempotent': true,
                'offline': 'queue',
              },
            ],
            'x-mana-views': [
              {
                'name': 'checkout_row',
                'fields': ['total_cents', 'verbs'],
                'live': true,
              },
            ],
          },
          'listing': {
            'x-mana-attachments': [
              {
                'attribute': 'cover_id',
                'many': false,
                'kinds': [
                  {
                    'name': 'photo',
                    'accept': ['image/png'],
                    'max_bytes': 1000,
                  },
                ],
              },
            ],
          },
          'signup': {
            'x-mana-flow': [
              {
                'cursor': 'stage',
                'done': 'done',
                'steps': [
                  {'name': 'terms', 'action': 'accept_terms'},
                  {
                    'name': 'address',
                    'action': 'save_address',
                    'optional': true,
                    'skippable': true,
                  },
                ],
              },
            ],
          },
          'shipment': {
            'x-mana-notifications': [
              {
                'action': 'ship',
                'template': 'shipment.sent',
                'category': 'orders',
                'channels': ['inbox', 'email'],
                'opens': '/orders?shipment=:id',
              },
              {
                'action': 'ship',
                'template': 'shipment.sent_seller',
                'category': 'orders',
                'channels': ['inbox'],
              },
            ],
          },
          'task': {
            'x-mana-history': [
              {
                'log': 'history_entry',
                'subject': 'task',
                'redacted': ['secret'],
              },
            ],
            'x-mana-entity': [
              {
                'topic': 'task',
                'audience': ['owner_id'],
                'deadlines': ['expire'],
              },
            ],
          },
          'plain': {'type': 'object'},
        },
      },
    });

    final generated = File(
      p.join(stage, 'lib/src/primitives.dart'),
    ).readAsStringSync();
    expect(generated, contains('abstract class OrderLineVerbs {'));
    expect(generated, contains('class OrderLineCheckoutRowView {'));
    expect(
      generated,
      contains('  int get totalCents => _attributes.totalCents;'),
    );
    expect(
      generated,
      contains('  BuiltList<String>? get verbs => _attributes.verbs;'),
    );
    expect(generated, contains("import 'package:shop_api/shop_api.dart';"));
    expect(
      generated,
      contains(
        'static const add = ManaVerb(resource: "order_line", name: "add", action: "add", risk: VerbRisk.none, idempotent: false, confirm: true, collection: true, from: "order"',
      ),
    );
    expect(
      generated,
      contains(
        r'static const applyCoupon = ManaVerb(resource: "order_line", name: "apply_coupon"',
      ),
    );
    expect(
      generated,
      contains(
        r'risk: VerbRisk.money, idempotent: true, retry: 2, inverse: "remove_coupon", describe: "Say \"\$5\" off"',
      ),
    );
    expect(
      generated,
      contains(
        r'inputs: [VerbInput(name: "code", type: "string", required: true, maxLength: 12, match: "^[A-Z0-9\$]+\$"), '
        r'VerbInput(name: "tags", type: "array", items: VerbInput(name: "tags", type: "string", oneOf: ["a", "b"])), '
        r'VerbInput(name: "percent", type: "number", min: 0.5, max: 90, unique: true)]);',
      ),
    );
    expect(
      generated,
      contains('static const all = <ManaVerb>[add, applyCoupon, markSeen];'),
    );
    expect(
      generated,
      contains(
        'static const checkoutRow = ManaView(resource: "order_line", name: "checkout_row", fields: ["total_cents", "verbs"], live: true);',
      ),
    );
    expect(
      generated,
      contains(
        'static const coverId = ManaAttachment(resource: "listing", attribute: "cover_id", many: false, kinds: [AttachmentKind(name: "photo", accept: ["image/png"], maxBytes: 1000)]);',
      ),
    );
    expect(
      generated,
      contains('idempotent: true, offline: VerbOffline.queue);'),
    );
    expect(
      generated,
      contains(
        'static const ship = ManaNotification(resource: "shipment", action: "ship", template: "shipment.sent", category: "orders", channels: ["inbox", "email"], opens: "/orders?shipment=:id");',
      ),
    );
    expect(
      generated,
      contains('static const all = <ManaNotification>[ship, ship2];'),
    );
    expect(
      generated,
      contains(
        'static const flow = ManaFlow(resource: "signup", cursor: "stage", done: "done", steps: [FlowStep(name: "terms", action: "accept_terms"), FlowStep(name: "address", action: "save_address", optional: true, skippable: true)]);',
      ),
    );
    expect(
      generated,
      contains(
        'static const history = ManaHistory(resource: "task", log: "history_entry", redacted: ["secret"]);',
      ),
    );
    expect(
      generated,
      contains(
        'static const entity = ManaEntity(resource: "task", topic: "task", audience: ["owner_id"], deadlines: ["expire"]);',
      ),
    );
    expect(
      generated.indexOf('class ListingAttachments'),
      lessThan(generated.indexOf('class OrderLineVerbs')),
    );
    expect(
      File(p.join(stage, 'lib/shop_api.dart')).readAsStringSync(),
      endsWith("export 'package:shop_api/src/primitives.dart';\n"),
    );
    expect(
      File(p.join(stage, 'pubspec.yaml')).readAsStringSync(),
      contains('  mana_primitives:\n    path: '),
    );
  });

  test('a primitive with no client writer stops generation', () {
    expect(
      () => writePrimitives('unused', 'shop_api', 'unused', {
        'components': {
          'schemas': {
            'order': {
              'x-mana-unknown': [<String, Object>{}],
            },
          },
        },
      }),
      throwsA(
        isA<ManaFailure>().having(
          (f) => f.message,
          'message',
          contains('x-mana-unknown on order'),
        ),
      ),
    );
  });

  test('a contract without primitives is left untouched', () {
    final stage = Directory.systemTemp.createTempSync('mana-client-').path;
    addTearDown(() => Directory(stage).deleteSync(recursive: true));
    writePrimitives(stage, 'shop_api', stage, {
      'components': {'schemas': {}},
    });
    expect(
      File(p.join(stage, 'lib/src/primitives.dart')).existsSync(),
      isFalse,
    );
  });

  test('a listed primitive needs a client writer and a catalog entry', () {
    Map contract(List<Map> primitives) => {
      'info': {'x-mana-primitives': primitives},
    };
    expect(
      primitiveGaps(
        contract([
          {'contract': 'x-mana-verbs', 'catalog': 'verbs'},
        ]),
        {'verbs'},
      ),
      isEmpty,
    );
    expect(
      primitiveGaps(
        contract([
          {'contract': 'x-mana-unknown', 'catalog': 'unknown'},
        ]),
        {'verbs'},
      ),
      [
        'x-mana-unknown has no client writer',
        'x-mana-unknown names catalog id unknown, which framework/catalog.toml lacks',
      ],
    );
    expect(primitiveGaps({}, const {}), isEmpty);
  });
}
