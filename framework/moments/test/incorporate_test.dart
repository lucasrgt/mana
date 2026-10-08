import 'dart:convert';
import 'dart:io';

import 'package:moments/src/incorporate.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

final class Fixture {
  Fixture() : root = temporary('live-incorporate-') {
    Directory(p.join(root, 'live-ui')).createSync();
    Directory(p.join(root, 'lib')).createSync();
    json('live-ui/schema.json', {
      'title': {'type': 'text', 'maxLength': 80},
      'gap': {
        'enum': ['lg', 'xl'],
      },
    });
    json('live-ui/overrides.json', {
      'version': 1,
      'values': {'title': r'A "quoted" \ label $1', 'gap': 'xl'},
    });
    json('live-ui/targets.json', {
      'title': {'kind': 'arb', 'file': 'lib/app.arb', 'key': 'title'},
      'gap': {'kind': 'dartEnum', 'file': 'lib/style.dart', 'type': 'SpaceToken', 'symbol': 'gap'},
    });
    write('lib/app.arb', '{\n  "title": "Before",\n  "untouched": "Keep me"\n}\n');
    write('lib/style.dart', '// handwritten comment\nconst gap = SpaceToken.lg;\n');
  }

  final String root;
  void json(String name, Object? value) => write(name, '${const JsonEncoder.withIndent('  ').convert(value)}\n');
  void write(String name, String text) => File(p.join(root, name)).writeAsStringSync(text);
  String read(String name) => File(p.join(root, name)).readAsStringSync();
  Map<String, Object?> arb() => (jsonDecode(read('lib/app.arb')) as Map).cast();
}

void main() {
  test('review is read-only; incorporation preserves hand edits and produces ordinary source', () {
    final f = Fixture();
    final before = f.read('lib/app.arb'), overrides = f.read('live-ui/overrides.json');
    final plan = savePlan(f.root);
    expect((plan['changes']! as List).length, 2);
    expect(f.read('lib/app.arb'), before);
    expect((applyPlan(f.root)['written']! as List).length, 2);
    expect(f.arb()['title'], r'A "quoted" \ label $1');
    expect(f.arb()['untouched'], 'Keep me');
    expect(f.read('lib/style.dart'), '// handwritten comment\nconst gap = SpaceToken.xl;\n');
    expect(f.read('live-ui/overrides.json'), overrides);
    expect((savePlan(f.root)['changes']! as List).length, 0);
    expect(applyPlan(f.root)['written'], <Object?>[]);
  });

  test('source changes or a newer preview invalidate the plan before any writes', () {
    final f = Fixture();
    savePlan(f.root);
    f.write('lib/style.dart', '// concurrent change\nconst gap = SpaceToken.lg;\n');
    expect(() => applyPlan(f.root), throwing('changed since planning'));
    expect(f.arb()['title'], 'Before');
    savePlan(f.root);
    f.json('live-ui/overrides.json', {
      'version': 1,
      'values': {'title': 'New revision', 'gap': 'xl'},
    });
    expect(() => applyPlan(f.root), throwing('changed since planning'));
    expect(f.arb()['title'], 'Before');
  });

  test('invalid tokens, ICU labels and ambiguous bindings never modify source', () {
    final f = Fixture();
    final before = f.read('lib/app.arb');
    f.json('live-ui/overrides.json', {
      'version': 1,
      'values': {'gap': 'xl; injected()'},
    });
    expect(() => savePlan(f.root), throwing('expected'));
    f.json('live-ui/overrides.json', {
      'version': 1,
      'values': {'title': '{name}'},
    });
    expect(() => savePlan(f.root), throwing('ICU'));
    f.json('live-ui/overrides.json', {
      'version': 1,
      'values': {'gap': 'xl'},
    });
    f.write('lib/style.dart', 'const gap = SpaceToken.lg;\nconst gap = SpaceToken.lg;\n');
    expect(() => savePlan(f.root), throwing('exactly one'));
    expect(f.read('lib/app.arb'), before);
  });

  test('a forged plan and a symlink outside lib cannot choose a write target', () {
    final f = Fixture();
    final plan = savePlan(f.root);
    ((plan['files']! as List).first as Map)['file'] = '../outside';
    f.json('live-ui/.incorporate-plan.json', plan);
    expect(() => applyPlan(f.root), throwing('changed since planning'));
    Link(p.join(f.root, 'lib/escape.arb')).createSync(p.join(f.root, 'live-ui/schema.json'));
    f.json('live-ui/targets.json', {
      'title': {'kind': 'arb', 'file': 'lib/escape.arb', 'key': 'title'},
    });
    f.json('live-ui/overrides.json', {
      'version': 1,
      'values': {'title': 'Bad target'},
    });
    expect(() => planIncorporation(f.root), throwing('escapes lib'));
  });

  test('a write failure rolls back files already replaced', () {
    final f = Fixture();
    savePlan(f.root);
    final style = f.read('lib/style.dart');
    // gap sorts before title: the second file replacement fails.
    f.write('lib/app.arb.live-ui.tmp', 'existing temp');
    expect(() => applyPlan(f.root), throwing('File exists'));
    expect(f.read('lib/style.dart'), style);
    expect(f.arb()['title'], 'Before');
  });

  test('a screen prefix only incorporates that screen and cannot change between plan and write', () {
    final f = Fixture();
    f.json('live-ui/schema.json', {
      'review.title': {'type': 'text', 'maxLength': 80},
      'signup.title': {'type': 'text', 'maxLength': 80},
    });
    f.json('live-ui/targets.json', {
      'review.title': {'kind': 'arb', 'file': 'lib/app.arb', 'key': 'title'},
      'signup.title': {'kind': 'arb', 'file': 'lib/app.arb', 'key': 'untouched'},
    });
    f.json('live-ui/overrides.json', {
      'version': 1,
      'values': {'review.title': 'Reviewed title', 'signup.title': 'Leave as preview'},
    });
    final plan = savePlan(f.root, prefix: 'review.');
    expect([for (final change in (plan['changes']! as List).cast<Map>()) change['property']], ['review.title']);
    expect(() => applyPlan(f.root), throwing('changed since planning'));
    expect(() => applyPlan(f.root, prefix: 'signup.'), throwing('changed since planning'));
    expect(f.arb()['title'], 'Before');
    applyPlan(f.root, prefix: 'review.');
    expect(f.arb()['title'], 'Reviewed title');
    expect(f.arb()['untouched'], 'Keep me');
    expect(
      ((jsonDecode(f.read('live-ui/overrides.json')) as Map)['values'] as Map)['signup.title'],
      'Leave as preview',
    );
    expect(() => savePlan(f.root, prefix: 'review'), throwing('prefix ending'));
    expect(() => savePlan(f.root, prefix: 'missing.'), throwing('Unknown property prefix'));
  });
}
