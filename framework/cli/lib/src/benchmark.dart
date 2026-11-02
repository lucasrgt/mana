import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'benchmark_report.dart';
import 'failure.dart';
import 'features.dart';
import 'sensors.dart';

/// A command a task or the benchmark runs in the workspace: before the agent
/// (`prepare`), to score it (`check`, `heldout`) or after it (`cleanup`).
///
/// An argument that is exactly `{files}` becomes the workspace files matching
/// [files] (relative to [filesRoot]), hidden ones and those matching
/// [except] left out (a test that already fails on the task's own commit is
/// not a bug the agent brought); [count] reads the number of failures from
/// the output (its first group, last match).
typedef BenchmarkCommand = ({
  String id,
  List<String> run,
  String cwd,
  String? files,
  String filesRoot,
  List<String> except,
  RegExp? count,
});

/// How the agent's copy differs between conditions. [strip] removes every
/// line matching a pattern (`ignore_case = true` for any case) from each
/// listed file; [replace] writes a file's
/// whole content (a script starting with `#!` stays executable).
typedef BenchmarkCondition = ({
  String name,
  String summary,
  List<String> remove,
  List<({List<String> files, RegExp pattern})> strip,
  Map<String, String> replace,
});

/// An agent the benchmark can run: [command] with `{prompt}`, `{model}`,
/// `{budget}` and `{workspace}` filled in, run in the workspace with
/// [unset] taken out of its environment. [usage] names the parser of its
/// standard output (`claude-json`), or is null.
typedef BenchmarkAgent = ({
  String name,
  List<String> command,
  String? model,
  String? budget,
  String? usage,
  List<String> unset,
});

/// One task: the tree at [commit] with the paths that commit changed
/// matching [revert] put back as they were before it, so the agent redoes the
/// change from [prompt]. [hidden] are paths of [commit] (and the files under
/// the task's `hidden/` folder) the agent never sees; they are laid over its
/// result only to score it.
final class BenchmarkTask {
  BenchmarkTask._({
    required this.id,
    required this.dir,
    required this.kind,
    required this.summary,
    required this.commit,
    required this.revert,
    required this.hidden,
    required this.prompt,
    required this.prepare,
    required this.checks,
    required this.heldout,
  });

  final String id, dir, kind, summary, commit, prompt;
  final List<String> revert, hidden;
  final List<BenchmarkCommand> prepare, checks, heldout;

  /// The files the task adds for scoring only, relative to the workspace.
  List<String> get extraHidden {
    final folder = Directory(p.join(dir, 'hidden'));
    if (!folder.existsSync()) return const [];
    return [
      for (final f in folder.listSync(recursive: true).whereType<File>())
        p.relative(f.path, from: folder.path),
    ]..sort();
  }

  static BenchmarkTask load(String dir) {
    final id = p.basename(dir);
    final file = File(p.join(dir, 'task.toml'));
    final prompt = File(p.join(dir, 'prompt.md'));
    if (!file.existsSync() || !prompt.existsSync()) {
      throw ManaFailure('Task $id needs task.toml and prompt.md');
    }
    final data = TomlDocument.parse(file.readAsStringSync()).toMap();
    final commit = data['commit'];
    if (commit is! String || commit.isEmpty) {
      throw ManaFailure('Task $id names no commit');
    }
    final checks = _commands(data['check'], 'check', id);
    if (checks.isEmpty) {
      throw ManaFailure('Task $id has no [[check]]: nothing would score it');
    }
    return BenchmarkTask._(
      id: id,
      dir: dir,
      kind: (data['kind'] as String?) ?? 'task',
      summary: (data['summary'] as String?) ?? '',
      commit: commit,
      revert: _strings(data['revert'], const ['**']),
      hidden: _strings(data['hidden'], const []),
      prompt: prompt.readAsStringSync().trim(),
      prepare: _commands(data['prepare'], 'prepare', id),
      checks: checks,
      heldout: _commands(data['heldout'], 'heldout', id),
    );
  }
}

List<String> _strings(Object? value, List<String> fallback) =>
    value == null ? fallback : (value as List).cast<String>();

List<BenchmarkCommand> _commands(Object? value, String kind, String owner) {
  final list = (value as List?) ?? const [];
  return [
    for (final (i, raw) in list.indexed)
      () {
        final c = (raw as Map).cast<String, Object?>();
        final run = _strings(c['run'], const []);
        if (run.isEmpty) throw ManaFailure('$owner: a $kind has no run');
        final count = c['count'] as String?;
        return (
          id: (c['id'] as String?) ?? '$kind-${i + 1}',
          run: run,
          cwd: (c['cwd'] as String?) ?? '.',
          files: c['files'] as String?,
          filesRoot:
              (c['files_root'] as String?) ?? (c['cwd'] as String?) ?? '.',
          except: _strings(c['except'], const []),
          count: count == null ? null : RegExp(count),
        );
      }(),
  ];
}

/// The benchmark: `benchmark.toml` and its `tasks/<id>/` folders.
final class Benchmark {
  Benchmark._({
    required this.dir,
    required this.name,
    required this.preamble,
    required this.remove,
    required this.copy,
    required this.prepare,
    required this.cleanup,
    required this.repetitions,
    required this.timeout,
    required this.checkTimeout,
    required this.passEnv,
    required this.dropEnv,
    required this.env,
    required this.submodules,
    required this.conditions,
    required this.agents,
    required this.tasks,
  });

