import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'failure.dart';
import 'features.dart';

/// What a sensor proves, so an agent can pick a visual signal for a colour
/// change rather than a logic test.
const proofKinds = [
  'structure',
  'logic',
  'types',
  'visual',
  'behavior',
  'performance',
  'security',
  'accessibility',
];

typedef Sensor = ({
  String id,
  List<String> run,
  String cwd,
  String proves,
  List<String> covers,
  Duration cost,
  List<String> requires,
  Map<String, String> env,
  bool sideEffects,
  bool gate,
  String output,
});

Duration parseCost(String text) {
  final match = RegExp(r'^(\d+)(s|m|h)$').firstMatch(text.trim());
  if (match == null) {
    throw ManaFailure('Invalid sensor cost: $text (use 2s, 5m, 1h)');
  }
  final value = int.parse(match[1]!);
  return switch (match[2]) {
    's' => Duration(seconds: value),
    'm' => Duration(minutes: value),
    _ => Duration(hours: value),
  };
}

String formatCost(Duration cost) =>
    cost.inMinutes >= 1 && cost.inSeconds % 60 == 0
    ? '${cost.inMinutes}m'
    : '${cost.inSeconds}s';

/// The project's verification signals (`sensors.toml`): addressed, with what
/// they cover, cost and prove. `selectFor` picks the sensors a change needs.
final class Sensors {
  Sensors._(this.root, this.sensors);

  final String root;
  final List<Sensor> sensors;

  static const file = 'sensors.toml';

  static Sensors load(String root) {
    final Map<String, Object?> data;
    try {
      data = TomlDocument.parse(
        File(p.join(root, file)).readAsStringSync(),
      ).toMap();
    } on TomlException catch (error) {
      throw ManaFailure('Invalid $file: $error');
    } on FileSystemException {
      throw ManaFailure('Missing $file: declare the project sensors first');
    }
    if (data['version'] != 1) {
      throw const ManaFailure('Unsupported sensors.toml version');
    }
    final declared = data['sensor'];
    if (declared is! Map || declared.isEmpty) {
      throw const ManaFailure('sensors.toml declares no sensor');
    }
    List<String> strings(Object? value, String where) {
      if (value is! List || value.any((v) => v is! String)) {
        throw ManaFailure('$where must be a list of strings');
      }
      return value.cast<String>();
    }

    final sensors = <Sensor>[];
    for (final MapEntry(:key, :value) in declared.entries) {
      final id = key as String;
      if (value is! Map) throw ManaFailure('sensor.$id must be a table');
      if (!RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(id)) {
        throw ManaFailure('Invalid sensor id: $id');
      }
      final run = strings(value['run'], 'sensor.$id.run');
      if (run.isEmpty) throw ManaFailure('sensor.$id.run is empty');
      final proves = value['proves'];
      if (!proofKinds.contains(proves)) {
        throw ManaFailure(
          'sensor.$id.proves must be one of ${proofKinds.join(', ')}',
        );
      }
      final covers = strings(value['covers'], 'sensor.$id.covers');
      for (final cover in covers) {
        if (cover.startsWith('feature:') || cover.startsWith('moment:')) {
          continue;
        }
        globPattern(cover);
      }
      final output = (value['output'] ?? 'exit') as String;
      if (!const ['exit', 'moments'].contains(output)) {
        throw ManaFailure('sensor.$id.output must be exit or moments');
      }
      sensors.add((
        id: id,
        run: run,
        cwd: (value['cwd'] ?? '.') as String,
        proves: proves! as String,
        covers: covers,
        cost: parseCost((value['cost'] ?? '') as String),
        requires: strings(
          value['requires'] ?? const <String>[],
          'sensor.$id.requires',
        ),
        env: switch (value['env']) {
          null => const <String, String>{},
          final Map env when env.values.every((v) => v is String) =>
            env.cast<String, String>(),
          _ => throw ManaFailure('sensor.$id.env must map names to strings'),
        },
        sideEffects: (value['side_effects'] ?? false) as bool,
        gate: (value['gate'] ?? true) as bool,
        output: output,
      ));
    }
    final learned = _readLock(root);
    final measured = [
      for (final s in sensors)
        if (learned[s.id] case {
          'runs': final int runs,
          'medianMs': final int median,
        } when runs >= 3)
          (
            id: s.id,
            run: s.run,
            cwd: s.cwd,
            proves: s.proves,
            covers: s.covers,
            cost: Duration(milliseconds: median),
            requires: s.requires,
            env: s.env,
            sideEffects: s.sideEffects,
            gate: s.gate,
            output: s.output,
          )
        else
          s,
    ]..sort((a, b) => a.cost.compareTo(b.cost));
    return Sensors._(root, measured)..learned = learned;
  }

