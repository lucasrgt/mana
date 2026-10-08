import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One recorded call of a `defexample` function (`Mana.Examples`).
typedef LiveExample = ({
  String function,
  String gesture,
  String at,
  List<String> args,
  String result,
});

/// The gesture → Moment names the suite reports under [root] know.
Map<String, String> gestureMoments(String root) {
  final names = <String, String>{};
  final apps = Directory(p.join(root, 'apps'));
  if (!apps.existsSync()) return names;
  for (final app in apps.listSync().whereType<Directory>()) {
    final suites = Directory(p.join(app.path, 'moments/.suite'));
    if (!suites.existsSync()) continue;
    for (final run in suites.listSync().whereType<Directory>()) {
      final summary = File(p.join(run.path, 'summary.json'));
      if (!summary.existsSync()) continue;
      try {
        final results =
            (jsonDecode(summary.readAsStringSync()) as Map)['results'] as List;
        for (final result in results.cast<Map>()) {
          final report = File('${result['report']}');
          if (!report.existsSync()) continue;
          final actions =
              (jsonDecode(report.readAsStringSync()) as Map)['actions'] as Map?;
          for (final receipt
              in (actions?['receipts'] as List?)?.cast<Map>() ??
                  const <Map>[]) {
            names['${receipt['gesture']}'] =
                '${p.basename(app.path)}:${result['name']}';
          }
        }
      } on FormatException {
        continue;
      }
    }
  }
  return names;
}

/// The recorded examples of [function] (or of every marked function), read
/// from `<root>/.mana/examples`, grouped per Moment, newest first, each with
/// whether its result differs from the previous call in the same Moment.
Map<String, Object?> liveExamples(String root, {String? function}) {
  final dir = Directory(p.join(root, '.mana/examples'));
  final moments = gestureMoments(root);
  final functions = <String, Object?>{};
  if (dir.existsSync()) {
    for (final file in dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.jsonl'),
    )) {
      final calls = <LiveExample>[];
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final value = jsonDecode(line) as Map;
          calls.add((
            function: '${value['function']}',
            gesture: '${value['gesture']}',
            at: '${value['at']}',
            args: (value['args'] as List).cast<String>(),
            result: '${value['result']}',
          ));
        } on Object {
          continue;
        }
      }
      if (calls.isEmpty) continue;
      final name = calls.first.function;
      if (function != null && !name.contains(function)) continue;
      final byMoment = <String, List<LiveExample>>{};
      for (final call in calls) {
        (byMoment[moments[call.gesture] ?? 'gesture:${call.gesture}'] ??= [])
            .add(call);
      }
      functions[name] = [
        for (final MapEntry(key: moment, value: list) in byMoment.entries)
          {
            'moment': moment,
            'calls': list.length,
            'args': list.last.args,
            'result': list.last.result,
            'at': list.last.at,
            if (list.length > 1 &&
                _stable(list[list.length - 2].result) !=
                    _stable(list.last.result))
              'previous': list[list.length - 2].result,
          },
      ]..sort((a, b) => '${b['at']}'.compareTo('${a['at']}'));
    }
  }
  return {'directory': dir.path, 'functions': functions};
}

final _uuid = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
);

/// A result without the ids and timestamps each run's fresh records bring.
String _stable(String result) => result
    .replaceAll(_uuid, '<id>')
    .replaceAll(RegExp(r'~U\[[^\]]*\]'), '<time>');
