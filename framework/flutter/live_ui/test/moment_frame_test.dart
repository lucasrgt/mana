import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  testWidgets(
    'post-frame observation reads live state without restoring or navigating',
    (tester) async {
      var navigations = 0, restores = 0;
      var filter = 'all';
      final controller = MomentController(navigate: (_) => navigations++);
      final scroll = ScrollController();
      final binding = MomentViewBinding(
        route: '/inbox',
        scroll: scroll,
        read: () => {'filter': filter},
        restore: (_) {
          restores++;
        },
      );
      controller.restore('one', {
        'name': 'inbox',
        'projection': {'route': '/inbox', 'filter': 'all', 'scrollOffset': 0},
      });
      Widget screen(bool ready) => MomentScope(
        controller: controller,
        child: Builder(
          builder: (context) {
            binding.attach(context, ready: ready);
            return const SizedBox();
          },
        ),
      );
      await tester.pumpWidget(screen(true));
      await tester.pumpAndSettle();
      expect(restores, 1);
      var finished = false;
      final pending = controller.readFrame('one').then((value) {
        finished = true;
        return value;
      });
      expect(finished, false);
      filter = 'reservation';
      await tester.pump();
      expect((await pending)['filter'], 'reservation');
      expect(restores, 1);
      expect(navigations, 1);
      await tester.pumpWidget(screen(false));
      final unready = expectLater(
        controller.readFrame('one'),
        throwsStateError,
      );
      await tester.pump();
      await unready;
      binding.dispose();
      final missing = expectLater(
        controller.readFrame('one'),
        throwsStateError,
      );
      await tester.pump();
      await missing;
      controller.dispose();
      scroll.dispose();
    },
  );

  testWidgets(
    'ambiguous and stale frame readers never acknowledge a projection',
    (tester) async {
      final controller = MomentController(navigate: (_) {});
      controller.restore('one', {
        'name': 'inbox',
        'projection': {'route': '/inbox'},
      });
      final first = Object(), second = Object();
      controller.registerFrameReader(first, () => {'route': '/inbox'});
      controller.registerFrameReader(second, () => {'route': '/inbox'});
      final ambiguous = expectLater(
        controller.readFrame('one'),
        throwsStateError,
      );
      await tester.pump();
      await ambiguous;
      controller.removeFrameReader(second);
      final stale = expectLater(controller.readFrame('one'), throwsStateError);
      controller.restore('two', {
        'name': 'inbox',
        'projection': {'route': '/inbox'},
      });
      await tester.pump();
      await stale;
      controller.dispose();
    },
  );
}
