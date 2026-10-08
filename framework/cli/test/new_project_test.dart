import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('a new project needs a valid name and an empty folder', () async {
    final parent = Directory.systemTemp.createTempSync('mana-new-');
    addTearDown(() => parent.deleteSync(recursive: true));

    expect(
      () => newProject(p.join(parent.path, 'Bad-Name')),
      throwsA(isA<ManaFailure>()),
    );
    final taken = Directory(p.join(parent.path, 'taken'))..createSync();
    File(p.join(taken.path, 'keep')).writeAsStringSync('');
    expect(() => newProject(taken.path), throwsA(isA<ManaFailure>()));
  });

  test('the template names the project everywhere it must', () {
    final template = Directory(p.join(frameworkRoot(), 'cli/templates/new'));
    final files = template.listSync(recursive: true).whereType<File>().toList();
    expect(
      files.map((f) => p.relative(f.path, from: template.path)),
      contains('mana.toml'),
    );
    final text = [for (final file in files) file.readAsStringSync()].join('\n');
    expect(text, contains('__Name__.Moments.App'));
    expect(text, contains('"name": "__dash__-api"'));
  });
}
