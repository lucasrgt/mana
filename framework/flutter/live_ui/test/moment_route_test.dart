import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/src/moments.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a flow navigates directly to its saved destination without visiting its scope route', () {
    final visits = <String>[];
    final controller = MomentController(
      navigate: visits.add,
      resolveRoute: (projection) => projection['destination'] as String,
    );
    addTearDown(controller.dispose);
    controller.restore('one', {
      'name': 'recovery',
      'projection': {'route': '/sign-in', 'destination': '/reset-password'},
    });
    expect(visits, ['/reset-password']);
    expect(controller.projection!['route'], '/sign-in');
    controller.restore('two', {
      'name': 'recovery',
      'projection': {'route': '/sign-in', 'destination': '/tasks'},
    });
    expect(visits, ['/reset-password', '/tasks']);
  });
  test(
    'invalid navigation does not commit a revision or call the navigator',
    () {
      final visits = <String>[];
      final controller = MomentController(navigate: visits.add);
      addTearDown(controller.dispose);
      expect(
        () => controller.restore('one', {
          'projection': {'route': '//other.example'},
        }),
        throwsStateError,
      );
      expect(visits, isEmpty);
      expect(controller.revision, '');
      controller.restore('one', {
        'projection': {'route': '/tasks'},
      });
      expect(visits, ['/tasks']);
      controller.restore('one', {
        'projection': {'route': '/tasks'},
      });
      expect(visits, ['/tasks']);
    },
  );
}
