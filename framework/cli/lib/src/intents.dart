import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'failure.dart';
import 'notebook.dart';
import 'sensors.dart';
import 'toolchain.dart';

/// What a person asked for, turned into situations they judge and criteria
/// that freeze before implementation (`intents/<id>.toml`):
///
/// ```toml
/// ask = "Hosts cancel without leaving the agenda"
/// feature = "bookings"
/// [[situation]]
/// moment = "hosts:host-cancel"
/// expect = "the booking leaves the agenda and the traveler is told"
/// [[criterion]]
/// id = "cancel-moment"
/// moment = "hosts:host-cancel"
/// [[criterion]]
/// id = "backend"
/// sensor = "backend-test"
/// ```
///
/// `approve` freezes the criteria (their hash goes to
/// `intents/<id>.approved.json`) and writes the decision to the notebook;
/// `check` refuses criteria edited after approval and runs each — a Moment
/// headless or a sensor — into one AVP verdict.
final class Intents {
  Intents(this.root);

  final String root;

  File _file(String id) => File(p.join(root, 'intents', '$id.toml'));
  File _approval(String id) =>
      File(p.join(root, 'intents', '$id.approved.json'));

  Map<String, Object?> read(String id) {
    final file = _file(id);
    if (!file.existsSync()) throw ManaFailure('No intent at intents/$id.toml');
    final data = TomlDocument.parse(file.readAsStringSync()).toMap();
    final criteria = ((data['criterion'] as List?) ?? const []).cast<Map>();
    if (data['ask'] is! String || criteria.isEmpty) {
      throw ManaFailure(
        'intents/$id.toml needs the ask and at least one [[criterion]]',
      );
    }
    for (final c in criteria) {
      if (c['id'] is! String ||
          ((c['moment'] is String) == (c['sensor'] is String))) {
        throw ManaFailure(
          'Each criterion of $id has an id and exactly one of moment = "app:name" or sensor = "<id>"',
        );
      }
    }
    final approval = _approval(id);
    return {
      'id': id,
      ...data,
      'status': approval.existsSync() ? 'approved' : 'proposed',
      'criteriaHash': _criteriaHash(criteria),
      if (approval.existsSync())
        'approved': jsonDecode(approval.readAsStringSync()),
    };
  }

  static String _criteriaHash(List<Map> criteria) => sha256Hex(
    utf8.encode(
      jsonEncode([
        for (final c in criteria)
          {'id': c['id'], 'moment': c['moment'], 'sensor': c['sensor']},
      ]),
    ),
  );

  List<Map<String, Object?>> list() {
    final dir = Directory(p.join(root, 'intents'));
    if (!dir.existsSync()) return [];
    return [
      for (final file
          in dir
              .listSync()
              .whereType<File>()
              .where((f) => f.path.endsWith('.toml'))
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
        read(p.basenameWithoutExtension(file.path)),
    ];
  }

  /// Freezes [id]'s criteria and records the decision in the notebook.
  Map<String, Object?> approve(String id, {required String by}) {
    final intent = read(id);
    if (intent['status'] == 'approved') {
      throw ManaFailure(
        '$id is already approved; propose a new intent to change it',
      );
    }
    final approval = {
      'at': DateTime.now().toUtc().toIso8601String(),
      'by': by,
      'criteriaHash': intent['criteriaHash'],
    };
    _approval(id).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(approval)}\n',
    );
    final about = [
      if (intent['feature'] is String) 'feature:${intent['feature']}',
      for (final c in (intent['criterion'] as List).cast<Map>())
        if (c['moment'] is String) 'moment:${c['moment']}',
    ];
    Notebook(root).add(
      why: 'Intent $id approved by $by: ${intent['ask']}',
      about: about.isEmpty ? ['feature:${intent['id']}'] : about,
      paths: ['intents/$id.toml'],
    );
    return {...intent, 'status': 'approved', 'approved': approval};
  }

  /// Runs [id]'s frozen criteria into an AVP verdict. [moment] runs one
  /// Moment headless and answers its exit code (0 passed, 1 failed, 2 could
  /// not decide).
  Future<Map<String, Object?>> check(
    String id, {
    required Future<int> Function(String app, String name) moment,
    void Function(String line)? progress,
  }) async {
    final intent = read(id);
    final approved = intent['approved'] as Map?;
    if (approved == null) {
      throw ManaFailure('$id is not approved yet; its criteria are not frozen');
    }
    if (approved['criteriaHash'] != intent['criteriaHash']) {
      throw ManaFailure(
        'The criteria of $id changed after approval; propose a new intent instead of editing a frozen one',
      );
    }
    final results = <Map<String, Object?>>[];
    final sensors = File(p.join(root, Sensors.file)).existsSync()
        ? Sensors.load(root)
        : null;
    for (final c in (intent['criterion'] as List).cast<Map>()) {
      String status;
      if (c['moment'] is String) {
        final [app, name] = (c['moment'] as String).split(':');
        progress?.call('… moment ${c['moment']}');
        final code = await moment(app, name);
        status = code == 0
            ? 'pass'
            : code == 1
            ? 'fail'
            : 'unresolved';
      } else {
        if (sensors == null) {
          throw const ManaFailure('A sensor criterion needs sensors.toml');
        }
        progress?.call('… sensor ${c['sensor']}');
        final verdict = await sensors.run([
          (sensors.named(c['sensor'] as String), 'intent $id'),
        ]);
        status =
            (verdict['results'] as List).cast<Map>().single['status'] as String;
      }
      results.add({
        'criterionId': c['id'],
        'status': status,
        if (c['moment'] is String) 'moment': c['moment'],
        if (c['sensor'] is String) 'sensor': c['sensor'],
      });
    }
    final passed = results.where((r) => r['status'] == 'pass').length;
    final failed = results.where((r) => r['status'] == 'fail').length;
    return {
      'protocol': 'avp',
      'subject': 'intent:$id',
      'results': results,
      'outcome': failed > 0
          ? 'fail'
          : passed == results.length
          ? 'pass'
          : 'inconclusive',
      'acceptanceScore': passed + failed == 0
          ? null
          : passed / (passed + failed),
    };
  }
}
