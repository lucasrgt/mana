import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// fixtures/client/generated is dart-dio 7.25.0's output for
// fixtures/client/contract.json as its templates render it, cut to the files
// the patches touch; fixtures/client/patched is what the RegExp patches the AST
// edits replaced made of it. Both end in .txt so the analyzer skips them.
final _fixtures = p.join('test', 'fixtures', 'client');

/// Each file under [root] by its relative path, less [suffix].
Map<String, List<int>> _tree(String root, {String suffix = ''}) => {
  for (final file in Directory(
    root,
  ).listSync(recursive: true).whereType<File>())
    p.relative(file.path, from: root).replaceFirst(RegExp('$suffix\$'), ''):
        file.readAsBytesSync(),
};

const _serializers = '''
Serializers serializers = (_\$serializers.toBuilder()
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(Item)]),
        () => ListBuilder<Item>(),
      )
      ..add(const OneOfSerializer())
    ).build();
''';

String _read(String declared, String fullType) =>
    '''
void f() {
  _responseData = rawResponse == null ? null : _serializers.deserialize(
    rawResponse,
    specifiedType: const $fullType,
  ) as $declared;
}
''';

void main() {
  test('the fixture contract generates the same client bytes as before', () {
    final stage = Directory.systemTemp.createTempSync('mana-client-');
    addTearDown(() => stage.deleteSync(recursive: true));
    _tree(p.join(_fixtures, 'generated'), suffix: '.txt').forEach((
      path,
      bytes,
    ) {
      File(p.join(stage.path, path))
        ..createSync(recursive: true)
        ..writeAsBytesSync(bytes);
    });

    patchGeneratedClient(stage.path);

    final expected = _tree(p.join(_fixtures, 'patched'), suffix: '.txt');
    final actual = _tree(stage.path);
    expect(actual.keys.toSet(), expected.keys.toSet());
    for (final path in expected.keys) {
      expect(actual[path], expected[path], reason: path);
    }
  });

  group('withoutRepeatedImports', () {
    test('drops an import repeated word for word, keeps the first', () {
      expect(
        withoutRepeatedImports('''
import 'package:built_value/json_object.dart';
import 'package:dio/dio.dart';

import 'package:built_collection/built_collection.dart';
import 'package:built_value/json_object.dart';
import 'package:x/src/api_util.dart';

class A {}
'''),
        '''
import 'package:built_value/json_object.dart';
import 'package:dio/dio.dart';

import 'package:built_collection/built_collection.dart';
import 'package:x/src/api_util.dart';

class A {}
''',
      );
    });

    test('keeps imports of the same library that differ', () {
      const source = '''
import 'package:built_value/json_object.dart';
import 'package:built_value/json_object.dart' as json;
''';
      expect(withoutRepeatedImports(source), source);
    });
  });

  group('readListsAsLists', () {
    test('a list response is read as the BuiltList it declares', () {
      final read = readListsAsLists(
        _read('BuiltList<Item>', 'FullType(BuiltSet, [FullType(Item)])'),
      );
      expect(
        read.source,
        _read('BuiltList<Item>', 'FullType(BuiltList, [FullType(Item)])'),
      );
      expect(read.types, {'Item'});
      expect(readListsAsLists(read.source).types, isEmpty);
    });

    test('a set response and a mismatched element stay as written', () {
      for (final source in [
        _read('BuiltSet<String>', 'FullType(BuiltSet, [FullType(String)])'),
        _read('BuiltList<Item>', 'FullType(BuiltSet, [FullType(Note)])'),
        _read('BuiltList<Item>?', 'FullType(BuiltSet, [FullType(Item)])'),
      ]) {
        final read = readListsAsLists(source);
        expect(read.source, source);
        expect(read.types, isEmpty);
      }
    });
  });

  group('withListBuilders', () {
    test('registers each missing list builder, in order, once', () {
      expect(
        withListBuilders(_serializers, ['Item', 'Note', 'Tag']),
        _serializers.replaceFirst('\n    ).build();', '''

      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(Note)]),
        () => ListBuilder<Note>(),
      )
      ..addBuilderFactory(
        const FullType(BuiltList, [FullType(Tag)]),
        () => ListBuilder<Tag>(),
      )
    ).build();'''),
      );
      expect(withListBuilders(_serializers, ['Item']), _serializers);
    });

    test('refuses serializers it cannot find the cascade of', () {
      expect(
        () => withListBuilders('final serializers = 1;\n', ['Note']),
        throwsA(isA<ManaFailure>()),
      );
      expect(withListBuilders('final serializers = 1;\n', []), isNotEmpty);
    });
  });
}
