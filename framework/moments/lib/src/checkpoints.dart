import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/runtime.dart' show savePrivateState;
import 'package:path/path.dart' as p;

import 'canonical.dart';
import 'errors.dart';
import 'json.dart';

/// What composition learns of a recipe before running it (the plug's
/// `describe`): whether it prepares in a database of its own, its digest and
/// whether the snapshot asked about still exists.
typedef Description = ({bool isolated, String? digest, bool snapshot});

/// One recipe as a chain composes it.
final class Transition {
  const Transition({required this.prepare, this.describe, this.capture});

  /// Runs the recipe and answers its launch, or null when it returned none.
  /// [parent] is the launch of the checkpoint it builds on; with [snapshot]
  /// it runs in a clone of that captured snapshot instead of the base.
  final Future<Map<String, Object?>?> Function({Map<String, Object?>? parent, String? snapshot}) prepare;

  /// Null when the adapter cannot tell: the recipe counts as one on the
  /// shared database, never captured.
  final Future<Description?> Function({String? snapshot})? describe;
  final Future<void> Function(Map<String, Object?> launch, String snapshot)? capture;
}

/// A Moment of a chain, root first. [transition] is null when it declares no
/// recipe (its data is its parent's); [parent] says other Moments declare it
/// as their `from`, so its checkpoint is worth capturing.
typedef Link = ({String moment, Map<String, Object?> identity, Transition? transition, bool parent});

/// What one composed preparation did: the launch it ends with and, per
/// Moment of the chain, how its data came to be (`checkpoint`: materialized
/// from its captured snapshot; `root`, `from-snapshot` or `on-parent`: its
/// recipe ran).
typedef Composed = ({Map<String, Object?>? launch, List<Map<String, Object?>> path});

/// The checkpoints one backend keeps (`moments/.backend/checkpoints.json`):
/// per Moment, the launch its preparation answered, the digest of the recipe
/// that made it and the snapshot captured right after. Snapshots are
/// databases in the owned Postgres, so a checkpoint outlives the process
/// that made it.
final class CheckpointStore {
  CheckpointStore(this.file);
  final String file;

  Map<String, Map<String, Object?>> read() {
    if (!File(file).existsSync()) return {};
    final value = jsonDecode(File(file).readAsStringSync());
    if (value is! Map || value['version'] != 1 || value['checkpoints'] is! Map) {
      throw MomentsError('Unreadable checkpoints in $file; inspect or remove it');
    }
    return {
      for (final MapEntry(:key, :value) in (value['checkpoints'] as Map).entries)
        key as String: (value as Map).cast<String, Object?>(),
    };
  }

  Map<String, Object?>? operator [](String moment) => read()[moment];

  void put(String moment, Map<String, Object?>? checkpoint) {
    final all = read();
    if (checkpoint == null) {
      if (all.remove(moment) == null) return;
    } else {
      all[moment] = checkpoint;
    }
    Directory(p.dirname(file)).createSync(recursive: true);
    savePrivateState(file, {'version': 1, 'checkpoints': all});
  }
}

/// The snapshot a Moment's checkpoint is captured as: stable per Moment, so a
/// new capture replaces the old one, and within `Mana.Snapshot`'s name rule.
String snapshotName(String moment) => 'c-${hashText(moment).substring(0, 24)}';

/// [child]'s launch on top of [parent]'s: what the child does not answer
/// (the account, inputs) stays the parent's.
Map<String, Object?>? composeLaunch(Map<String, Object?>? parent, Map<String, Object?>? child) {
  if (parent == null || child == null) return child ?? parent;
  final inputs = {...?(parent['inputs'] as Map?)?.cast<String, Object?>(), ...?(child['inputs'] as Map?)?.cast()};
  return {...parent, ...child, if (inputs.isNotEmpty) 'inputs': inputs};
}

final _queues = <String, Future<void>>{};

