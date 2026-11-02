import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory backend;

  setUp(() {
    backend = Directory.systemTemp.createTempSync('mana-style')
      ..createSync(recursive: true);
    File(p.join(backend.path, '.formatter.exs')).writeAsStringSync('[]');
    File(p.join(backend.path, 'mix.exs')).writeAsStringSync(
      'defp deps, do: [{:credo, "~> 1.7", only: [:dev, :test], runtime: false}]',
    );
    File(
      p.join(backend.path, '.credo.exs'),
    ).writeAsStringSync('%{configs: [%{name: "default", strict: true}]}');
    File(p.join(backend.path, 'lib/app.ex'))
      ..createSync(recursive: true)
      ..writeAsStringSync('defmodule App do\nend\n');
  });
  tearDown(() => backend.deleteSync(recursive: true));

  test('a backend formatted and linted strictly has no gaps', () {
    expect(elixirStyleGaps(backend.path), isEmpty);
  });

  test('missing pieces, relaxed checks and silenced findings are gaps', () {
    File(p.join(backend.path, '.formatter.exs')).deleteSync();
    File(p.join(backend.path, '.credo.exs')).writeAsStringSync(
      '%{configs: [%{name: "default", checks: %{disabled: [{Credo.Check.Design.AliasUsage, []}]}}]}',
    );
    File(p.join(backend.path, 'lib/app.ex')).writeAsStringSync(
      '# credo:disable-for-next-line\ndefmodule App do\nend\n',
    );
    final name = p.basename(backend.path);
    expect(elixirStyleGaps(backend.path), [
      '$name has no .formatter.exs',
      '$name/.credo.exs is not strict',
      '$name/.credo.exs switches checks off',
      '$name/lib/app.ex silences Credo',
    ]);
  });
}
