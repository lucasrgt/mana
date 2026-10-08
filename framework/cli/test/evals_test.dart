import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('an eval checks what the agent added and what commands say', () async {
    final root = Directory.systemTemp
        .createTempSync('mana-eval-')
        .resolveSymbolicLinksSync();
    addTearDown(() => Directory(root).deleteSync(recursive: true));
    void write(String path, String text) => (File(
      p.join(root, path),
    )..createSync(recursive: true)).writeAsStringSync(text);
    void git(List<String> args) =>
        Process.runSync('git', args, workingDirectory: root);
    write('backend/point.ex', 'attribute :name, :string\n');
    write('evals/cnpj/task.md', 'Add a CNPJ to points.\n');
    write('evals/cnpj/checks.toml', r'''
[[check]]
id = "server-type"
kind = "diff"
files = "backend/**"
pattern = ':cnpj,\s*Mana\.BR\.Cnpj'

[[check]]
id = "no-hand-check"
kind = "diff"
pattern = '\\d\{14\}'
absent = true

[[check]]
id = "builds"
kind = "command"
run = ["sh", "-c", "test -f backend/point.ex"]

[[check]]
id = "fails"
kind = "command"
run = ["sh", "-c", "echo nope; exit 3"]
''');
    git(['init', '-q']);
    git(['-c', 'user.email=a@b', '-c', 'user.name=a', 'add', '.']);
    git(['-c', 'user.email=a@b', '-c', 'user.name=a', 'commit', '-qm', 'base']);
    write(
      'backend/point.ex',
      'attribute :name, :string\nattribute :cnpj, Mana.BR.Cnpj\n',
    );
    write('apps/os/lib/form.dart', "final cnpj = RegExp(r'^\\d{14}\$');\n");

    expect(AgentEval.list(root), ['cnpj']);
    final eval = AgentEval.load(root, 'cnpj');
    expect(eval.task, 'Add a CNPJ to points.');
    final verdict = await eval.check(root);
    final status = {
      for (final r in (verdict['results']! as List).cast<Map>())
        r['criterionId']: r['status'],
    };
    expect(status, {
      'server-type': 'pass',
      'no-hand-check': 'fail',
      'builds': 'pass',
      'fails': 'fail',
    });
    expect(verdict['outcome'], 'fail');
    expect(verdict['acceptanceScore'], 0.5);
    expect(
      AgentEval.usage(
        '{"usage": {"input_tokens": 3}, "total_cost_usd": 0.1, "num_turns": 4}',
      ),
      {
        'usage': {'input_tokens': 3},
        'cost': 0.1,
        'turns': 4,
      },
    );
    expect(AgentEval.usage('not json'), isNull);
    expect(() => AgentEval.load(root, 'missing'), throwsA(isA<ManaFailure>()));
  });
}
