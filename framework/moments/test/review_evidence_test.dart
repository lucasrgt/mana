import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show uuidV4;
import 'package:moments/src/action_review_evidence.dart';
import 'package:moments/src/cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

Map<String, Object?> plan() => {
  'version': 1,
  'status': 'planned',
  'executed': false,
  'verification': 'not-performed',
  'target': {'resource': 'App.Task', 'action': 'complete'},
  'moments': [
    {'name': 'complete', 'coverage': 'unverified'},
    {'name': 'other', 'coverage': 'unverified'},
  ],
  'reviews': [
    {'id': 'authorization', 'status': 'pending'},
  ],
};

Map<String, Object?> journey() {
  final gesture = uuidV4();
  return {
    'version': 1,
    'id': uuidV4(),
    'name': 'complete',
    'operation': 'journey',
    'status': 'passed',
    'finalObservation': {'secret': 'DO NOT COPY'},
    'steps': [
      {'id': gesture, 'name': 'complete_task'},
    ],
    'actions': {
      'status': 'observed',
      'coverage': 'not-established',
      'overflow': false,
      'receipts': [
        {
          'version': 1,
          'gesture': gesture,
          'request': 'b' * 32,
          'step': 'complete_task',
          'truncated': false,
          'scope': 'request-actions-only',
          'coverage': 'not-established',
          'actions': [
            {'resource': 'App.Task', 'action': 'complete', 'kind': 'bulk_update', 'outcome': 'span-finished'},
          ],
        },
      ],
    },
  };
}

ReviewInput report([Map<String, Object?>? value]) => (value: value ?? journey(), sha256: 'a' * 64);
Map<String, Object?> actions(Map<String, Object?> value) => (value['actions']! as Map).cast();
Map firstReceipt(Map<String, Object?> value) => (actions(value)['receipts']! as List).first as Map;
List<Map> list(Map<String, Object?> value, String key) => (value[key]! as List).cast<Map>();

