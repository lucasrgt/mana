import 'dart:convert';
import 'dart:io';

import 'package:moments/src/verdict.dart';
import 'package:test/test.dart';

// The LiveView runner (ManaWeb.Moments.Verdict) is held to the same cases.
void main() {
  final cases = (jsonDecode(File('../contracts/moments/avp-verdicts.json').readAsStringSync()) as List)
      .cast<Map<String, Object?>>();

  for (final c in cases) {
    test('AVP verdict: ${c['case']}', () {
      final verdict = avpVerdict(
        subject: c['subject']! as String,
        status: c['status']! as String,
        checks: (c['checks']! as List).cast<Map<String, Object?>>(),
        reason: c['reason'] as String?,
      );
      expect(jsonDecode(jsonEncode(verdict)), c['verdict']);
    });
  }
}