  final String dir, name, preamble;
  final List<String> remove, copy, passEnv, dropEnv;
  final List<BenchmarkCommand> prepare, cleanup;
  final int repetitions;
  final Duration timeout, checkTimeout;
  final Map<String, String> env, submodules;
  final List<BenchmarkCondition> conditions;
  final Map<String, BenchmarkAgent> agents;
  final List<BenchmarkTask> tasks;

  /// The benchmark published with the framework.
  static String defaultDir(String frameworkRoot) =>
      p.join(frameworkRoot, 'benchmark');

  static Benchmark load(String dir) {
    final file = File(p.join(dir, 'benchmark.toml'));
    if (!file.existsSync()) {
      throw ManaFailure('No benchmark.toml in $dir');
    }
    final data = TomlDocument.parse(file.readAsStringSync()).toMap();
    final conditions = ((data['conditions'] as Map?) ?? const {})
        .cast<String, Object?>();
    if (conditions.isEmpty) {
      throw const ManaFailure('benchmark.toml declares no [conditions.<name>]');
    }
    final tasksDir = Directory(p.join(dir, 'tasks'));
    final tasks = [
      if (tasksDir.existsSync())
        for (final d in tasksDir.listSync().whereType<Directory>())
          if (File(p.join(d.path, 'task.toml')).existsSync())
            BenchmarkTask.load(d.path),
    ]..sort((a, b) => a.id.compareTo(b.id));
    return Benchmark._(
      dir: dir,
      name: (data['name'] as String?) ?? p.basename(dir),
      preamble: ((data['preamble'] as String?) ?? '').trim(),
      remove: _strings(data['remove'], const []),
      copy: _strings(data['copy'], const []),
      prepare: _commands(data['prepare'], 'prepare', 'benchmark.toml'),
      cleanup: _commands(data['cleanup'], 'cleanup', 'benchmark.toml'),
      repetitions: (data['repetitions'] as int?) ?? 1,
      timeout: parseCost((data['timeout'] as String?) ?? '45m'),
      checkTimeout: parseCost((data['check_timeout'] as String?) ?? '30m'),
      passEnv: _strings(data['pass_env'], const []),
      dropEnv: _strings(data['drop_env'], const ['MANA_', 'MOMENTS_']),
      env: ((data['env'] as Map?) ?? const {}).cast<String, String>(),
      submodules: ((data['submodules'] as Map?) ?? const {})
          .cast<String, String>(),
      conditions: [
        for (final MapEntry(:key, :value) in conditions.entries)
          () {
            final c = ((value as Map?) ?? const {}).cast<String, Object?>();
            return (
              name: key,
              summary: (c['summary'] as String?) ?? '',
              remove: _strings(c['remove'], const []),
              strip: [
                for (final s in ((c['strip'] as List?) ?? const []).cast<Map>())
                  (
                    files: _strings(s['files'], const []),
                    pattern: RegExp(
                      s['pattern'] as String,
                      caseSensitive: s['ignore_case'] != true,
                    ),
                  ),
              ],
              replace: ((c['replace'] as Map?) ?? const {})
                  .cast<String, String>(),
            );
          }(),
      ],
      agents: {
        for (final MapEntry(:key, :value)
            in ((data['agents'] as Map?) ?? const {})
                .cast<String, Map>()
                .entries)
          key: (
            name: key,
            command: _strings(value['command'], const []),
            model: value['model'] as String?,
            budget: value['budget']?.toString(),
            usage: value['usage'] as String?,
            unset: _strings(value['unset'], const []),
          ),
      },
      tasks: tasks,
    );
  }

  BenchmarkCondition condition(String name) => conditions.firstWhere(
    (c) => c.name == name,
    orElse: () => throw ManaFailure(
      'Unknown condition $name (${conditions.map((c) => c.name).join(', ')})',
    ),
  );

  List<BenchmarkTask> select(List<String>? ids) {
    if (ids == null || ids.isEmpty) return tasks;
    return [
      for (final id in ids)
        tasks.firstWhere(
          (t) => t.id == id,
          orElse: () => throw ManaFailure('Unknown task $id'),
        ),
    ];
  }
}

/// Agents built into the harness: `noop` changes nothing and `oracle`
/// applies the task's own commit, so a task can be checked to fail untouched
/// and pass with its real solution before any model runs it.
const builtInAgents = {'noop', 'oracle'};

/// One planned run.
typedef BenchmarkRun = ({
  BenchmarkTask task,
  BenchmarkCondition condition,
  int repetition,
});

/// Runs tasks × conditions × repetitions, each in a fresh workspace with no
/// history, and appends one JSON line per run to `results.jsonl` in [out]
/// (runs already there are skipped, so a stopped run resumes).
final class BenchmarkRunner {
  BenchmarkRunner(
    this.benchmark, {
    required this.repo,
    required this.out,
    required this.work,
    required this.agent,
    this.model,
    this.budget,
    this.timeout,
    this.keep = false,
    this.harness,
    this.progress,
  });

  final Benchmark benchmark;