void main() {
  setUpAll(compileCli);

  test('positive bulk observation retains candidates, pending review and no current coverage claim', () {
    final input = plan(), r = report(), before = jsonEncode([input, r.value]);
    final value = reviewEvidence(input, [r]);
    expect(list(value, 'observations').first['kind'], 'bulk_update');
    expect(list(value, 'observations').first['step'], 'complete_task');
    expect(list(value, 'candidates').length, 2);
    expect(list(value, 'candidates')[1]['observation'], 'not-observed-in-supplied-reports');
    expect(value['verification'], 'not-performed');
    expect(value['coverage'], 'not-established');
    expect(value['applicability'], contains('historical-only'));
    expect(jsonEncode(value).contains('DO NOT COPY'), isFalse);
    expect(jsonEncode([input, r.value]), before);
  });

  test('failed, incomplete, legacy and non-domain evidence are not upgraded into passing coverage', () {
    final value = journey()
      ..['status'] = 'failed'
      ..['name'] = 'outside-domain';
    firstReceipt(value)['truncated'] = true;
    ((firstReceipt(value)['actions'] as List).first as Map)['outcome'] = 'error-reported';
    final result = reviewEvidence(plan(), [report(value)]);
    expect(list(result, 'observations').first['journeyStatus'], 'failed');
    expect(list(result, 'inputs').first['truncated'], true);
    expect(list(result, 'candidates').first['observation'], 'not-observed-in-supplied-reports');
    for (final capture in <Map<String, Object?>?>[
      null,
      {'status': 'unavailable'},
    ]) {
      final old = journey();
      if (capture == null) {
        old.remove('actions');
      } else {
        old['actions'] = capture;
      }
      final output = reviewEvidence(plan(), [report(old)]);
      expect(list(output, 'inputs').first['capture'], 'unavailable');
      expect(output['observations'], <Object?>[]);
    }
    final missing = journey()
      ..['actions'] = {
        'status': 'not-observed',
        'coverage': 'not-established',
        'overflow': false,
        'receipts': <Object?>[],
      };
    expect(list(reviewEvidence(plan(), [report(missing)]), 'inputs').first['capture'], 'not-observed');
  });

  test(
    'tampered associations, duplicate requests, unknown sensitive fields and contradictory captures are refused',
    () {
      for (final mutate in <void Function(Map<String, Object?> r)>[
        (r) => firstReceipt(r)['step'] = 'other',
        (r) => ((r['steps']! as List).first as Map)['id'] = uuidV4(),
        (r) => (actions(r)['receipts']! as List).add(firstReceipt(r)),
        (r) => firstReceipt(r)['actor'] = 'secret',
        (r) => ((firstReceipt(r)['actions'] as List).first as Map)['token'] = 'secret',
        (r) => (r['actions']! as Map)['status'] = 'not-observed',
        (r) => (r['steps']! as List).add((r['steps']! as List).first),
        (r) => (r['actions']! as Map)['coverage'] = 'verified',
        (r) => r['operation'] = 'check',
      ]) {
        final value = journey();
        mutate(value);
        expect(() => reviewEvidence(plan(), [report(value)]), throwsA(anything));
      }
    },
  );

  test('duplicate input is idempotent; conflicting run identities and excessive input are rejected', () {
    final r = report();
    expect(list(reviewEvidence(plan(), [r, r]), 'inputs').length, 1);
    expect(() => reviewEvidence(plan(), [r, (value: r.value, sha256: 'c' * 64)]), throwing('Conflicting'));
    expect(() => reviewEvidence(plan(), List.filled(33, r)), throwsA(anything));
  });

  test('CLI associates actual files without a project/runtime and never modifies the input plan', () async {
    final root = temporary('mana-review-');
    final planFile = p.join(root, 'plan.json'), evidence = p.join(root, 'report.json');
    writeJson(planFile, plan());
    writeJson(evidence, journey());
    final before = File(planFile).readAsStringSync();
    final run = await moments(['review', '--plan', planFile, '--evidence', evidence, '--json'], cwd: root);
    final result = (jsonDecode(run.stdout) as Map).cast<String, Object?>();
    expect((result['observations']! as List).length, 1);
    expect((result['plan']! as Map)['sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(File(planFile).readAsStringSync(), before);
    for (final args in [
      ['review'],
      ['review', '--plan', planFile],
      ['review', '--evidence', evidence],
      ['status', '--plan', planFile],
      ['review', '--plan', planFile, '--plan', planFile, '--evidence', evidence],
    ]) {
      expect(() => parseArgs(args), throwsA(anything), reason: '$args');
    }
  });

  test('file boundary rejects links, oversized payloads and malformed JSON without echoing their contents', () {
    final root = temporary('mana-review-files-');
    final planFile = p.join(root, 'plan'), evidence = p.join(root, 'report'), link = p.join(root, 'link');
    writeJson(planFile, plan());
    writeJson(evidence, journey());
    Link(link).createSync(evidence);
    expect(() => readReviewEvidence(planFile, [link]), throwing('readable JSON'));
    File(evidence).openSync(mode: FileMode.append)
      ..truncateSync(8 * 1024 * 1024 + 1)
      ..closeSync();
    expect(() => readReviewEvidence(planFile, [evidence]), throwing('readable JSON'));
    File(evidence).writeAsStringSync('PRIVATE_INVALID_CONTENT');
    expect(
      () => readReviewEvidence(planFile, [evidence]),
      throwsA(predicate((e) => !'$e'.contains('PRIVATE_INVALID_CONTENT'))),
    );
    expect(() => readReviewEvidence(planFile, []), throwing('between 1 and 32'));
  });

  test('navigation observations remain useful for review without becoming verified journeys', () {
    final value = journey()
      ..['operation'] = 'navigation'
      ..['status'] = 'captured';
    final result = reviewEvidence(plan(), [report(value)]);
    expect(list(result, 'observations').first['journeyStatus'], 'captured');
    expect(result['verification'], 'not-performed');
    value['status'] = 'passed';
    expect(() => reviewEvidence(plan(), [report(value)]), throwsA(anything));
  });
}
