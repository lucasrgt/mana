import 'dart:async';
import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState;
import 'package:moments/src/browser.dart';
import 'package:moments/src/cli.dart';
import 'package:moments/src/composition.dart';
import 'package:moments/src/layers.dart';
import 'package:moments/src/managed.dart';
import 'package:moments/src/materializer.dart';
import 'package:path/path.dart' as p;

/// Composition fixture. [mode] is normal, prepare-fails, wait, crash or
/// cleanup-fails; events are appended to `<project>/events`.
final class TestComposition implements CompositionProfile {
  TestComposition(this.context, this.mode);
  final CompositionContext context;
  final String mode;
  BrowserBoundary? _boundary;

  void note(String event) =>
      File(p.join(context.project, 'events')).writeAsStringSync('$event\n', mode: FileMode.append);

  @override
  Map<String, Object?> get recovery => {
    'processes': <String>[],
    'containers': <String>[],
    'roots': <Object>[],
    'browsers': [if (mode == 'crash') 'surface'],
  };

  @override
  Future<void> prepare({required Interruption signal}) async {
    note('prepare');
    if (mode == 'prepare-fails') throw StateError('private-input-must-not-leak');
    if (mode == 'wait') {
      final aborted = Completer<void>();
      signal.onAbort(aborted.complete);
      await aborted.future;
    }
    if (mode == 'crash') {
      final dir = p.join(context.directory, 'surface');
      Directory(dir).createSync();
      await (_boundary = allocateBrowserBoundary(dir)).open('http://127.0.0.1:54321/', context.browserProvider);
    }
  }

  @override
  Future<CompositionConnection> connect({required String surface, required String moment}) async =>
      CompositionConnection(
        request: (path, [_]) async {
          note('observe');
          if (mode == 'crash') await Completer<void>().future;
          const projection = {'phase': 'ready'};
          if (path == '/moments/look') {
            return {
              'revision': 1,
              'observed': {'client': 'client-a', 'projection': projection},
            };
          }
          return {
            'moment': {'revision': 1},
            'screen': {
              'lastReported': {'matchesRevision': true, 'projection': projection},
            },
          };
        },
      );

  @override
  Future<void> cleanup({required bool passed}) async {
    note('cleanup');
    if (mode == 'cleanup-fails') throw StateError('private-cleanup-error');
    await _boundary?.close(context.browserProvider);
  }

  @override
  Null get beforeStage => null;
  @override
  Null get afterStage => null;
  @override
  Null get verify => null;
}

final class _Files implements MaterializerRuntime {
  @override
  String get type => 'ash-flutter-local';
  @override
  Object allocate(World world) => {'url': 'http://example.invalid'};
  @override
  Future<void> start(Object handle, World world) async {}
  @override
  Future<void> stop(Object handle) async {}
  @override
  Null get executeJourney => null;
}

/// File-only crash fixture: an actor root and a private JSON root, no app.
final class CrashMaterialization implements MaterializationProfile {
  CrashMaterialization(String directory)
    : _root = p.join(directory, 'actor-root'),
      _mail = p.join(directory, 'mailbox-root'),
      _initial = p.join(directory, 'initial');
  final String _root, _mail, _initial;
  final _opts = LayerOptions(assertStopped: (_) {});
  static const _actor = FlutterActorLayer(), _json = PrivateJsonLayer();

  @override
  Map<String, Object?> get recovery => {
    'processes': <String>[],
    'containers': <String>[],
    'roots': [
      {'name': 'actor-root', 'type': 'flutter-actor'},
      {'name': 'mailbox-root', 'type': 'private-json'},
    ],
  };

  @override
  String codeIdentity() => 'a' * 64;

  @override
  late final engine = MaterializationEngine(
    scope: 'File-only crash mechanism; no application/browser',
    layers: [
      (name: 'actor', driver: _actor, root: _root, opts: _opts),
      (name: 'mailbox', driver: _json, root: _mail, opts: _opts),
    ],
    recipes: {'root': (_) async {}},
    runtime: _Files(),
  );

  @override
  Future<void> prepare({
    required Interruption signal,
    required void Function(Map<String, Object?> event) onProgress,
  }) async {
    Directory(_initial).createSync();
    Process.runSync('chmod', ['700', _initial]);
    savePrivateState(p.join(_initial, 'state.json'), {
      'messages': ['opaque-local-capture'],
    });
    await _json.capture(handle: PrivateJsonLayer.sourceHandle(_initial), out: _mail, opts: _opts);
    savePrivateState(p.join(_initial, 'ui-session.json'), {
      'version': 2,
      'active': 'root',
      'states': {
        'root': {
          'name': 'root',
          'projection': {'route': '/'},
        },
      },
    });
    savePrivateState(p.join(_initial, 'actor-state.json'), {'version': 1, 'values': <String, Object?>{}});
    await _actor.capture(handle: FlutterActorLayer.sourceHandle(_initial), out: _root, opts: _opts);
  }

  @override
  Future<void> cleanup() async {
    await _actor.forget(dir: _root);
    await _json.forget(dir: _mail);
  }
}

/// The project program a killed supervisor runs; `MANA_TEST_MODE` selects the fixture.
Future<void> main(List<String> args) async {
  final mode = Platform.environment['MANA_TEST_MODE'] ?? 'normal';
  exitCode = await runCli(
    args,
    adapters: ProjectAdapters(
      composition: (context) => TestComposition(context, mode),
      materialization: (context) => CrashMaterialization(context.directory),
    ),
  );
}