  static const lockFile = 'sensors.lock';

  /// What `mana sense learn` measured per sensor (empty without a lock).
  Map<String, Map<String, Object?>> learned = const {};

  static Map<String, Map<String, Object?>> _readLock(String root) {
    final lock = File(p.join(root, lockFile));
    if (!lock.existsSync()) return const {};
    try {
      final sensors =
          (jsonDecode(lock.readAsStringSync()) as Map)['sensors'] as Map;
      return {
        for (final MapEntry(:key, :value) in sensors.entries)
          key as String: (value as Map).cast<String, Object?>(),
      };
    } on Object {
      return const {};
    }
  }

  /// Measures every sensor from the runs kept in `.mana/sense`: how long it
  /// really takes (median, p95), how often it fails, how often a failure was
  /// flaky (it passed again at the same commit with the same change), what it
  /// catches per minute spent, and which changed files its failures came
  /// with. Writes `sensors.lock`, which ordering and budgets then use instead
  /// of the declared cost once a sensor has three runs.
  static Map<String, Object?> learn(String root) {
    final runs = Directory(p.join(root, '.mana/sense'));
    final stats =
        <
          String,
          List<({int ms, String status, String key, List<String> paths})>
        >{};
    if (runs.existsSync()) {
      for (final run
          in runs.listSync().whereType<Directory>().toList()
            ..sort((a, b) => a.path.compareTo(b.path))) {
        final verdict = File(p.join(run.path, 'verdict.json'));
        if (!verdict.existsSync()) continue;
        try {
          final meta = File(p.join(run.path, 'run.json'));
          final info = meta.existsSync()
              ? jsonDecode(meta.readAsStringSync()) as Map
              : const {};
          final paths = ((info['paths'] as List?) ?? const []).cast<String>();
          final key = '${info['commit']}|${paths.join(',')}';
          for (final result
              in ((jsonDecode(verdict.readAsStringSync()) as Map)['results']
                      as List)
                  .cast<Map>()) {
            final ms = (result['evidence'] as Map?)?['durationMs'];
            if (ms is! int) continue;
            (stats['${result['criterionId']}'] ??= []).add((
              ms: ms,
              status: '${result['status']}',
              key: key,
              paths: paths,
            ));
          }
        } on Object {
          continue;
        }
      }
    }
    int percentile(List<int> sorted, double q) =>
        sorted[((sorted.length - 1) * q).round()];
    final declared = File(p.join(root, file)).existsSync()
        ? {for (final s in load(root).sensors) s.id}
        : null;
    final sensors = <String, Object?>{};
    for (final MapEntry(key: id, value: list) in stats.entries) {
      if (declared != null && !declared.contains(id)) continue;
      final durations = [for (final r in list) r.ms]..sort();
      final fails = list.where((r) => r.status == 'fail').toList();
      var flaky = 0;
      for (var i = 0; i < list.length; i++) {
        if (list[i].status != 'fail') continue;
        if (list
            .skip(i + 1)
            .any(
              (later) => later.key == list[i].key && later.status == 'pass',
            )) {
          flaky++;
        }
      }
      final minutes = durations.fold<int>(0, (a, b) => a + b) / 60000;
      final impact = <String, int>{};
      for (final failure in fails) {
        for (final path in failure.paths) {
          impact[path] = (impact[path] ?? 0) + 1;
        }
      }
      sensors[id] = {
        'runs': list.length,
        'medianMs': percentile(durations, 0.5),
        'p95Ms': percentile(durations, 0.95),
        'failRate': double.parse(
          (fails.length / list.length).toStringAsFixed(3),
        ),
        'flakyRate': double.parse((flaky / list.length).toStringAsFixed(3)),
        'catchesPerMinute': minutes == 0
            ? 0.0
            : double.parse(
                ((fails.length - flaky) / minutes).toStringAsFixed(3),
              ),
        'failsWith':
            (impact.entries.toList()
                  ..sort((a, b) => b.value.compareTo(a.value)))
                .take(10)
                .map((e) => e.key)
                .toList(),
      };
    }
    final lock = {
      'version': 1,
      'note':
          'Measured by mana sense learn from .mana/sense; regenerate, do not edit.',
      'sensors': Map.fromEntries(
        sensors.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
      ),
    };
    File(p.join(root, lockFile)).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(lock)}\n',
    );
    return lock;
  }

  Sensor named(String id) =>
      sensors.where((s) => s.id == id).firstOrNull ??
      (throw ManaFailure('Unknown sensor: $id'));

  /// Paths changed since [base], committed or not, plus untracked files.
  List<String> changedSince(String base) {
    final diff = Process.runSync('git', [
      'diff',
      '--name-only',
      base,
      '--',
    ], workingDirectory: root);
    if (diff.exitCode != 0) throw ManaFailure('Cannot diff against $base');
    final untracked = Process.runSync('git', [
      'ls-files',
      '--others',
      '--exclude-standard',
    ], workingDirectory: root);
    return {
      ...(diff.stdout as String).split('\n'),
      ...(untracked.stdout as String).split('\n'),
    }.where((path) => path.isNotEmpty).toList()..sort();
  }

  /// The sensors whose coverage meets [paths], cheapest first, each with the
  /// reason it was picked.
  List<(Sensor, String)> selectFor(List<String> paths, {FeatureMap? features}) {
    final featuresTouched = <String>{};
    final momentsTouched = <String>{};
    if (features != null) {
      for (final path in paths) {
        for (final name in features.owners(path)) {
          if (featuresTouched.add(name)) {
            momentsTouched.addAll(features.moments(features.named(name)));
          }
        }
      }
    }
    final picked = <(Sensor, String)>[];
    for (final sensor in sensors) {
      String? reason;
      for (final cover in sensor.covers) {
        if (cover.startsWith('feature:')) {
          final glob = globPattern(cover.substring('feature:'.length));
          final hit = featuresTouched.where(glob.hasMatch).firstOrNull;
          if (hit != null) reason = 'feature:$hit changed';
        } else if (cover.startsWith('moment:')) {
          final glob = globPattern(cover.substring('moment:'.length));
          final hit = momentsTouched.where(glob.hasMatch).firstOrNull;
          if (hit != null) reason = 'moment:$hit is affected';
        } else {
          final glob = globPattern(cover);
          final hit = paths.where(glob.hasMatch).firstOrNull;
          if (hit != null) reason = '$hit changed';
        }
        if (reason != null) break;
      }
      if (reason != null) picked.add((sensor, reason));
    }
    return picked;
  }

  /// Runs [plan] cheapest first. A failure stops the climb to costlier
  /// sensors unless [keepGoing]; a sensor beyond [budget] is not run and stays
  /// unresolved. The result is an AVP verdict over the sensors.
  Future<Map<String, Object?>> run(
    List<(Sensor, String)> plan, {
    Duration? budget,
    bool keepGoing = false,
    void Function(String line)? progress,
    List<String> paths = const [],
  }) async {
    final logs = Directory(
      p.join(
        root,
        '.mana/sense',
        DateTime.now().toUtc().toIso8601String().replaceAll(
          RegExp('[:.]'),
          '-',
        ),
      ),
    );
    logs.createSync(recursive: true);
    final head = Process.runSync('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: root);
    File(p.join(logs.path, 'run.json')).writeAsStringSync(
      jsonEncode({
        'commit': head.exitCode == 0 ? (head.stdout as String).trim() : null,
        'paths': paths,
      }),
    );
    var spent = Duration.zero;
    var stopped = false;
    final results = <Map<String, Object?>>[];
    for (final (sensor, reason) in plan) {
      if (stopped) {
        results.add({
          'criterionId': sensor.id,
          'status': 'unresolved',
          'reason': 'Not run: a cheaper sensor failed first',
          'picked': reason,
        });
        continue;
      }
      if (budget != null && spent + sensor.cost > budget) {
        results.add({
          'criterionId': sensor.id,
          'status': 'unresolved',
          'reason':
              'Not run: ${formatCost(sensor.cost)} exceeds the remaining budget',
          'picked': reason,
        });
        continue;
      }
      progress?.call(
        '… ${sensor.id} (${formatCost(sensor.cost)}, ${sensor.proves}): $reason',
      );
      final log = File(p.join(logs.path, '${sensor.id}.log'));
      final watch = Stopwatch()..start();
      int code;
      try {
        final process = await Process.start(
          sensor.run.first,
          sensor.run.skip(1).toList(),
          workingDirectory: p.join(root, sensor.cwd),
          environment: {
            for (final MapEntry(:key, :value) in sensor.env.entries)
              key: value.replaceAll(r'${root}', root),
          },
        );
        final sink = log.openWrite();
        await Future.wait([
          process.stdout.forEach(sink.add),
          process.stderr.forEach(sink.add),
        ]);
        code = await process.exitCode;
        await sink.close();
      } on ProcessException catch (error) {
        log.writeAsStringSync('${error.message}: ${error.executable}\n');
        code = -1;
      }
      watch.stop();
      spent += watch.elapsed;
      final status = switch ((code, sensor.output)) {
        (0, _) => 'pass',
        (2, 'moments') => 'unresolved',
        (-1, _) => 'unresolved',
        _ => 'fail',
      };
      results.add({
        'criterionId': sensor.id,
        'status': status,
        if (status != 'pass')
          'reason': status == 'unresolved'
              ? 'The sensor could not decide (exit $code); see its log'
              : '${sensor.id} failed (exit $code); see its log',
        'picked': reason,
        'evidence': {
          'durationMs': watch.elapsedMilliseconds,
          'exitCode': code,
          'log': p.relative(log.path, from: root),
        },
      });
      progress?.call(
        '${status == 'pass'
            ? '✓'
            : status == 'fail'
            ? '✗'
            : '?'} ${sensor.id} ${watch.elapsed.inSeconds}s',
      );
      if (status != 'pass' && sensor.gate && !keepGoing) stopped = true;
    }
    final passed = results.where((r) => r['status'] == 'pass').length;
    final failed = results.where((r) => r['status'] == 'fail').length;
    final applicable = passed + failed;
    final verdict = {
      'protocol': 'avp',
      'protocolVersion': '0.4.0',
      'subject': 'change',
      'archetype': 'sensors',
      'results': results,
      'outcome': failed > 0
          ? 'fail'
          : results.any((r) => r['status'] == 'unresolved') || applicable == 0
          ? 'inconclusive'
          : 'pass',
      'acceptanceScore': applicable == 0 ? null : passed / applicable,
    };
    File(
      p.join(logs.path, 'verdict.json'),
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(verdict));
    return verdict;
  }
}
