import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('screens name the verbs their generated classes reach', () {
    final root = Directory.systemTemp.createTempSync('mana-graph');
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'app/lib/booking/view.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
VerbGate(verb: BookingVerbs.acceptProposal, offered: b.verbs);
runVerb(context, BookingVerbs.cancel, offered: b.verbs);
final all = BookingVerbs.all;
''');
    File(p.join(root.path, 'app/lib/api.g.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('BookingVerbs.generatedOnly');
    File(p.join(root.path, 'admin/lib/main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('HostPlanVerbs.cancel; BookingVerbs.cancel;');

    expect(screenVerbs(root.path, ['app', 'admin', 'missing']), {
      'booking.accept_proposal': ['app/lib/booking/view.dart'],
      'booking.cancel': ['admin/lib/main.dart', 'app/lib/booking/view.dart'],
      'host_plan.cancel': ['admin/lib/main.dart'],
    });
  });
}
