import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'declaration_sources.dart' show declarationRoots;
import 'errors.dart';
import 'format.dart';
import 'json.dart';
import 'manifest.dart';
import 'situations.dart' show RecipeCall, describeMove, explorations;

/// The exploration a Moment is, when a saved `Mana.Explore` trace declares it
/// (a `moments` section's `explorations` directory): its recipe is the trace,
/// its one criterion the property the trace broke.
Map<String, Object?>? explorationOf(Object? scene) =>
    scene is Map && scene['exploration'] is Map ? (scene['exploration']! as Map).cast() : null;

/// An exploration Moment has no screen to open: the suite runs it, and fork,
/// diff and trace evaluate its data.
void refuseExplorationUi(String manifestFile, String? name) {
  if (name == null || !File(manifestFile).existsSync()) return;
  if (explorationOf((readManifest(manifestFile)['moments']! as Map)[name]) != null) {
    throw MomentsError(
      '$name is an exploration Moment, with no screen to open: moments suite $name replays and checks it; fork, diff and trace evaluate its data',
    );
  }
}

/// [name]'s trace replayed in a database of its own, checking only the
/// property it broke: failed while the bug is there, passed once it is fixed.
/// A backend that cannot replay it makes the run unavailable, never passed.
Future<Map<String, Object?>> checkExploration(RecipeCall call, String name, Map<String, Object?> exploration) async {
  final started = nowMs();
  final trace = (exploration['trace']! as Map).cast<String, Object?>();
  final property = '${trace['property']}';
  Map<String, Object?> result(String status, {String? reason, Object? violation}) => {
    'name': name,
    'status': status,
    'durationMs': nowMs() - started,
    'checks': [
      if (status != 'unavailable') {'name': property, 'kind': 'property', 'status': status},
    ],
    'reason': ?reason,
    'violation': ?violation,
  };
  try {
    final answer = await call(explorations, 'check', {'trace': trace});
    return switch (answer) {
      {'status': 'passed'} => result('passed'),
      {'status': 'failed', 'violation': final Map violation} => result(
        'failed',
        reason: '$property breaks${violation['detail'] is String ? ': ${violation['detail']}' : ''}',
        violation: violation,
      ),
      _ => result('unavailable', reason: 'The backend did not check the exploration'),
    };
  } on MomentsError catch (error) {
    return result('unavailable', reason: error.message);
  }
}

/// The exploration Moments among [names], checked [workers] at a time; each
/// result is also [emit]ted as a suite `moment` event.
Future<List<Map<String, Object?>>> runExplorations({
  required RecipeCall call,
  required Map<String, Object?> moments,
  required List<String> names,
  required int workers,
  void Function(Map<String, Object?> event)? emit,
}) async {
  final queue = [...names], results = <Map<String, Object?>>[];
  await Future.wait([
    for (var worker = 0; worker < (workers < queue.length ? workers : queue.length); worker++)
      () async {
        while (queue.isNotEmpty) {
          final name = queue.removeAt(0);
          final entry = {...await checkExploration(call, name, explorationOf(moments[name])!), 'worker': worker};
          results.add(entry);
          emit?.call({'phase': 'moment', ...entry});
        }
      }(),
  ]);
  return results..sort((a, b) => names.indexOf(a['name']! as String).compareTo(names.indexOf(b['name']! as String)));
}

