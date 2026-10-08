import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

const _flow = ManaFlow(
  resource: 'host',
  cursor: 'lifecycle_state',
  done: 'complete',
  steps: [
    FlowStep(name: 'terms_pending', action: 'accept_terms'),
    FlowStep(name: 'basic_pending', action: 'save_basic'),
    FlowStep(name: 'address_pending', action: 'save_address'),
  ],
);

enum _Screen { terms, basic, phone, address }

const _screens = FlowScreens<_Screen>(_flow, [
  (_Screen.terms, 'terms_pending'),
  (_Screen.basic, 'basic_pending'),
  (_Screen.phone, null),
  (_Screen.address, 'address_pending'),
]);

void main() {
  test('a journey resumes at the cursor, or at an app check still owed', () {
    expect(_screens.resume(null), _Screen.terms);
    expect(_screens.resume('basic_pending'), _Screen.basic);
    expect(_screens.resume('address_pending'), _Screen.address);
    expect(
      _screens.resume(
        'address_pending',
        passed: (s) => s == _Screen.phone ? false : null,
      ),
      _Screen.phone,
    );
    expect(
      _screens.resume(
        'basic_pending',
        passed: (s) => switch (s) {
          _Screen.basic => true,
          _Screen.phone => false,
          _ => null,
        },
      ),
      _Screen.phone,
    );
    expect(_screens.resume('complete'), _Screen.address);
  });

  test('position, progress and back come from the order', () {
    expect(_screens.progress(_Screen.basic), 0.5);
    expect(_screens.previous(_Screen.phone), _Screen.basic);
    expect(_screens.previous(_Screen.terms), isNull);
    expect(_screens.next(_Screen.phone), _Screen.address);
  });
}
