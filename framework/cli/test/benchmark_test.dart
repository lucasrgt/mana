import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A scripted agent: `{model}` picks what it does, and it writes what it
/// could see next to its workspace, so a test can tell what reached it.
const _agent = r'''
prompt="$1"; mode="$2"
seen="../seen-$(basename "$PWD").txt"
{
  echo "prompt=$(printf %s "$prompt" | tr '\n' '|')"
  echo "files=$(find app -type f | sort | tr '\n' ' ')"
  echo "commits=$(git rev-list --count HEAD)"
  echo "agents=$(tr '\n' '|' < AGENTS.md)"
  echo "moments=$(sh tools/moments 2>&1)"
  echo "framework=$(ls sub/framework | tr '\n' ' ')"
  echo "cache=$(cat cache/warm)"
  echo "lab=${LAB_URL:-unset} other=${MANA_OTHER:-unset}"
} > "$seen"
case "$mode" in
  fix) printf 'price() { echo 90; }\nname() { echo stay; }\n' > app/lib.sh ;;
  break) printf 'price() { echo 90; }\nname() { echo moved; }\n' > app/lib.sh ;;
  cheat) printf 'exit 0\n' > app/price_test.sh ;;
  sleep) sleep 30 & sleep 30 ;;
esac
echo '{"type":"result","subtype":"success","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":20},"total_cost_usd":0.25,"num_turns":3}'
''';

