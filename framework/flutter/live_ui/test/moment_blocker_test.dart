import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/live_ui.dart';

void main() {
  testWidgets('an application gate prevents frame evidence until it clears', (
    tester,
  ) async {
    final controller = MomentController(navigate: (_) {});
    controller.restore('one', {
      'name': 'inbox',
      'projection': {'route': '/inbox'},
    });
    final reader = Object();
    controller.registerFrameReader(
      reader,
      () => {'route': '/inbox', 'value': 'live'},
    );
    Widget screen(MomentBlockReason? reason) => MomentScope(
      controller: controller,
      child: MomentRuntimeBlocker(reason: reason, child: const SizedBox()),
    );
    await tester.pumpWidget(screen(MomentBlockReason.authenticationRequired));
    final blocked = expectLater(
      controller.readFrame('one'),
      throwsA(
        isA<MomentRuntimeBlocked>().having(
          (e) => e.reason,
          'reason',
          MomentBlockReason.authenticationRequired,
        ),
      ),
    );
    await tester.pump();
    await blocked;
    await tester.pumpWidget(screen(null));
    final frame = controller.readFrame('one');
    await tester.pump();
    expect((await frame)['value'], 'live');
    await tester.pumpWidget(screen(MomentBlockReason.sessionUnavailable));
    await tester.pumpWidget(const SizedBox());
    final afterDispose = controller.readFrame('one');
    await tester.pump();
    expect((await afterDispose)['value'], 'live');
    controller.dispose();
  });
}