  /// The project's git repository (its history holds every task's commit;
  /// its working tree, the caches listed in `copy`).
  final String repo;
  final String out, work, agent;
  final String? model, budget;
  final Duration? timeout;
  final bool keep;

  /// The framework commit the harness ran from, kept with every result.
  final String? harness;
  final void Function(String)? progress;

  BenchmarkAgent? get _agent {
    if (builtInAgents.contains(agent)) return null;
    return benchmark.agents[agent] ??
        (throw ManaFailure(
          'Unknown agent $agent (benchmark.toml: ${benchmark.agents.keys.join(', ')}; built in: ${builtInAgents.join(', ')})',
        ));
  }

  String get resultsFile => p.join(out, 'results.jsonl');

  List<BenchmarkRun> plan({
    List<String>? tasks,
    List<String>? conditions,
    int? repetitions,
  }) => [
    for (final task in benchmark.select(tasks))
      for (final condition in [
        for (final name
            in conditions ?? [for (final c in benchmark.conditions) c.name])
          benchmark.condition(name),
      ])
        for (var r = 1; r <= (repetitions ?? benchmark.repetitions); r++)
          (task: task, condition: condition, repetition: r),
  ];

  static String runId(BenchmarkRun run) =>
      '${run.task.id}-${run.condition.name}-${run.repetition}';

  /// The prompt the agent receives, the same in every condition.
  String prompt(BenchmarkTask task) => [
    if (benchmark.preamble.isNotEmpty) benchmark.preamble,
    task.prompt,
  ].join('\n\n');

  /// The agent's command line for [run] in [workspace].
  List<String> command(BenchmarkRun run, String workspace) {
    final spec = _agent;
    if (spec == null) return ['(built-in $agent)'];
    final values = {
      'prompt': prompt(run.task),
      'model': model ?? spec.model ?? '',
      'budget': budget ?? spec.budget ?? '',
      'workspace': workspace,
    };
    return [
      for (final arg in spec.command)
        arg.replaceAllMapped(
          RegExp(r'\{(prompt|model|budget|workspace)\}'),
          (m) => values[m[1]]!,
        ),
    ];
  }

  /// The environment the agent and the checks get: this one without the
  /// variables starting with a `drop_env` prefix (Mana's and Moments' own by
  /// default: they would point into another checkout), except those
  /// `pass_env` lets through, plus `env`.
  Map<String, String> environment({
    List<String> unset = const [],
    Map<String, String>? from,
  }) => {
    for (final MapEntry(:key, :value) in (from ?? Platform.environment).entries)
      if (benchmark.passEnv.contains(key) ||
          !(benchmark.dropEnv.any(key.startsWith) || unset.contains(key)))
        key: value,
    ...benchmark.env,
  };