/// Runs [operation] after every earlier one with the same [key]: two suite
/// workers opening children of one parent capture it once, and never clone a
/// snapshot while it is being replaced.
Future<T> _serialized<T>(String key, Future<T> Function() operation) async {
  final previous = _queues[key];
  final done = Completer<void>();
  _queues[key] = done.future;
  try {
    if (previous != null) await previous;
    return await operation();
  } finally {
    done.complete();
    if (identical(_queues[key], done.future)) _queues.remove(key);
  }
}

/// Prepares the last Moment of [chain] on its ancestors' checkpoints. The
/// deepest ancestor with a current checkpoint (same declaration, same recipe
/// digest, snapshot still there) is materialized from its snapshot and only
/// the transitions after it run; a recipe on the shared database has no
/// snapshot, so its chain runs from the root (the protocol's replay mode).
/// A data-scoped Moment that is a parent is captured after it prepares.
/// [onTransition] hears of each recipe before it runs, and whether its
/// writes stay in a database of its own.
Future<Composed> composeChain(
  List<Link> chain,
  CheckpointStore store, {
  void Function(String moment, bool isolated)? onTransition,
}) {
  final links = [
    for (final link in chain)
      if (link.transition != null) link,
  ];
  if (links.isEmpty) return Future.value((launch: null, path: <Map<String, Object?>>[]));
  if (links.length == 1 && !links.single.parent) return _compose(links, store, onTransition);
  return _serialized(store.file, () => _compose(links, store, onTransition));
}

Future<Composed> _compose(
  List<Link> links,
  CheckpointStore store,
  void Function(String moment, bool isolated)? onTransition,
) async {
  final path = <Map<String, Object?>>[];
  Map<String, Object?>? parent;
  String? snapshot;
  var start = 0;
  for (var index = links.length - 2; index >= 0; index--) {
    final link = links[index], kept = store[link.moment];
    final name = kept?['snapshot'];
    if (kept == null || name is! String || !deepEqual(kept['identity'], link.identity)) continue;
    final described = await link.transition!.describe?.call(snapshot: name);
    if (described == null || !described.snapshot || described.digest != kept['digest']) {
      store.put(link.moment, null);
      continue;
    }
    parent = (kept['launch']! as Map).cast();
    snapshot = name;
    start = index + 1;
    path.add({'moment': link.moment, 'mode': 'checkpoint', 'capturedAt': kept['capturedAt']});
    break;
  }
  for (var index = start; index < links.length; index++) {
    final link = links[index], transition = link.transition!, last = index == links.length - 1;
    final keep = !last || link.parent;
    final described = keep || parent != null || onTransition != null ? await transition.describe?.call() : null;
    final isolated = described?.isolated ?? false;
    if (parent != null && (parent['dataScope'] is String) != isolated) {
      throw MomentsError(
        '${link.moment} and its parent must both prepare in a database of their own (data_scope: true), or both on the shared database',
      );
    }
    onTransition?.call(link.moment, isolated);
    final answered = await transition.prepare(parent: parent, snapshot: snapshot);
    if (snapshot != null && (answered?['dataScope'] is! String || answered!['dataScope'] == parent!['dataScope'])) {
      throw MomentsError("${link.moment} did not prepare in a clone of its parent's snapshot");
    }
    path.add({
      'moment': link.moment,
      'mode': parent == null
          ? 'root'
          : snapshot != null
          ? 'from-snapshot'
          : 'on-parent',
    });
    final launch = composeLaunch(parent, answered);
    snapshot = null;
    if (keep && isolated) {
      final capture = transition.capture;
      if (launch?['dataScope'] is! String || capture == null) {
        throw MomentsError('${link.moment} prepared in a data scope that cannot be captured for its children');
      }
      final name = snapshotName(link.moment);
      await capture(launch!, name);
      store.put(link.moment, {
        'identity': link.identity,
        'launch': launch,
        'snapshot': name,
        'digest': described!.digest,
        'capturedAt': DateTime.now().toUtc().toIso8601String(),
      });
      if (!last) snapshot = name;
    }
    parent = launch;
  }
  return (launch: parent, path: path);
}