/// `moments/explorations.md`: every exploration Moment of the manifest in the
/// map format, so the text alone says what broke and how to get there.
/// `moments sync` writes it; it is derived, like the manifest.
void writeExplorationMap(String project) {
  final manifestFile = p.join(project, 'moments/manifest.json');
  final file = File(p.join(project, 'moments/explorations.md'));
  // Whatever the export wrote: a manifest the runner refuses has no
  // exploration to map, and the refusal is the next command's to report.
  final exported = File(manifestFile).existsSync() ? jsonDecode(File(manifestFile).readAsStringSync()) : null;
  final moments = exported is Map && exported['moments'] is Map
      ? (exported['moments'] as Map).cast<String, Object?>()
      : const <String, Object?>{};
  final names = [
    for (final MapEntry(:key, :value) in moments.entries)
      if (explorationOf(value) != null) key,
  ]..sort();
  if (names.isEmpty) {
    if (file.existsSync()) file.deleteSync();
    return;
  }
  final text = StringBuffer(
    '# Saved explorations\nmoments: 0.1\nlayers: db=postgres\nx-generated: moments sync, from the Ash declaration\n',
  );
  for (final name in names) {
    final exploration = explorationOf(moments[name])!;
    final trace = (exploration['trace']! as Map).cast<String, Object?>();
    final moves = ((trace['moves'] as List?) ?? const []).cast<Map>().map((m) => m.cast<String, Object?>());
    final subject = [trace['resource'], trace['verb']].whereType<String>().join(' ');
    text.write(
      stateSection(
        name: name,
        run: (
          executor: 'mana-explore',
          ref: p.relative(p.join(p.dirname(manifestFile), exploration['file']! as String), from: project),
        ),
        checks: ['${trace['property']} holds${subject.isEmpty ? '' : ' for $subject'} (Mana.Explore found it broken)'],
        describe: [
          if (trace['detail'] case final String detail) detail,
          'To get here: from an empty database with the exploration\'s people, '
              '${moves.isEmpty ? 'nothing else happens' : moves.map(describeMove).join(', then ')}.',
        ].join('\n'),
      ),
    );
  }
  file.writeAsStringSync('$text');
}

/// Where `save` writes [trace] so that the Ash declaration lists it: the
/// `explorations` directory of the section whose domain has the trace's
/// resource, or the only one declared. It must lie inside the app or a root
/// of `moments/sources.json`.
String explorationDirectory(String project, String manifestFile, Map<String, Object?> trace) {
  final declared = ((readManifest(manifestFile)['explorations'] as List?) ?? const []).cast<Map>();
  if (declared.isEmpty) {
    throw MomentsError(
      'No moments section declares explorations: add explorations "priv/moments/explorations" to the section of the domain with ${trace['resource']}, then moments sync',
    );
  }
  final owning = declared.where((d) => ((d['resources'] as List?) ?? const []).contains(trace['resource'])).toList();
  final chosen = owning.length == 1
      ? owning.single
      : declared.length == 1
      ? declared.single
      : throw MomentsError(
          'Several sections declare explorations (${declared.map((d) => d['domain']).join(', ')}) and not exactly one has ${trace['resource']}',
        );
  final directory = p.normalize(p.join(p.dirname(manifestFile), chosen['directory']! as String));
  final real = _real(directory);
  if (!declarationRoots(project).roots.any((root) => p.equals(root.path, real) || p.isWithin(root.path, real))) {
    throw MomentsError('$directory is outside the app and the roots of moments/sources.json');
  }
  return directory;
}

// The directory may not exist yet: resolve the part that does.
String _real(String path) {
  var existing = path;
  while (!Directory(existing).existsSync() && p.dirname(existing) != existing) {
    existing = p.dirname(existing);
  }
  return p.normalize(p.join(Directory(existing).resolveSymbolicLinksSync(), p.relative(path, from: existing)));
}

/// [trace] written as [name] where the declaration lists explorations; the
/// path written.
String writeExploration(String directory, String name, Map<String, Object?> trace) {
  final target = p.join(directory, '$name.json');
  if (File(target).existsSync()) throw MomentsError('$target is saved already; choose another name');
  Directory(directory).createSync(recursive: true);
  File(target).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(trace)}\n');
  return target;
}

/// A suite's summary when it ran exploration Moments only.
Map<String, Object?> explorationSummary(
  List<Map<String, Object?>> results, {
  required int workers,
  required num wallMs,
  Object? selection,
}) => {
  'version': 1,
  'status': results.every((r) => r['status'] == 'passed')
      ? 'passed'
      : results.any((r) => r['status'] == 'failed')
      ? 'failed'
      : 'unavailable',
  'runtime': 'backend',
  'workers': workers,
  'moments': results.length,
  'wallMs': wallMs,
  'serialMs': results.fold<num>(0, (sum, r) => sum + ((r['durationMs'] as num?) ?? 0)),
  'skipped': 0,
  'peakMemory': <String, Object?>{},
  'results': results,
  'scope':
      'Exploration Moments only: each saved Mana.Explore trace replayed in a database of its own, checking the property it broke; no app built or opened.',
  'selection': ?selection,
};