  Future<List<Map<String, Object?>>> run(List<BenchmarkRun> runs) async {
    Directory(out).createSync(recursive: true);
    final done = {
      for (final r in readResults(resultsFile))
        '${r['task']}-${r['condition']}-${r['repetition']}',
    };
    final results = <Map<String, Object?>>[];
    for (final run in runs) {
      final id = runId(run);
      if (done.contains(id)) {
        progress?.call('= $id already in ${p.relative(resultsFile)}');
        continue;
      }
      progress?.call('▶ $id');
      final result = await runOne(run);
      File(resultsFile).writeAsStringSync(
        '${jsonEncode(result)}\n',
        mode: FileMode.append,
        flush: true,
      );
      progress?.call(
        '${result['error'] != null
            ? '! error'
            : result['success'] == true
            ? '✓ pass'
            : '✗ fail'} $id'
        '${result['error'] != null ? ': ${result['error']}' : ''}',
      );
      results.add(result);
    }
    File(
      p.join(out, 'summary.md'),
    ).writeAsStringSync(benchmarkSummary(readResults(resultsFile)));
    return results;
  }

  /// Prepares [run]'s workspace, lets the agent work, scores the result and
  /// removes the workspace (unless [keep]).
  Future<Map<String, Object?>> runOne(BenchmarkRun run) async {
    final id = runId(run);
    final logs = Directory(p.join(out, 'runs', id))
      ..createSync(recursive: true);
    final workspace = p.join(work, id);
    final record = <String, Object?>{
      'benchmark': benchmark.name,
      'task': run.task.id,
      'kind': run.task.kind,
      'condition': run.condition.name,
      'repetition': run.repetition,
      'agent': agent,
      'model': _agent == null ? null : (model ?? _agent!.model),
      'commit': run.task.commit,
      'startedAt': DateTime.now().toUtc().toIso8601String(),
      'harness': ?harness,
    };
    final env = environment(unset: _agent?.unset ?? const []);
    try {
      record['commit'] = _git([
        'rev-parse',
        '${run.task.commit}^{commit}',
      ]).trim();
      final prepared = await prepare(run, workspace, logs: logs.path);
      record['submodules'] = prepared.submodules;
      record['strippedLines'] = prepared.stripped;
      final agentResult = await _work(run, workspace, env, logs.path);
      record.addAll(agentResult);
      final diff = _diff(workspace, prepared.base, logs.path);
      record['diff'] = diff;
      record.addAll(await score(run.task, workspace, env, logs: logs.path));
    } on ManaFailure catch (error) {
      record['error'] = error.message;
    } on FileSystemException catch (error) {
      record['error'] = '${error.message}: ${error.path}';
    } on ProcessException catch (error) {
      record['error'] = '${error.executable}: ${error.message}';
    } finally {
      await _cleanup(workspace, env, logs.path);
      if (!keep) _remove(workspace);
    }
    record['logs'] = p.relative(logs.path, from: out);
    return record;
  }

  /// The workspace for [run]: the task's starting tree, its submodules, the
  /// copied caches, the prepare commands, then the condition, committed as
  /// the only commit of a new repository.
  Future<({String base, Map<String, String> submodules, int stripped})> prepare(
    BenchmarkRun run,
    String workspace, {
    required String logs,
  }) async {
    final task = run.task;
    if (Directory(workspace).existsSync()) _remove(workspace);
    Directory(workspace).createSync(recursive: true);
    final commit = _git(['rev-parse', '${task.commit}^{commit}']).trim();
    _extract(repo, commit, workspace);
    final changes = changedPaths(commit);
    final reverted = revertedPaths(task, changes);
    for (final hidden in task.hidden) {
      if (!changes.containsKey(hidden)) {
        throw ManaFailure(
          '${task.id}: hidden path $hidden is not changed by ${task.commit}, so the agent would see it',
        );
      }
    }
    _checkout(repo, '$commit^', reverted, workspace);
    final submodules = <String, String>{};
    for (final MapEntry(key: path, value: source)
        in benchmark.submodules.entries) {
      final rev = reverted.contains(path) ? '$commit^' : commit;
      final entry = _git([
        'ls-tree',
        rev,
        '--',
        path,
      ]).trim().split(RegExp(r'\s+'));
      if (entry.length < 3 || entry[1] != 'commit') continue;
      final from = p.isAbsolute(source) ? source : p.join(repo, source);
      final target = Directory(p.join(workspace, path));
      if (target.existsSync()) target.deleteSync(recursive: true);
      target.createSync(recursive: true);
      _extract(from, entry[2], target.path);
      submodules[path] = entry[2];
    }
    for (final path in benchmark.copy) {
      final from = p.join(repo, path);
      if (!FileSystemEntity.isDirectorySync(from) &&
          !FileSystemEntity.isFileSync(from)) {
        continue;
      }
      final to = p.join(workspace, path);
      _remove(to);
      Directory(p.dirname(to)).createSync(recursive: true);
      _run(['cp', '-a', from, to]);
    }
    final env = environment(unset: _agent?.unset ?? const []);
    for (final c in [...benchmark.prepare, ...task.prepare]) {
      final result = await _command(c, workspace, env, logs, 'prepare');
      if (result.code != 0) {
        throw ManaFailure(
          'prepare ${c.id} exited ${result.code} (${p.join(logs, 'prepare-${c.id}.log')})',
        );
      }
    }
    for (final path in [...benchmark.remove, ...run.condition.remove]) {
      _remove(p.join(workspace, path));
    }
    var stripped = 0;
    for (final strip in run.condition.strip) {
      for (final path in strip.files) {
        final file = File(p.join(workspace, path));
        if (!file.existsSync()) continue;
        final lines = const LineSplitter().convert(file.readAsStringSync());
        final kept = [
          for (final line in lines)
            if (!strip.pattern.hasMatch(line)) line,
        ];
        stripped += lines.length - kept.length;
        file.writeAsStringSync('${kept.join('\n')}\n');
      }
    }
    for (final MapEntry(key: path, value: content)
        in run.condition.replace.entries) {
      final file = File(p.join(workspace, path))..createSync(recursive: true);
      file.writeAsStringSync(content);
      if (content.startsWith('#!')) _run(['chmod', '+x', file.path]);
    }
    _run(['git', 'init', '-q'], cwd: workspace);
    _run(['git', 'add', '-A'], cwd: workspace);
    _run(
      [
        'git',
        '-c',
        'core.hooksPath=/dev/null',
        '-c',
        'commit.gpgsign=false',
        'commit',
        '-qm',
        'base',
      ],
      cwd: workspace,
      env: const {
        'GIT_AUTHOR_NAME': 'benchmark',
        'GIT_AUTHOR_EMAIL': 'benchmark@localhost',
        'GIT_COMMITTER_NAME': 'benchmark',
        'GIT_COMMITTER_EMAIL': 'benchmark@localhost',
        'GIT_AUTHOR_DATE': '2000-01-01T00:00:00Z',
        'GIT_COMMITTER_DATE': '2000-01-01T00:00:00Z',
      },
    );
    return (
      base: _run(['git', 'rev-parse', 'HEAD'], cwd: workspace).trim(),
      submodules: submodules,
      stripped: stripped,
    );
  }

  /// Every path [commit] changed against its parent, with its status letter.
  Map<String, String> changedPaths(String commit) {
    final raw = _git([
      'diff-tree',
      '-r',
      '-z',
      '--no-renames',
      '--no-commit-id',
      '--name-status',
      '$commit^',
      commit,
    ]).split('\x00');
    return {for (var i = 0; i + 1 < raw.length; i += 2) raw[i + 1]: raw[i]};
  }

  /// The changed paths the agent gets as they were before the commit: the
  /// ones [BenchmarkTask.revert] matches, and every hidden one.
  static Set<String> revertedPaths(
    BenchmarkTask task,
    Map<String, String> changes,
  ) {
    final globs = [for (final g in task.revert) globPattern(g)];
    return {
      for (final path in changes.keys)
        if (task.hidden.contains(path) || globs.any((g) => g.hasMatch(path)))
          path,
    };
  }

  Future<Map<String, Object?>> _work(
    BenchmarkRun run,
    String workspace,
    Map<String, String> env,
    String logs,
  ) async {
    final watch = Stopwatch()..start();
    if (agent == 'noop') {
      return {'wallSeconds': 0.0, 'agentExit': 0, 'timedOut': false};
    }
    if (agent == 'oracle') {
      final commit = _git(['rev-parse', '${run.task.commit}^{commit}']).trim();
      final changes = changedPaths(commit);
      final solution = revertedPaths(run.task, changes)
        ..removeAll(run.task.hidden)
        ..removeAll(benchmark.submodules.keys);
      _checkout(repo, commit, solution, workspace);
      return {
        'wallSeconds': _seconds(watch.elapsed),
        'agentExit': 0,
        'timedOut': false,
      };
    }
    final argv = command(run, workspace);
    final result = await runInGroup(
      argv,
      cwd: workspace,
      env: env,
      timeout: timeout ?? benchmark.timeout,
      stdout: p.join(logs, 'agent.out'),
      stderr: p.join(logs, 'agent.err'),
    );
    final output = File(p.join(logs, 'agent.out')).readAsStringSync();
    return {
      'wallSeconds': _seconds(watch.elapsed),
      'agentExit': result.code,
      'timedOut': result.timedOut,
      ...switch (_agent!.usage) {
        'claude-json' => claudeUsage(output),
        _ => const <String, Object?>{},
      },
    };
  }

  Map<String, Object?> _diff(String workspace, String base, String logs) {
    _run(['git', 'add', '-A'], cwd: workspace);
    File(p.join(logs, 'diff.patch')).writeAsStringSync(
      _run(['git', 'diff', '--cached', '--binary', base], cwd: workspace),
    );
    var files = 0, insertions = 0, deletions = 0;
    for (final line in const LineSplitter().convert(
      _run(['git', 'diff', '--cached', '--numstat', base], cwd: workspace),
    )) {
      final parts = line.split('\t');
      if (parts.length < 3) continue;
      files++;
      insertions += int.tryParse(parts[0]) ?? 0;
      deletions += int.tryParse(parts[1]) ?? 0;
    }
    return {'files': files, 'insertions': insertions, 'deletions': deletions};
  }

  /// Lays the hidden files over the agent's result and runs the checks
  /// (the acceptance: all must pass) and the held-out commands (failures
  /// there are bugs that reach the pull request).
  Future<Map<String, Object?>> score(
    BenchmarkTask task,
    String workspace,
    Map<String, String> env, {
    required String logs,
  }) async {
    final commit = _git(['rev-parse', '${task.commit}^{commit}']).trim();
    _checkout(repo, commit, task.hidden.toSet(), workspace);
    final extra = task.extraHidden;
    for (final path in extra) {
      final target = File(p.join(workspace, path))..createSync(recursive: true);
      File(p.join(task.dir, 'hidden', path)).copySync(target.path);
    }
    final hidden = {...task.hidden, ...extra};
    Future<List<Map<String, Object?>>> each(
      List<BenchmarkCommand> commands,
      String kind,
    ) async => [
      for (final c in commands)
        await () async {
          final watch = Stopwatch()..start();
          final result = await _command(
            c,
            workspace,
            env,
            logs,
            kind,
            hidden: hidden,
          );
          final failures = result.code == 0 ? 0 : _failures(c, result.output);
          return {
            'id': c.id,
            'status': result.code == 0 ? 'pass' : 'fail',
            'exit': result.code,
            'seconds': _seconds(watch.elapsed),
            if (kind == 'heldout') 'failures': failures,
          };
        }(),
    ];
    final checks = await each(task.checks, 'check');
    final heldout = await each(task.heldout, 'heldout');
    return {
      'checks': checks,
      'success': checks.every((c) => c['status'] == 'pass'),
      'heldout': heldout,
      'heldoutFailures': heldout.fold<int>(
        0,
        (sum, c) => sum + (c['failures']! as int),
      ),
    };
  }

  static int _failures(BenchmarkCommand c, String output) {
    final matches = c.count?.allMatches(output).toList() ?? const [];
    final counted = matches.isEmpty
        ? null
        : int.tryParse(matches.last[1] ?? '');
    return counted == null || counted == 0 ? 1 : counted;
  }

  Future<({int code, bool timedOut, String output})> _command(
    BenchmarkCommand c,
    String workspace,
    Map<String, String> env,
    String logs,
    String kind, {
    Set<String> hidden = const {},
  }) async {
    final cwd = p.join(workspace, c.cwd);
    final argv = [
      for (final arg in c.run)
        if (arg == '{files}')
          ...matchingFiles(
            workspace,
            c.files ?? '**',
            root: c.filesRoot,
            except: hidden,
            exceptGlobs: c.except,
          )
        else
          arg,
    ];
    final log = p.join(logs, '$kind-${c.id}.log');
    final result = await runInGroup(
      argv,
      cwd: cwd,
      env: env,
      timeout: benchmark.checkTimeout,
      stdout: log,
    );
    return (
      code: result.code,
      timedOut: result.timedOut,
      output: File(log).readAsStringSync(),
    );
  }

  /// Files under [workspace] matching [glob], relative to [root] and
  /// sorted, without [except] and [exceptGlobs] (paths relative to the
  /// workspace).
  static List<String> matchingFiles(
    String workspace,
    String glob, {
    String root = '.',
    Set<String> except = const {},
    List<String> exceptGlobs = const [],
  }) {
    final pattern = globPattern(glob);
    final excluded = [for (final g in exceptGlobs) globPattern(g)];
    final base = Directory(p.join(workspace, root));
    if (!base.existsSync()) return const [];
    return [
      for (final f in base.listSync(recursive: true).whereType<File>())
        if (p.relative(f.path, from: workspace) case final path
            when pattern.hasMatch(path) &&
                !except.contains(path) &&
                !excluded.any((g) => g.hasMatch(path)))
          p.relative(f.path, from: base.path),
    ]..sort();
  }

  Future<void> _cleanup(
    String workspace,
    Map<String, String> env,
    String logs,
  ) async {
    if (!Directory(workspace).existsSync()) return;
    for (final c in benchmark.cleanup) {
      try {
        await _command(c, workspace, env, logs, 'cleanup');
      } on ProcessException {
        // Cleanup is best effort; the containers below are removed anyway.
      }
    }
    removeContainers(workspace);
  }

  String _git(List<String> args) => _run(['git', ...args], cwd: repo);
}

