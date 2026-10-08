import 'dart:io';

import 'package:mana/mana.dart' show savePrivateState;
import 'package:moments/src/layers.dart';
import 'package:moments/src/materializer.dart';
import 'package:moments/src/protocol.dart';
import 'package:path/path.dart' as p;

final class _Files implements MaterializerRuntime {
  @override
  String get type => 'ash-flutter-local';
  @override
  Object allocate(World world) => Object();
  @override
  Future<void> start(Object handle, World world) async {}
  @override
  Future<void> stop(Object handle) async {}
  @override
  Null get executeJourney => null;
}

/// Leaves behind one materialized run of `args.first` and prints its home.
Future<void> main(List<String> args) async {
  final project = args.first, base = p.join(project, 'moments'), initial = p.join(base, 'initial');
  Directory(initial).createSync();
  savePrivateState(p.join(initial, 'ui-session.json'), {
    'version': 2,
    'active': 'root',
    'states': {
      'root': {
        'name': 'root',
        'projection': {'route': '/'},
      },
    },
  });
  savePrivateState(p.join(initial, 'actor-state.json'), {
    'version': 1,
    'values': {'session': 'test-only'},
  });
  const actor = FlutterActorLayer();
  final root = p.join(base, 'actor-root'), opts = LayerOptions(assertStopped: (_) {});
  await actor.capture(handle: FlutterActorLayer.sourceHandle(initial), out: root, opts: opts);
  final manifestFile = p.join(base, 'manifest.json');
  savePrivateState(manifestFile, {
    'version': 3,
    'protocol': protocol,
    'watch': <Object?>[],
    'properties': {
      'route': {
        'enum': ['/'],
      },
    },
    'moments': {
      'root': {
        'projection': {'route': '/'},
        'checks': <Object?>[],
        'backend': {'recipe': 'root'},
      },
    },
  });
  final engine = Materializer.create(
    project: project,
    manifestFile: manifestFile,
    directory: p.join(base, 'runs'),
    layers: [(name: 'actor', driver: actor, root: root, opts: opts)],
    scope: 'CLI file-only mechanism test; no app runtime',
    runtime: _Files(),
    codeIdentity: () => 'a' * 64,
    recipes: {'root': (_) async {}},
  );
  await engine.open('root');
  stdout.write(engine.home);
  exit(0);
}