void main() {
  late String root, repo, suite, sub;

  void write(String path, String text) =>
      (File(path)..createSync(recursive: true)).writeAsStringSync(text);
  String git(String dir, List<String> args) {
    final result = Process.runSync('git', [
      '-c',
      'user.email=a@b',
      '-c',
      'user.name=a',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ], workingDirectory: dir);
    if (result.exitCode != 0) fail('git $args: ${result.stderr}');
    return (result.stdout as String).trim();
  }

  setUp(() {
    root = Directory.systemTemp
        .createTempSync('mana-benchmark-test-')
        .resolveSymbolicLinksSync();
    sub = p.join(root, 'sub');
    write(p.join(sub, 'framework/readme'), 'framework\n');
    write(p.join(sub, 'framework/benchmark/answers'), 'the price is 90\n');
    git(sub, ['init', '-q']);
    git(sub, ['add', '.']);
    git(sub, ['commit', '-qm', 'framework']);
    final pinned = git(sub, ['rev-parse', 'HEAD']);
    write(p.join(sub, 'framework/readme'), 'newer framework\n');
    git(sub, ['commit', '-qam', 'newer']);

    repo = p.join(root, 'repo');
    write(
      p.join(repo, 'app/lib.sh'),
      'price() { echo 100; }\nname() { echo stay; }\n',
    );
    write(
      p.join(repo, 'app/name_test.sh'),
      '. app/lib.sh; [ "\$(name)" = stay ]\n',
    );
    write(
      p.join(repo, 'AGENTS.md'),
      'Prove it with Moments.\nKeep it small.\n',
    );
    write(p.join(repo, 'tools/moments'), '#!/bin/sh\necho real runner\n');
    write(p.join(repo, '.gitignore'), 'cache/\n');
    write(p.join(repo, 'cache/warm'), 'compiled\n');
    git(repo, ['init', '-q']);
    git(repo, ['add', '.']);
    git(repo, ['update-index', '--add', '--cacheinfo', '160000,$pinned,sub']);
    git(repo, ['commit', '-qm', 'start']);
    write(
      p.join(repo, 'app/lib.sh'),
      'price() { echo 90; }\nname() { echo stay; }\n',
    );
    write(
      p.join(repo, 'app/price_test.sh'),
      '. app/lib.sh; [ "\$(price)" = 90 ]\n',
    );
    git(repo, ['add', '.']);
    git(repo, ['commit', '-qm', 'The price is 90']);
    final fix = git(repo, ['rev-parse', 'HEAD']);
    write(p.join(repo, 'later.txt'), 'later\n');
    git(repo, ['add', '.']);
    git(repo, ['commit', '-qm', 'later']);

    suite = p.join(root, 'suite');
    write(p.join(root, 'agent.sh'), _agent);
    write(p.join(suite, 'benchmark.toml'), '''
name = "Fixture"
preamble = "Work without asking."
remove = ["sub/framework/benchmark"]
copy = ["cache"]
pass_env = ["MANA_LAB"]
timeout = "1m"
check_timeout = "1m"

[env]
LAB_URL = "postgres://lab"

[submodules]
sub = "$sub"

[conditions.moments]
summary = "as it is"

[conditions.none]
summary = "no Moments"
[[conditions.none.strip]]
files = ["AGENTS.md", "missing.md"]
pattern = 'moments'
ignore_case = true
[conditions.none.replace]
"tools/moments" = "#!/bin/sh\\necho unavailable\\nexit 127\\n"

[agents.fake]
command = ["sh", "${p.join(root, 'agent.sh')}", "{prompt}", "{model}"]
model = "fix"
usage = "claude-json"
unset = ["CLAUDECODE"]
''');
    write(p.join(suite, 'tasks/price/prompt.md'), 'The price must be 90.\n');
    write(p.join(suite, 'tasks/price/hidden/app/extra_test.sh'), 'exit 0\n');
    write(p.join(suite, 'tasks/price/task.toml'), '''
kind = "bug"
summary = "price"
commit = "$fix"
hidden = ["app/price_test.sh"]

[[check]]
id = "price"
run = ["sh", "app/price_test.sh"]

[[check]]
id = "extra"
run = ["sh", "app/extra_test.sh"]

[[heldout]]
id = "suite"
run = ["sh", "-c", "n=0; for f in \\"\$@\\"; do sh \\"\$f\\" || n=\$((n+1)); done; echo \\"\$n failures\\"; [ \$n -eq 0 ]", "sh", "{files}"]
files = "app/*_test.sh"
count = '(\\d+) failures'
''');
  });
  tearDown(() => Directory(root).deleteSync(recursive: true));

  BenchmarkRunner runner({
    String agent = 'fake',
    String? model,
    Duration? timeout,
  }) => BenchmarkRunner(
    Benchmark.load(suite),
    repo: repo,
    out: p.join(root, 'out-$agent-${model ?? ''}'),
    work: p.join(root, 'work'),
    agent: agent,
    model: model,
    timeout: timeout,
  );

  Map<String, String> seen(String id) => {
    for (final line in File(
      p.join(root, 'work', 'seen-$id.txt'),
    ).readAsLinesSync())
      line.substring(0, line.indexOf('=')): line.substring(
        line.indexOf('=') + 1,
      ),
  };

  test('loads the tasks, conditions and agents', () {
    final benchmark = Benchmark.load(suite);
    expect([for (final t in benchmark.tasks) t.id], ['price']);
    final task = benchmark.tasks.single;
    expect(task.kind, 'bug');
    expect(task.revert, ['**']);
    expect(task.extraHidden, ['app/extra_test.sh']);
    expect([for (final c in benchmark.conditions) c.name], ['moments', 'none']);
    expect(benchmark.agents['fake']!.usage, 'claude-json');
    write(p.join(suite, 'tasks/empty/task.toml'), 'commit = "HEAD"\n');
    write(p.join(suite, 'tasks/empty/prompt.md'), 'Do it.\n');
    expect(
      () => Benchmark.load(suite),
      throwsA(
        isA<ManaFailure>().having(
          (f) => f.message,
          'message',
          contains('no [[check]]'),
        ),
      ),
    );
  });

  test(
    'an agent works in a copy without history, hidden files or the benchmark',
    () async {
      final bench = runner();
      final runs = bench.plan();
      expect(
        [for (final r in runs) BenchmarkRunner.runId(r)],
        ['price-moments-1', 'price-none-1'],
      );
      final results = await bench.run(runs);
      final moments = seen('price-moments-1'), none = seen('price-none-1');
      expect(moments['prompt'], 'Work without asking.||The price must be 90.');
      expect(moments['files'], 'app/lib.sh app/name_test.sh ');
      expect(moments['commits'], '1');
      expect(moments['framework'], 'readme ');
      expect(moments['cache'], 'compiled');
      expect(moments['lab'], 'postgres://lab other=unset');
      expect(moments['agents'], 'Prove it with Moments.|Keep it small.|');
      expect(moments['moments'], 'real runner');
      expect(none['agents'], 'Keep it small.|');
      expect(none['moments'], 'unavailable');
      expect(results.first['submodules'], {
        'sub': git(sub, ['rev-parse', 'HEAD~1']),
      });
      expect(results.last['strippedLines'], 1);
      for (final r in results) {
        expect(r['error'], isNull);
        expect(r['success'], isTrue);
        expect(r['heldoutFailures'], 0);
        expect(r['tokens'], {
          'input': 10,
          'output': 5,
          'cacheRead': 100,
          'cacheCreation': 20,
        });
        expect(r['costUsd'], 0.25);
        expect(r['diff'], {'files': 1, 'insertions': 1, 'deletions': 1});
        expect(r['commit'], git(repo, ['rev-parse', 'HEAD~1']));
      }
      final patch = File(
        p.join(bench.out, 'runs/price-moments-1/diff.patch'),
      ).readAsStringSync();
      expect(patch, contains('+price() { echo 90; }'));
      expect(
        Directory(p.join(root, 'work', 'price-moments-1')).existsSync(),
        isFalse,
      );
      expect(
        File(p.join(bench.out, 'summary.md')).readAsStringSync(),
        benchmarkSummary(readResults(bench.resultsFile)),
      );
      final again = await bench.run(runs);
      expect(again, isEmpty);
      expect(readResults(bench.resultsFile), hasLength(2));
    },
  );

  test(
    'the hidden checks score the result, held-out tests count the bugs',
    () async {
      Future<Map<String, Object?>> one(String agent, [String? model]) async {
        final bench = runner(agent: agent, model: model);
        return (await bench.run(bench.plan(conditions: ['moments']))).single;
      }

      final broke = await one('fake', 'break');
      expect(broke['success'], isTrue);
      expect(broke['heldoutFailures'], 1);
      expect(
        (broke['heldout']! as List).single,
        containsPair('status', 'fail'),
      );

      final cheat = await one('fake', 'cheat');
      expect(cheat['success'], isFalse);
      expect(
        (cheat['checks']! as List).first,
        allOf(containsPair('id', 'price'), containsPair('status', 'fail')),
      );

      final noop = await one('noop');
      expect(noop['success'], isFalse);
      expect(noop['heldoutFailures'], 0);
      final oracle = await one('oracle');
      expect(oracle['success'], isTrue);
      expect(oracle['heldoutFailures'], 0);
      expect(oracle['diff'], {'files': 1, 'insertions': 1, 'deletions': 1});
    },
  );

  test('a timeout stops the agent and what it started', () async {
    final bench = runner(model: 'sleep', timeout: const Duration(seconds: 1));
    final watch = Stopwatch()..start();
    final result = (await bench.run(
      bench.plan(conditions: ['moments']),
    )).single;
    expect(watch.elapsed, lessThan(const Duration(seconds: 15)));
    expect(result['timedOut'], isTrue);
    expect(result['agentExit'], 124);
    expect(result['success'], isFalse);
    final left = Process.runSync('pgrep', ['-f', 'sleep 30']);
    expect((left.stdout as String).trim(), isEmpty);
  });

  test('a hidden path the commit does not change is refused', () async {
    final task = File(p.join(suite, 'tasks/price/task.toml'));
    task.writeAsStringSync(
      task.readAsStringSync().replaceFirst(
        'hidden = ["app/price_test.sh"]',
        'hidden = ["app/name_test.sh"]',
      ),
    );
    final bench = runner();
    final result = (await bench.run(
      bench.plan(conditions: ['moments']),
    )).single;
    expect(result['error'], contains('app/name_test.sh is not changed'));
  });

  test('{files} leaves out hidden files and those a command excepts', () {
    final workspace = p.join(root, 'files');
    for (final path in [
      'api/test/a_test.sh',
      'api/test/b_test.sh',
      'api/test/c_test.sh',
      'api/lib.sh',
    ]) {
      write(p.join(workspace, path), '');
    }
    expect(
      BenchmarkRunner.matchingFiles(
        workspace,
        'api/test/*_test.sh',
        root: 'api',
        except: {'api/test/a_test.sh'},
        exceptGlobs: ['api/test/c_*'],
      ),
      ['test/b_test.sh'],
    );
  });

  test('the environment drops Mana variables but the ones passed', () {
    final bench = runner();
    expect(
      bench.environment(
        unset: ['CLAUDECODE'],
        from: {
          'PATH': '/bin',
          'MANA_FRAMEWORK': '/elsewhere',
          'MOMENTS_INSTANCE': 'x',
          'MANA_LAB': 'kept',
          'CLAUDECODE': '1',
        },
      ),
      {'PATH': '/bin', 'MANA_LAB': 'kept', 'LAB_URL': 'postgres://lab'},
    );
  });

  test('a dry run prints each command and runs nothing', () async {
    final lines = <String>[];
    final code = await benchmarkCommand(
      [
        '--suite',
        suite,
        '--repo',
        repo,
        '--agent',
        'fake',
        '--work',
        p.join(root, 'w'),
        '--dry-run',
      ],
      frameworkRoot: root,
      print: lines.add,
    );
    expect(code, 0);
    expect(
      lines.first,
      startsWith(
        'price-moments-1: cd ${p.join(root, 'w', 'price-moments-1')} && sh ',
      ),
    );
    expect(
      lines.first,
      endsWith("'Work without asking.\n\nThe price must be 90.' fix"),
    );
    expect(
      lines.last,
      '2 runs, at most 1 min of agent time each; nothing ran.',
    );
    expect(Directory(p.join(root, 'w')).existsSync(), isFalse);
  });

  test(
    'validate wants checks that fail untouched and pass on the commit',
    () async {
      final lines = <String>[];
      final code = await benchmarkCommand(
        [
          'validate',
          '--suite',
          suite,
          '--repo',
          repo,
          '--work',
          p.join(root, 'w'),
          '--out',
          p.join(root, 'v'),
        ],
        frameworkRoot: root,
        print: lines.add,
      );
      expect(code, 0);
      expect(lines.last, 'valid   price');
    },
  );

  test('the report is recomputed from the raw lines alone', () async {
    Map<String, Object?> run(
      String task,
      String condition,
      int repetition, {
      required bool success,
      int heldout = 0,
      double wall = 600,
      int tokens = 1000,
      double cost = 1,
      String? error,
    }) => {
      'benchmark': 'Fixture',
      'task': task,
      'kind': task == 'a' ? 'bug' : 'ui',
      'condition': condition,
      'repetition': repetition,
      'agent': 'claude',
      'model': 'opus',
      'wallSeconds': wall,
      'tokens': {
        'input': tokens,
        'output': 0,
        'cacheRead': 0,
        'cacheCreation': 0,
      },
      'costUsd': cost,
      'success': success,
      'heldoutFailures': heldout,
      'error': ?error,
    };
    final runs = [
      run('a', 'moments', 1, success: true, wall: 300),
      run(
        'a',
        'none',
        1,
        success: false,
        heldout: 2,
        wall: 900,
        tokens: 3000,
        cost: 3,
      ),
      run('b', 'moments', 1, success: true, wall: 420, tokens: 2000, cost: 2),
      run('b', 'none', 1, success: true, heldout: 1, wall: 600, tokens: 1500),
      run('b', 'none', 2, success: false, error: 'prepare failed'),
    ];
    const expected = '''
# Fixture benchmark

5 runs: 2 tasks × 2 conditions, agent claude opus. 1 runs failed in the harness and are not scored.

| Condition | Runs | Success | Median wall time | Mean tokens | Mean cost | Held-out failures | Runs with a held-out failure |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| moments | 2 | 2 (100%) | 6.0 min | 1,500 | \$1.50 | 0 | 0 |
| none | 2 | 1 (50%) | 12.5 min | 2,250 | \$2.00 | 3 | 2 |

## Per task

| Task | Kind | moments | none |
| --- | --- | --- | --- |
| a | bug | 1/1 | 0/1 (2 held-out) |
| b | ui | 1/1 | 1/1 (1 held-out) |

Success: every hidden check passes. Held-out failures: failing tests the agent never saw, outside the checks (bugs that reach the pull request). Tokens: input, output and cache, summed per run.
''';
    expect(benchmarkSummary(runs), expected);
    expect(benchmarkSummary(runs.reversed.toList()), expected);
    final file = File(p.join(root, 'results.jsonl'))
      ..writeAsStringSync(runs.map(jsonEncode).join('\n'));
    final lines = <String>[];
    expect(
      await benchmarkCommand(
        ['report', file.path],
        frameworkRoot: root,
        print: lines.add,
      ),
      0,
    );
    expect(lines.single, expected.trimRight());
  });

  test('usage comes from the result line of claude --output-format json', () {
    expect(
      claudeUsage(
        'noise\n{"type":"result","usage":{"input_tokens":3,"output_tokens":4},"total_cost_usd":0.1,"num_turns":2,"subtype":"error_max_budget_usd"}',
      ),
      {
        'tokens': {'input': 3, 'output': 4, 'cacheRead': 0, 'cacheCreation': 0},
        'costUsd': 0.1,
        'turns': 2,
        'agentResult': 'error_max_budget_usd',
      },
    );
    expect(
      claudeUsage('{\n  "type": "result",\n  "usage": {"output_tokens": 7}\n}'),
      containsPair('tokens', {
        'input': 0,
        'output': 7,
        'cacheRead': 0,
        'cacheCreation': 0,
      }),
    );
    expect(claudeUsage('not json'), isEmpty);
  });
}
