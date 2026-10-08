import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _index = '<script src="flutter_bootstrap.js" async=""></script>';
const _bootstrap =
    '_flutter.buildConfig={"builds":[{"mainJsPath":"main.dart.js"}]};';

Directory _directory() {
  final directory = Directory.systemTemp.createTempSync('mana-pages-');
  addTearDown(() => directory.deleteSync(recursive: true));
  return directory;
}

void main() {
  test(
    'each changed release loads its own script even with a cached previous release',
    () {
      final directory = _directory().path;
      ({String entry, String script}) publish(String main) {
        File(p.join(directory, 'main.dart.js')).writeAsStringSync(main);
        File(
          p.join(directory, 'flutter_bootstrap.js'),
        ).writeAsStringSync(_bootstrap);
        File(p.join(directory, 'index.html')).writeAsStringSync(_index);
        versionWebAssets(directory);
        final html = File(p.join(directory, 'index.html')).readAsStringSync();
        final entry = RegExp('src="([^"]+)"').firstMatch(html)![1]!;
        final loader = File(p.join(directory, entry)).readAsStringSync();
        final script = RegExp('"mainJsPath":"([^"]+)"').firstMatch(loader)![1]!;
        expect(File(p.join(directory, script)).readAsStringSync(), main);
        expect(
          File(p.join(directory, 'main.dart.js')).readAsStringSync(),
          main,
        );
        return (entry: entry, script: script);
      }

      final old = publish('old login'), updated = publish('fixed login');
      expect(updated.entry, isNot(old.entry));
      expect(updated.script, isNot(old.script));
      expect(publish('fixed login'), updated);
    },
  );

  test('fails before changing HTML if the Flutter loader contract changes', () {
    final directory = _directory().path;
    File(p.join(directory, 'main.dart.js')).writeAsStringSync('app');
    File(
      p.join(directory, 'flutter_bootstrap.js'),
    ).writeAsStringSync('unknown loader');
    File(p.join(directory, 'index.html')).writeAsStringSync(_index);
    expect(
      () => versionWebAssets(directory),
      throwsA(
        isA<ManaFailure>().having(
          (e) => e.message,
          'message',
          contains('Unexpected Flutter'),
        ),
      ),
    );
    expect(File(p.join(directory, 'index.html')).readAsStringSync(), _index);
  });
}
