import 'package:moments/src/verdict.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> check(String name, String status, {Object? expected, Object? observed}) => {
    'name': name,
    'status': status,
    'field': 'phase',
    'expected': ?expected,
    'observed': ?observed,
  };

  test('all criteria passing is a pass with full score', () {
    final v = avpVerdict(subject: 'root', status: 'passed', checks: [check('a', 'passed'), check('b', 'passed')]);
    expect(v['outcome'], 'pass');
    expect(v['acceptanceScore'], 1.0);
    expect(v['archetype'], 'moment-criteria');
    expect(v['protocolVersion'], avpProtocolVersion);
  });

  test('a failing criterion fails the verdict with an actionable reason and evidence', () {
    final v = avpVerdict(
      subject: 'root',
      status: 'failed',
      checks: [
        check('a', 'passed'),
        check('b', 'failed', expected: 'paid', observed: 'open'),
      ],
    );
    expect(v['outcome'], 'fail');
    expect(v['acceptanceScore'], 0.5);
    final failed = (v['results']! as List).cast<Map>().last;
    expect(failed['reason'], 'phase: expected paid, observed open');
    expect(failed['evidence'], {'field': 'phase', 'expected': 'paid', 'observed': 'open'});
  });

  test('unavailable evidence is unresolved and never green', () {
    final v = avpVerdict(
      subject: 'root',
      status: 'unavailable',
      checks: [check('a', 'passed')],
      reason: 'Ownership could not be released',
    );
    expect(v['outcome'], 'inconclusive');
    expect((v['results']! as List).cast<Map>().last, {
      'criterionId': 'moment-observation',
      'status': 'unresolved',
      'reason': 'Ownership could not be released',
    });
  });

  test('a failed run without a failing criterion still fails', () {
    final v = avpVerdict(subject: 'root', status: 'failed', checks: const [], reason: 'Step tap did not land');
    expect(v['outcome'], 'fail');
    expect(v['acceptanceScore'], 0.0);
  });

  test('nothing decided is inconclusive with a null score', () {
    final v = avpVerdict(subject: 'root', status: 'unavailable', checks: const []);
    expect(v['outcome'], 'inconclusive');
    expect(v['acceptanceScore'], isNull);
  });
}
