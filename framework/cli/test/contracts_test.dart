import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

typedef _Fixture = ({
  Map<String, dynamic> spec,
  Map<String, Object?> Function() compare,
});

_Fixture _fixture() {
  final dir = Directory.systemTemp.createTempSync('mana-contract-');
  addTearDown(() => dir.deleteSync(recursive: true));
  Map<String, dynamic> content(String name) => {
    'application/json': {
      'schema': {r'$ref': '#/components/schemas/$name'},
    },
  };
  final spec = <String, dynamic>{
    'openapi': '3.0.0',
    'info': {'title': 'Contract fixture', 'version': '1'},
    'paths': {
      '/items': {
        'post': {
          'operationId': 'createItem',
          'requestBody': {'required': true, 'content': content('Input')},
          'responses': {
            '200': {'description': 'OK', 'content': content('Output')},
          },
        },
      },
    },
    'components': {
      'schemas': {
        'Input': {
          'type': 'object',
          'required': ['name'],
          'properties': {
            'name': {'type': 'string'},
            'kind': {
              'type': 'string',
              'enum': ['one', 'two'],
            },
          },
        },
        'Output': {
          'type': 'object',
          'required': ['id', 'kind'],
          'properties': {
            'id': {'type': 'string'},
            'kind': {
              'type': 'string',
              'enum': ['one', 'two'],
            },
          },
        },
      },
    },
  };
  final base = p.join(dir.path, 'base.json'),
      candidate = p.join(dir.path, 'candidate.json');
  File(base).writeAsStringSync(jsonEncode(spec));
  return (
    spec: spec,
    compare: () {
      File(candidate).writeAsStringSync(jsonEncode(spec));
      return compareContracts(base, candidate);
    },
  );
}

Map<String, dynamic> _schema(_Fixture f, String name) =>
    f.spec['components']['schemas'][name] as Map<String, dynamic>;

void main() {
  setUpAll(installToolchain);

  test(
    'documentation and optional request/response fields preserve declared HTTP compatibility',
    () {
      final f = _fixture();
      f.spec['info']['description'] = 'New docs';
      _schema(f, 'Input')['properties']['note'] = {'type': 'string'};
      _schema(f, 'Output')['properties']['note'] = {'type': 'string'};
      expect(f.compare()['status'], 'compatible');
    },
  );

  test(
    'a new required request field and removal of an endpoint break old clients',
    () {
      final f = _fixture();
      (_schema(f, 'Input')['required'] as List).add('otp');
      _schema(f, 'Input')['properties']['otp'] = {'type': 'string'};
      final result = f.compare();
      expect(result['status'], 'breaking');
      expect(
        (result['changes']! as List).any(
          (c) =>
              c['id'] == 'new-required-request-property' &&
              c['operationId'] == 'createItem',
        ),
        isTrue,
      );
      (f.spec['paths'] as Map).remove('/items');
      expect(f.compare()['status'], 'breaking');
    },
  );

  test(
    'request and response enum changes have opposite compatibility directions',
    () {
      final f = _fixture();
      (_schema(f, 'Input')['properties']['kind']['enum'] as List).add('three');
      expect(f.compare()['status'], 'compatible');
      _schema(f, 'Input')['properties']['kind']['enum'] = ['one'];
      expect(f.compare()['status'], 'breaking');
      _schema(f, 'Input')['properties']['kind']['enum'] = ['one', 'two'];
      (_schema(f, 'Output')['properties']['kind']['enum'] as List).add('three');
      expect(f.compare()['status'], 'breaking');
    },
  );

  test(
    'responses cannot drop guaranteed properties or change their declared type silently',
    () {
      final f = _fixture();
      _schema(f, 'Output')['required'] = ['kind'];
      expect(f.compare()['status'], 'breaking');
      _schema(f, 'Output')['required'] = ['id', 'kind'];
      _schema(f, 'Output')['properties']['id']['type'] = 'integer';
      expect(f.compare()['status'], 'breaking');
    },
  );

  test(
    'missing references and external references are unavailable instead of compatible',
    () {
      final f = _fixture();
      final schema =
          f.spec['paths']['/items']['post']['requestBody']['content']['application/json']['schema']
              as Map;
      schema[r'$ref'] = '#/components/schemas/Missing';
      expect(
        f.compare,
        throwsA(
          isA<ManaFailure>().having(
            (e) => e.message,
            'message',
            contains('unavailable'),
          ),
        ),
      );
      schema[r'$ref'] = 'http://127.0.0.1:1/private.json';
      expect(
        f.compare,
        throwsA(
          isA<ManaFailure>().having(
            (e) => e.message,
            'message',
            contains('External contract references'),
          ),
        ),
      );
    },
  );

  test(
    'the report binds exact input hashes and explicitly limits its claim',
    () {
      final f = _fixture();
      final same = f.compare();
      expect(same['baseSha256'], same['candidateSha256']);
      expect(same['exitCode'], 0);
      f.spec['info']['description'] = 'Changed documentation';
      final changed = f.compare();
      expect(changed['baseSha256'], isNot(changed['candidateSha256']));
      expect(changed['status'], 'compatible');
      expect(changed['scope'], contains('not Dart source compatibility'));
    },
  );
}
