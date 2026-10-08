import 'package:assay_flutter/assay_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

const archive = ManaVerb(resource: 'task', name: 'archive', action: 'archive');

Widget gate(
  AssayBackend backend, {
  Iterable<String> offered = const ['archive'],
}) => Directionality(
  textDirection: TextDirection.ltr,
  child: VerbGate(
    verb: archive,
    offered: offered,
    run: () => backend.call('archive', () {}),
    hideWhenNotOffered: false,
    builder: (context, onPressed) => GestureDetector(
      key: const Key('archive'),
      onTap: onPressed,
      child: const Text('Archive'),
    ),
  ),
);

void main() {
  testWidgets('a verb button performs its effect once per activation', (
    tester,
  ) async {
    final verdict = await runVerification(
      WidgetActionEffect(),
      'VerbGate.archive',
      WidgetActionSubject(
        tester: tester,
        build: gate,
        action: find.byKey(const Key('archive')),
        effect: 'archive',
      ),
    );
    expect(verdict.of('fires-primary-effect'), VerdictStatus.pass);
    expect(verdict.of('single-flight'), VerdictStatus.pass);
  });

  testWidgets('a verb the record does not offer cannot perform it', (
    tester,
  ) async {
    final verdict = await runVerification(
      WidgetLifecycleGate(),
      'VerbGate.archive',
      WidgetGateSubject(
        tester: tester,
        build: (backend) => gate(backend, offered: const []),
        action: find.byKey(const Key('archive')),
        effect: 'archive',
      ),
    );
    expect(verdict.of('blocked-action-is-disabled'), VerdictStatus.pass);
  });
}