/// Removes the containers a run left behind: those mounting a folder of
/// [workspace] and the Moments sandboxes of its projects (labelled with the
/// hash of the project's path). Nothing when Docker is not installed.
void removeContainers(String workspace) {
  final resolved = Directory(workspace).resolveSymbolicLinksSync();
  final ProcessResult listed;
  try {
    listed = Process.runSync('docker', ['ps', '-aq']);
  } on ProcessException {
    return;
  }
  if (listed.exitCode != 0) return;
  final ids = const LineSplitter()
      .convert(listed.stdout as String)
      .where((id) => id.isNotEmpty)
      .toList();
  if (ids.isEmpty) return;
  final projects = <String>{};
  void walk(Directory dir, int depth) {
    for (final d in dir.listSync(followLinks: false).whereType<Directory>()) {
      if (p.basename(d.path) == 'moments') {
        projects.add(sha256.convert(utf8.encode(dir.path)).toString());
      } else if (depth < 3) {
        walk(d, depth + 1);
      }
    }
  }

  walk(Directory(resolved), 0);
  final inspected = Process.runSync('docker', [
    'inspect',
    '--format',
    '{{.Id}}\t{{index .Config.Labels "dev.moments.workspace"}}\t{{range .Mounts}}{{.Source}}\t{{end}}',
    ...ids,
  ]);
  final owned = [
    for (final line in const LineSplitter().convert(inspected.stdout as String))
      if (line.split('\t') case [final id, final label, ...final mounts]
          when projects.contains(label) ||
              mounts.any((m) => m == resolved || p.isWithin(resolved, m)))
        id,
  ];
  if (owned.isNotEmpty) {
    Process.runSync('docker', ['rm', '-f', '-v', ...owned]);
  }
}

