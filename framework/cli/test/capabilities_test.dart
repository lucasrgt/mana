import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String framework() => p.normalize(p.join(Directory.current.path, '..'));

void main() {
  test(
    'the framework catalog loads and every entry points to existing docs',
    () {
      final catalog = Catalog.load(framework());
      expect(catalog.capabilities, isNotEmpty);
      for (final c in catalog.capabilities) {
        final docs = p.join(framework(), '..', c.docs);
        expect(
          File(docs).existsSync() || Directory(docs).existsSync(),
          isTrue,
          reason: '${c.id}: ${c.docs}',
        );
      }
    },
  );

  test(
    'search ranks by matched words, folds accents and hides planned pieces by default',
    () {
      final catalog = Catalog.load(framework());
      expect(catalog.search('validate cpf').first.id, 'mana-br');
      expect(catalog.search('profile photo').first.id, 'uploads');
      expect(catalog.search('séssion').first.id, 'session');
      expect(catalog.search('verb').first.id, 'verbs');
      expect(
        catalog.search('a').every((c) => c.status == 'available'),
        isTrue,
      );
      expect(
        catalog.search('a', all: true).length,
        greaterThanOrEqualTo(catalog.search('a').length),
      );
    },
  );

  test('the committed agent skill is the one the catalog generates', () {
    final catalog = Catalog.load(framework());
    final skill = File(
      p.join(framework(), 'agents/skills/mana/SKILL.md'),
    ).readAsStringSync();
    expect(skill, catalog.skill(), reason: 'run mana capabilities skill');
  });

  test('invalid catalogs are refused', () {
    final dir = Directory.systemTemp.createTempSync('mana-catalog-');
    addTearDown(() => dir.deleteSync(recursive: true));
    for (final body in [
      'version = 2\n',
      'version = 1\n',
      'version = 1\n[[capability]]\nid = "a"\n',
      'version = 1\n[[capability]]\nid = "a"\nname = "A"\nlayer = "x"\nstatus = "available"\nsummary = "s"\nuse = "u"\ndocs = "d"\n',
    ]) {
      File(p.join(dir.path, 'catalog.toml')).writeAsStringSync(body);
      expect(
        () => Catalog.load(dir.path),
        throwsA(isA<ManaFailure>()),
        reason: body,
      );
    }
  });
}
