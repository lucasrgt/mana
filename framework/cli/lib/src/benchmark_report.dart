/// The summary of a benchmark's raw results (`results.jsonl`), as Markdown.
///
/// Only the raw lines decide it: runs are grouped and sorted by name, never
/// by the order they ran in, so the same lines always give the same table.
/// A run with an `error` (the harness failed, not the agent) is counted
/// apart and left out of every rate.
String benchmarkSummary(List<Map<String, Object?>> runs) {
  final scored = [
    for (final r in runs)
      if (r['error'] == null) r,
  ];
  final errors = runs.length - scored.length;
  final conditions = {for (final r in runs) '${r['condition']}'}.toList()
    ..sort();
  final tasks = {for (final r in runs) '${r['task']}'}.toList()..sort();
  final names = {for (final r in runs) '${r['benchmark']}'}.toList()..sort();
  final agents = {
    for (final r in runs)
      [r['agent'], if (r['model'] != null) r['model']].join(' '),
  }.toList()..sort();
  final out = StringBuffer()
    ..writeln('# ${names.join(', ')} benchmark')
    ..writeln()
    ..writeln(
      '${runs.length} runs: ${tasks.length} tasks × ${conditions.length} conditions'
      '${agents.isEmpty ? '' : ', agent ${agents.join(', ')}'}.'
      '${errors == 0 ? '' : ' $errors runs failed in the harness and are not scored.'}',
    )
    ..writeln()
    ..writeln(
      '| Condition | Runs | Success | Median wall time | Mean tokens | Mean cost | Held-out failures | Runs with a held-out failure |',
    )
    ..writeln('| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |');
  for (final condition in conditions) {
    final group = [
      for (final r in scored)
        if (r['condition'] == condition) r,
    ];
    final passed = group.where((r) => r['success'] == true).length;
    final walls = [
      for (final r in group)
        if (r['wallSeconds'] case final num s) s.toDouble(),
    ];
    final tokens = [
      for (final r in group)
        if (r['tokens'] case final Map t)
          t.values.whereType<num>().fold<num>(0, (a, b) => a + b),
    ];
    final costs = [
      for (final r in group)
        if (r['costUsd'] case final num c) c,
    ];
    final heldout = group.fold<int>(
      0,
      (sum, r) => sum + ((r['heldoutFailures'] as num?)?.toInt() ?? 0),
    );
    final buggy = group
        .where((r) => ((r['heldoutFailures'] as num?) ?? 0) > 0)
        .length;
    out.writeln(
      [
        '',
        condition,
        '${group.length}',
        group.isEmpty ? '—' : '$passed (${_percent(passed, group.length)})',
        walls.isEmpty ? '—' : '${(_median(walls) / 60).toStringAsFixed(1)} min',
        tokens.isEmpty ? '—' : _thousands(_mean(tokens).round()),
        costs.isEmpty ? '—' : '\$${_mean(costs).toStringAsFixed(2)}',
        '$heldout',
        '$buggy',
        '',
      ].join(' | ').trim(),
    );
  }
  out
    ..writeln()
    ..writeln('## Per task')
    ..writeln()
    ..writeln('| Task | Kind | ${conditions.join(' | ')} |')
    ..writeln('| --- | --- |${' --- |' * conditions.length}');
  for (final task in tasks) {
    final kind = runs.firstWhere((r) => r['task'] == task)['kind'];
    final cells = [
      for (final condition in conditions)
        () {
          final group = [
            for (final r in scored)
              if (r['task'] == task && r['condition'] == condition) r,
          ];
          if (group.isEmpty) return '—';
          final passed = group.where((r) => r['success'] == true).length;
          final heldout = group.fold<int>(
            0,
            (sum, r) => sum + ((r['heldoutFailures'] as num?)?.toInt() ?? 0),
          );
          return '$passed/${group.length}${heldout == 0 ? '' : ' ($heldout held-out)'}';
        }(),
    ];
    out.writeln('| $task | $kind | ${cells.join(' | ')} |');
  }
  out
    ..writeln()
    ..writeln(
      'Success: every hidden check passes. Held-out failures: failing tests '
      'the agent never saw, outside the checks (bugs that reach the pull '
      'request). Tokens: input, output and cache, summed per run.',
    );
  return out.toString();
}

String _percent(int part, int whole) => '${(100 * part / whole).round()}%';

double _mean(List<num> values) =>
    values.fold<num>(0, (a, b) => a + b) / values.length;

double _median(List<double> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[mid]
      : (sorted[mid - 1] + sorted[mid]) / 2;
}

String _thousands(int value) => value.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);
