import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:live_ui/src/rendered_tree.dart';

class _Repeated extends StatelessWidget {
  const _Repeated();
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 80,
    height: 24,
    child: Text('private field value', textDirection: TextDirection.ltr),
  );
}

void main() {
  testWidgets('zero-height Row spacer retains its layout interval', (
    tester,
  ) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 10, height: 30),
              SizedBox(width: 8),
              SizedBox(width: 10, height: 30),
            ],
          ),
        ),
      ),
    );
    final nodes = RenderedTree().capture({'SizedBox'})['nodes'] as List;
    final gap = nodes.cast<Map>().singleWhere((n) => n['layoutOnly'] == true);
    expect(gap['inViewport'], true);
    expect(gap['bounds'], [10.0, 15.0, 8.0, 0.0]);
    expect(gap['visibleBounds'], [10.0, 0.0, 8.0, 30.0]);
  });
  testWidgets(
    'source locations distinguish repeated elements and omit private values',
    (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Repeated(),
                _Repeated(),
                Offstage(child: _Repeated()),
                Opacity(opacity: 0, child: _Repeated()),
              ],
            ),
          ),
        ),
      );
      final tree = RenderedTree();
      final report = tree.capture({'SizedBox'});
      expect(report['tracking'], true);
      final nodes = (report['nodes'] as List).cast<Map<String, Object?>>();
      final samples = nodes
          .where(
            (n) => (n['ancestors'] as List).any(
              (a) => (a as Map)['widget'] == '_Repeated',
            ),
          )
          .toList();
      expect(samples, hasLength(4));
      expect(samples.map((n) => n['id']).toSet(), hasLength(4));
      expect(
        samples.map((n) => n['location'].toString()).toSet(),
        hasLength(1),
      );
      expect(samples.where((n) => n['inViewport'] == true), hasLength(2));
      expect(report.toString(), isNot(contains('private field value')));
      final again = tree.capture({'SizedBox'});
      expect(
        (again['nodes'] as List).map((n) => (n as Map)['id']),
        nodes.map((n) => n['id']),
      );
    },
  );

  testWidgets(
    'viewport clipping excludes mounted items outside scroll window',
    (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 100,
              height: 30,
              child: SingleChildScrollView(
                child: Column(
                  children: [_Repeated(), _Repeated(), _Repeated()],
                ),
              ),
            ),
          ),
        ),
      );
      final report = RenderedTree().capture({'SizedBox'});
      final samples = (report['nodes'] as List)
          .cast<Map>()
          .where(
            (n) => (n['ancestors'] as List).any(
              (a) => (a as Map)['widget'] == '_Repeated',
            ),
          )
          .toList();
      expect(samples, hasLength(3));
      expect(samples.where((n) => n['inViewport'] == true), hasLength(2));
      expect(samples.last['reason'], 'clipped');
      expect((samples[1]['visibleBounds'] as List)[3], 6);
      expect(
        RenderedTree().capture({'SizedBox'}, maxVisited: 1)['truncated'],
        true,
      );
    },
  );
}