/// Tokens, cost and turns from `claude -p --output-format json`: its result
/// object, the whole output or its last line that is one.
Map<String, Object?> claudeUsage(String stdout) {
  Map? value;
  for (final line in [
    stdout,
    ...const LineSplitter().convert(stdout).reversed,
  ]) {
    try {
      final decoded = jsonDecode(line.trim());
      if (decoded is Map && decoded['type'] == 'result') {
        value = decoded;
        break;
      }
    } on FormatException {
      continue;
    }
  }
  if (value == null) return const {};
  final usage = (value['usage'] as Map?) ?? const {};
  int tokens(String key) => (usage[key] as num?)?.toInt() ?? 0;
  return {
    'tokens': {
      'input': tokens('input_tokens'),
      'output': tokens('output_tokens'),
      'cacheRead': tokens('cache_read_input_tokens'),
      'cacheCreation': tokens('cache_creation_input_tokens'),
    },
    'costUsd': value['total_cost_usd'],
    'turns': value['num_turns'],
    'agentResult': value['subtype'],
  };
}

/// Runs [argv] leading a process group of its own (`setsid` on Linux, perl's
/// `setpgrp` on macOS) with its output in files, so a timeout stops what the
/// agent started too (servers, test runs), not only the agent.
Future<({int code, bool timedOut})> runInGroup(
  List<String> argv, {
  required String cwd,
  required Map<String, String> env,
  required Duration timeout,
  required String stdout,
  String? stderr,
}) async {
  final grouped = Platform.isMacOS
      ? [
          '/usr/bin/perl',
          '-e',
          r'setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"',
          '--',
          ...argv,
        ]
      : ['setsid', ...argv];
  final child = await Process.start(
    grouped.first,
    grouped.skip(1).toList(),
    workingDirectory: cwd,
    environment: env,
    includeParentEnvironment: false,
  );
  final out = File(stdout).openWrite();
  final err = stderr == null ? out : File(stderr).openWrite();
  final drained = [
    child.stdout.listen(out.add).asFuture<void>(),
    child.stderr.listen(err.add).asFuture<void>(),
  ];
  var timedOut = false;
  Timer? kill;
  final timer = Timer(timeout, () {
    timedOut = true;
    Process.killPid(-child.pid);
    kill = Timer(
      const Duration(seconds: 10),
      () => Process.killPid(-child.pid, ProcessSignal.sigkill),
    );
  });
  final code = await child.exitCode;
  timer.cancel();
  kill?.cancel();
  Process.killPid(-child.pid, ProcessSignal.sigkill);
  await Future.wait(
    drained,
  ).timeout(const Duration(seconds: 5), onTimeout: () => const []);
  await out.close();
  if (stderr != null) await err.close();
  return (code: timedOut ? 124 : code, timedOut: timedOut);
}

