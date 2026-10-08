import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'failure.dart';
import 'features.dart';

/// One check of an agent eval: `diff` looks at the lines the agent added
/// (in files matching `files`), `command` runs in the worktree and passes on
/// exit 0.
typedef EvalCheck = ({
  String id,
  String kind,
  String? files,
  String? pattern,
  bool absent,
  List<String> run,
  String cwd,
});

/// An agent eval: a task given to an agent with no hints
/// (`evals/<name>/task.md`) and the checks that decide whether it used the
/// framework as intended (`evals/<name>/checks.toml`). [run] performs it in
/// a throwaway git worktree at HEAD and answers an AVP verdict, kept with the
/// agent's log and diff in `.mana/evals/<name>-<agent>-<time>/`.
final class AgentEval {
  AgentEval._(
    this.root,
    this.name,
    this.task,
    this.checks,
    this.setup,
    this.mcp,
    this.allow,
  );

  final String root;
  final String name;
  final String task;
  final List<EvalCheck> checks;

  /// Prepares the situation before the agent starts; `${setup}` in it (and
  /// in command checks) is a private JSON file it writes, with at least
  /// `api` and `token` when [mcp] is set.
  final List<String> setup;

  /// When set, the agent works only through `mana mcp` (`verbs`: open and
  /// follow; `flat`: one tool per operation of `contract`).
  final ({String mode, String? contract})? mcp;

  /// Tools the agent may use without asking (`[agent] allow`, e.g.
  /// `Bash(tools/generate_api.sh:*)`), besides editing files.
  final List<String> allow;

  static List<String> list(String root) {
    final dir = Directory(p.join(root, 'evals'));
    if (!dir.existsSync()) return [];
    return [
      for (final d in dir.listSync().whereType<Directory>())
        if (File(p.join(d.path, 'task.md')).existsSync()) p.basename(d.path),
    ]..sort();
  }

  static AgentEval load(String root, String name) {
    final dir = p.join(root, 'evals', name);
    final task = File(p.join(dir, 'task.md'));
    final checks = File(p.join(dir, 'checks.toml'));
    if (!task.existsSync() || !checks.existsSync()) {
      throw ManaFailure('evals/$name needs task.md and checks.toml');
    }
    final data = TomlDocument.parse(checks.readAsStringSync()).toMap();
    final mcp = data['mcp'] as Map?;
    return AgentEval._(
      root,
      name,
      task.readAsStringSync().trim(),
      [
        for (final c in ((data['check'] as List?) ?? const []).cast<Map>())
          (
            id: c['id'] as String,
            kind: c['kind'] as String,
            files: c['files'] as String?,
            pattern: c['pattern'] as String?,
            absent: c['absent'] == true,
            run: ((c['run'] as List?) ?? const []).cast<String>(),
            cwd: (c['cwd'] as String?) ?? '.',
          ),
      ],
      (((data['setup'] as Map?)?['run'] as List?) ?? const []).cast<String>(),
      mcp == null
          ? null
          : (mode: mcp['mode'] as String, contract: mcp['contract'] as String?),
      (((data['agent'] as Map?)?['allow'] as List?) ?? const []).cast<String>(),
    );
  }

  /// The lines added to files matching [files] in [worktree] since HEAD,
  /// new files included.
  static List<String> addedLines(String worktree, String? files) {
    Process.runSync('git', ['add', '-N', '.'], workingDirectory: worktree);
    final diff =
        Process.runSync('git', [
              'diff',
              '--no-prefix',
              '--unified=0',
              'HEAD',
            ], workingDirectory: worktree).stdout
            as String;
    final glob = files == null ? null : globPattern(files);
    final lines = <String>[];
    String? current;
    for (final line in const LineSplitter().convert(diff)) {
      if (line.startsWith('+++ ')) {
        current = line.substring(4);
      } else if (line.startsWith('+') &&
          !line.startsWith('+++') &&
          current != null &&
          (glob == null || glob.hasMatch(current))) {
        lines.add(line.substring(1));
      }
    }
    return lines;
  }

  /// Runs the checks in [worktree] into an AVP verdict.
  Future<Map<String, Object?>> check(
    String worktree, {
    void Function(String)? progress,
    String setupFile = '',
  }) async {
    _setup = setupFile;
    final results = <Map<String, Object?>>[];
    for (final c in checks) {
      progress?.call('… ${c.id}');
      results.add(switch (c.kind) {
        'diff' => _diff(worktree, c),
        'command' => await _command(worktree, c),
        _ => throw ManaFailure('Unknown check kind ${c.kind} in evals/$name'),
      });
    }
    final passed = results.where((r) => r['status'] == 'pass').length;
    return {
      'protocol': 'avp',
      'subject': 'eval:$name',
      'results': results,
      'outcome': passed == results.length ? 'pass' : 'fail',
      'acceptanceScore': results.isEmpty ? null : passed / results.length,
    };
  }

  Map<String, Object?> _diff(String worktree, EvalCheck c) {
    final pattern = RegExp(c.pattern ?? '');
    final hits = addedLines(worktree, c.files).where(pattern.hasMatch).toList();
    final pass = c.absent ? hits.isEmpty : hits.isNotEmpty;
    return {
      'criterionId': c.id,
      'status': pass ? 'pass' : 'fail',
      if (!pass)
        'reason': c.absent
            ? 'Added lines match what the eval forbids: ${hits.take(3).join(' | ')}'
            : 'No added line in ${c.files ?? 'the change'} matches ${c.pattern}',
    };
  }

