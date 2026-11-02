import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('the keys VerbGates place map to their verbs', () {
    final root = Directory.systemTemp.createTempSync('mana-upgrade');
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'app/lib/booking/view.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
Widget pay(Booking b) => VerbGate(
  verb: BookingVerbs.pay,
  offered: b.verbs,
  builder: (context, onPressed) => AppButton(
    key: const Key('booking-pay'),
    onPressed: onPressed,
    child: const Text('Pay', key: Key('label')),
  ),
);

Widget cancel(Booking b) => const VerbGate(
  key: ValueKey<String>('booking-cancel'),
  verb: BookingVerbs.cancel,
  offered: [],
  builder: _cancel,
);

Widget accept(Booking b) => VerbGate(
  verb: BookingVerbs.acceptProposal,
  offered: b.verbs,
  builder: (context, onPressed) {
    final row = Row(key: const Key('inner'));
    return b.urgent
        ? FilledButton(key: const Key('booking-accept-now'), onPressed: onPressed)
        : TextButton(key: const Key('booking-accept'), onPressed: onPressed);
  },
);

Widget either(Booking b, ManaVerb verb) => VerbGate(
  verb: verb,
  offered: b.verbs,
  builder: (context, onPressed) => AppButton(key: const Key('booking-either')),
);

Widget shared(Booking b) => VerbGate(
  verb: BookingVerbs.pay,
  offered: b.verbs,
  builder: (context, onPressed) => AppButton(key: Key('booking-\${b.id}')),
);
''');
    File(p.join(root.path, 'admin/lib/main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
final a = VerbGate(
  verb: HostPlanVerbs.cancel,
  builder: (context, onPressed) => AppButton(key: const Key('booking-cancel')),
);
final b = AppButton(key: const Key('booking-pay'));
''');
    File(p.join(root.path, 'app/lib/api.g.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        "final g = VerbGate(verb: GVerbs.x, key: Key('generated'));",
      );

    expect(verbKeys(root.path, ['app', 'admin']), {
      'version': 1,
      'keys': {
        'booking-accept': 'booking.accept_proposal',
        'booking-accept-now': 'booking.accept_proposal',
        'booking-pay': 'booking.pay',
      },
      'conflicts': {
        'booking-cancel': ['booking.cancel', 'host_plan.cancel'],
        'booking-either': ['a verb chosen at runtime'],
      },
    });
  });

  test('mix runs in the framework package with paths relative to it', () {
    expect(
      upgradeArguments(
        project: '/w/mana/framework/ash/upgrade',
        codemod: 'verb_steps',
        paths: ['/w/backend/lib'],
        mapping: '/w/backend/_build/mana-verb-steps.json',
        dryRun: true,
      ),
      [
        'mana.upgrade',
        'verb_steps',
        '../../../../backend/lib',
        '--mapping',
        '../../../../backend/_build/mana-verb-steps.json',
        '--dry-run',
      ],
    );
  });
}