double _seconds(Duration d) => (d.inMilliseconds / 100).round() / 10;

String _run(List<String> argv, {String? cwd, Map<String, String>? env}) {
  final result = Process.runSync(
    argv.first,
    argv.skip(1).toList(),
    workingDirectory: cwd,
    environment: env,
  );
  if (result.exitCode != 0) {
    throw ManaFailure(
      '${argv.join(' ')} exited ${result.exitCode}: ${'${result.stderr}'.trim()}',
    );
  }
  return result.stdout as String;
}

/// [rev]'s tree written into [dest], files dated now so build caches copied
/// later are older than every source and rebuild what changed.
void _extract(String repo, String rev, String dest) {
  final tar = p.join(dest, '.benchmark-tree.tar');
  try {
    _run(['git', '-C', repo, 'archive', '--format=tar', '-o', tar, rev]);
    _run(['tar', '-xmf', tar, '-C', dest]);
  } finally {
    final file = File(tar);
    if (file.existsSync()) file.deleteSync();
  }
}

/// [paths] in [dest] as they are at [rev] in [repo]: written from it, or
/// deleted when [rev] does not have them.
void _checkout(String repo, String rev, Set<String> paths, String dest) {
  if (paths.isEmpty) return;
  final present = <String>{};
  final sorted = paths.toList()..sort();
  for (var i = 0; i < sorted.length; i += 200) {
    final batch = sorted.sublist(i, (i + 200).clamp(0, sorted.length));
    final listed = Process.runSync(
      'git',
      ['-C', repo, 'ls-tree', '-r', '-z', '--name-only', rev, '--', ...batch],
      environment: {'GIT_LITERAL_PATHSPECS': '1'},
    );
    present.addAll(
      (listed.stdout as String).split('\x00').where((s) => s.isNotEmpty),
    );
  }
  for (final path in sorted) {
    if (!present.contains(path)) _remove(p.join(dest, path));
  }
  final existing = present.toList()..sort();
  for (var i = 0; i < existing.length; i += 200) {
    final batch = existing.sublist(i, (i + 200).clamp(0, existing.length));
    for (final path in batch) {
      _remove(p.join(dest, path));
    }
    final tar = p.join(dest, '.benchmark-checkout.tar');
    try {
      final archived = Process.runSync(
        'git',
        ['-C', repo, 'archive', '--format=tar', '-o', tar, rev, '--', ...batch],
        environment: {'GIT_LITERAL_PATHSPECS': '1'},
      );
      if (archived.exitCode != 0) {
        throw ManaFailure('git archive $rev failed: ${archived.stderr}');
      }
      _run(['tar', '-xmf', tar, '-C', dest]);
    } finally {
      final file = File(tar);
      if (file.existsSync()) file.deleteSync();
    }
  }
}

void _remove(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.directory) {
    Directory(path).deleteSync(recursive: true);
  } else {
    File(path).deleteSync();
  }
}

/// The runs in a `results.jsonl`; none when it does not exist.
List<Map<String, Object?>> readResults(String path) {
  final file = File(path);
  if (!file.existsSync()) return const [];
  return [
    for (final line in file.readAsLinesSync())
      if (line.trim().isNotEmpty)
        (jsonDecode(line) as Map).cast<String, Object?>(),
  ];
}

const benchmarkUsage = '''
mana eval benchmark [run] --repo <git repo> [--tasks a,b] [--conditions moments,none]
  [--repetitions N] [--agent claude|noop|oracle|<benchmark.toml agent>] [--model M] [--budget USD]
  [--timeout 45m] [--out <dir>] [--work <dir>] [--keep] [--dry-run] [--suite <dir>]
mana eval benchmark validate --repo <git repo> [--tasks a,b]
mana eval benchmark report <results.jsonl> [--out summary.md]
mana eval benchmark list''';