  var _setup = '';

  Future<Map<String, Object?>> _command(String worktree, EvalCheck c) async {
    final run = [for (final a in c.run) a.replaceAll(r'${setup}', _setup)];
    final result = await Process.run(
      run.first,
      run.skip(1).toList(),
      workingDirectory: p.join(worktree, c.cwd),
    );
    final tail = '${result.stdout}${result.stderr}'
        .trim()
        .split('\n')
        .reversed
        .take(5)
        .toList()
        .reversed
        .join(' / ');
    return {
      'criterionId': c.id,
      'status': result.exitCode == 0 ? 'pass' : 'fail',
      if (result.exitCode != 0)
        'reason': '${run.join(' ')} exited ${result.exitCode}: $tail',
    };
  }

  /// Creates the worktree, lets [agent] do the task there with no hints and
  /// checks the result; the worktree is removed unless [keep].
  Future<Map<String, Object?>> run({
    required String agent,
    bool keep = false,
    void Function(String)? progress,
  }) async {
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
      RegExp('[:.]'),
      '-',
    );
    final out = Directory(p.join(root, '.mana/evals', '$name-$agent-$stamp'))
      ..createSync(recursive: true);
    final worktree = p.join(out.path, 'worktree');
    final add = Process.runSync('git', [
      'worktree',
      'add',
      '--detach',
      worktree,
      'HEAD',
    ], workingDirectory: root);
    if (add.exitCode != 0) {
      throw ManaFailure('git worktree add failed: ${add.stderr}');
    }
    final setupFile = p.join(out.path, 'setup.json');
    final stats = p.join(out.path, 'mcp-stats.json');
    try {
      if (setup.isNotEmpty) {
        final run = [
          for (final a in setup) a.replaceAll(r'${setup}', setupFile),
        ];
        final prepared = await Process.run(
          run.first,
          run.skip(1).toList(),
          workingDirectory: root,
        );
        if (prepared.exitCode != 0) {
          throw ManaFailure(
            'Eval setup failed: ${prepared.stderr}${prepared.stdout}',
          );
        }
      }
      final tools = <String>[
        if (mcp case final mcp?)
          ...() {
            final values =
                jsonDecode(File(setupFile).readAsStringSync()) as Map;
            final config = File(p.join(out.path, 'mcp.json'))
              ..writeAsStringSync(
                jsonEncode({
                  'mcpServers': {
                    'mana': {
                      'command': p.join(root, 'framework/cli/mana'),
                      'args': [
                        'mcp',
                        '--api',
                        '${values['api']}',
                        '--agent',
                        'eval-$name',
                        '--stats',
                        stats,
                        if (mcp.mode == 'flat') ...[
                          '--flat',
                          '--contract',
                          p.join(root, mcp.contract!),
                        ],
                      ],
                      'env': {'MANA_AGENT_TOKEN': '${values['token']}'},
                    },
                  },
                }),
              );
            return [
              '--mcp-config',
              config.path,
              '--strict-mcp-config',
              '--allowedTools',
              'mcp__mana',
            ];
          }(),
      ];
      progress?.call('… $agent works on: $task');
      final command = switch (agent) {
        'claude' => [
          'framework/cli/mana',
          'agent',
          'claude',
          '--',
          '-p',
          task,
          '--permission-mode',
          'acceptEdits',
          '--output-format',
          'json',
          ...tools,
          if (allow.isNotEmpty) ...['--allowedTools', ...allow],
        ],
        'codex' => [
          'framework/cli/mana',
          'agent',
          'codex',
          '--',
          'exec',
          '--full-auto',
          task,
        ],
        _ => throw ManaFailure('Unknown agent $agent'),
      };
      final started = DateTime.now();
      final work = await Process.run(
        command.first,
        command.skip(1).toList(),
        workingDirectory: worktree,
      );
      File(
        p.join(out.path, 'agent.log'),
      ).writeAsStringSync('${work.stdout}\n${work.stderr}');
      final verdict = await check(
        worktree,
        progress: progress,
        setupFile: setupFile,
      );
      final full = {
        ...verdict,
        if (File(stats).existsSync())
          'tools': jsonDecode(File(stats).readAsStringSync()),
        'agent': agent,
        'agentExit': work.exitCode,
        'minutes': (DateTime.now().difference(started).inSeconds / 60)
            .toStringAsFixed(1),
        'usage': usage(work.stdout as String),
      };
      File(p.join(out.path, 'diff.patch')).writeAsStringSync(
        Process.runSync('git', [
              'diff',
              'HEAD',
            ], workingDirectory: worktree).stdout
            as String,
      );
      File(
        p.join(out.path, 'verdict.json'),
      ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(full));
      return full;
    } finally {
      if (!keep) {
        Process.runSync('git', [
          'worktree',
          'remove',
          '--force',
          worktree,
        ], workingDirectory: root);
      }
    }
  }

  /// Tokens, cost and turns from a `claude -p --output-format json` answer.
  static Object? usage(String stdout) {
    try {
      final value = jsonDecode(stdout.trim().split('\n').last);
      return value is Map
          ? {
              'usage': value['usage'],
              'cost': value['total_cost_usd'],
              'turns': value['num_turns'],
            }
          : null;
    } on Object {
      return null;
    }
  }
}