/// `mana eval benchmark`: answers the process exit code.
Future<int> benchmarkCommand(
  List<String> arguments, {
  required String frameworkRoot,
  void Function(String) print = _stdout,
}) async {
  final parser = ArgParser()
    ..addOption('suite')
    ..addOption('repo')
    ..addOption('tasks')
    ..addOption('conditions')
    ..addOption('repetitions')
    ..addOption('agent', defaultsTo: 'claude')
    ..addOption('model')
    ..addOption('budget')
    ..addOption('timeout')
    ..addOption('out')
    ..addOption('work')
    ..addFlag('keep', negatable: false)
    ..addFlag('dry-run', negatable: false);
  final values = parser.parse(arguments);
  final rest = values.rest;
  final suite = values.option('suite') ?? Benchmark.defaultDir(frameworkRoot);
  List<String>? csv(String name) => values
      .option(name)
      ?.split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();
  if (rest case ['report', final file]) {
    final summary = benchmarkSummary(readResults(file));
    if (values.option('out') case final path?) {
      File(path).writeAsStringSync(summary);
    } else {
      print(summary.trimRight());
    }
    return 0;
  }
  final benchmark = Benchmark.load(suite);
  if (rest case ['list']) {
    for (final t in benchmark.tasks) {
      print('${t.id.padRight(32)} ${t.kind.padRight(8)} ${t.summary}');
    }
    return 0;
  }
  final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
    RegExp(r'[:.]'),
    '-',
  );
  final repo = values.option('repo');
  if (repo == null) {
    throw const ManaFailure(
      'Pass --repo <git repository> holding the tasks\' commits',
    );
  }
  final work =
      values.option('work') ??
      (values.flag('dry-run')
          ? p.join(Directory.systemTemp.path, 'mana-benchmark-$stamp')
          : Directory.systemTemp.createTempSync('mana-benchmark-').path);
  final timeout = values.option('timeout');
  BenchmarkRunner runner(String agent, String out) => BenchmarkRunner(
    benchmark,
    repo: Directory(repo).absolute.path,
    out: out,
    work: work,
    agent: agent,
    model: values.option('model'),
    budget: values.option('budget'),
    timeout: timeout == null ? null : parseCost(timeout),
    keep: values.flag('keep'),
    harness: () {
      final head = Process.runSync('git', [
        'rev-parse',
        'HEAD',
      ], workingDirectory: frameworkRoot);
      return head.exitCode == 0 ? (head.stdout as String).trim() : null;
    }(),
    progress: print,
  );
  switch (rest) {
    case ['validate']:
      final out =
          values.option('out') ??
          p.join(Directory.systemTemp.path, 'mana-benchmark-validate-$stamp');
      final plan = (List<BenchmarkRun> runs) => [
        for (final r in runs)
          if (r.repetition == 1 && r.condition == benchmark.conditions.first) r,
      ];
      final noop = runner('noop', p.join(out, 'noop'));
      final oracle = runner('oracle', p.join(out, 'oracle'));
      await noop.run(plan(noop.plan(tasks: csv('tasks'))));
      await oracle.run(plan(oracle.plan(tasks: csv('tasks'))));
      Map<String, Map<String, Object?>> byTask(BenchmarkRunner r) => {
        for (final result in readResults(r.resultsFile))
          '${result['task']}': result,
      };
      final untouched = byTask(noop), solved = byTask(oracle);
      var valid = true;
      for (final task in benchmark.select(csv('tasks'))) {
        final before = untouched[task.id] ?? const {};
        final after = solved[task.id] ?? const {};
        final problems = [
          if (before['error'] ?? after['error'] case final error?) '$error',
          if (before['success'] == true) 'its checks pass untouched',
          if (after['success'] != true) 'its checks fail on its own commit',
          if ((after['heldoutFailures'] as int? ?? 0) > 0)
            'its held-out commands fail on its own commit',
        ];
        valid &= problems.isEmpty;
        print(
          '${problems.isEmpty ? 'valid  ' : 'INVALID'} ${task.id}'
          '${problems.isEmpty ? '' : ': ${problems.join('; ')}'}',
        );
      }
      return valid ? 0 : 1;
    case [] || ['run']:
      final out = values.option('out') ?? p.join(suite, 'results', stamp);
      final bench = runner(values.option('agent')!, out);
      final repetitions = values.option('repetitions');
      final runs = bench.plan(
        tasks: csv('tasks'),
        conditions: csv('conditions'),
        repetitions: repetitions == null ? null : int.parse(repetitions),
      );
      if (values.flag('dry-run')) {
        for (final run in runs) {
          final workspace = p.join(work, BenchmarkRunner.runId(run));
          print(
            '${BenchmarkRunner.runId(run)}: cd ${_quote(workspace)} && '
            '${bench.command(run, workspace).map(_quote).join(' ')}',
          );
        }
        print(
          '${runs.length} runs, at most ${(timeout == null ? benchmark.timeout : parseCost(timeout)).inMinutes} min of agent time each; nothing ran.',
        );
        return 0;
      }
      await bench.run(runs);
      print(
        'Results: ${p.relative(bench.resultsFile)}; summary: ${p.relative(p.join(out, 'summary.md'))}',
      );
      return 0;
    default:
      throw ManaFailure('Use$benchmarkUsage');
  }
}

void _stdout(String line) => stdout.writeln(line);

String _quote(String arg) => RegExp(r'^[\w@%+=:,./-]+$').hasMatch(arg)
    ? arg
    : "'${arg.replaceAll("'", r"'\''")}'";
