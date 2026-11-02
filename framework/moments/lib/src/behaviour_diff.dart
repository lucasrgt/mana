import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'affected.dart';
import 'canonical.dart';
import 'down.dart';
import 'errors.dart';
import 'manifest.dart';
import 'platform.dart' show sameProcess;
import 'reset.dart';
import 'situations.dart';
import 'suite.dart' show TemporaryBackend, runSuite;

/// The projections a behaviour diff compares, in report order.
const behaviourLayers = ['rows', 'history', 'observed', 'screen', 'offered'];
const _dataLayers = ['rows', 'history', 'observed'], _screenLayers = ['screen', 'offered'];

/// What one version answered for a Moment, each half evaluated twice (so a
/// field that differs between the two is known to be unreproducible rather
/// than changed) or with the reason it could not be: its data situation
/// ([data], the recipes' `/project` and `observe/2`) and its journey's last
/// screen report ([screens]: `screen` and `offered`).
final class Evaluation {
  const Evaluation({this.recipe, this.data = const [], this.dataReason, this.screens = const [], this.screenReason});

  final String? recipe;
  final List<Map<String, Object?>> data;
  final String? dataReason;
  final List<Map<String, Object?>> screens;
  final String? screenReason;

  Evaluation withScreens(List<Map<String, Object?>> screens, String? reason) =>
      Evaluation(recipe: recipe, data: data, dataReason: dataReason, screens: screens, screenReason: reason);
}

/// Brings up the backend of [project] at its version, evaluates [names]
/// there and takes it down again; [discard] also removes its database.
typedef EvaluateVersion =
    Future<Map<String, Evaluation>> Function(
      String project,
      List<String> names, {
      required bool discard,
      required String log,
    });

String _git(String root, List<String> args) {
  final result = Process.runSync('git', ['-C', root, ...args], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (result.exitCode != 0) throw MomentsError('git ${args.first} failed: ${'${result.stderr}'.trim()}');
  return result.stdout as String;
}

Map<String, Object?> _moments(String project) {
  final file = p.join(project, 'moments/manifest.json');
  return File(file).existsSync() ? (readManifest(file)['moments']! as Map).cast() : const {};
}

/// The Moments [project] declares at its version.
List<String> declaredMoments(String project) => _moments(project).keys.toList();

/// Each of [names] evaluated twice through [situations]. Moments whose
/// recipes from the root are the same share one evaluation: those recipes
/// alone make their data situation (journey steps are UI, outside it).
Future<Map<String, Evaluation>> evaluateMoments(
  Situations situations,
  List<String> names, {
  void Function(String name)? onMoment,
}) async {
  final manifest = _moments(situations.project);
  String? recipeOf(String name) => ((manifest[name] as Map?)?['backend'] as Map?)?['recipe'] as String?;
  final byRecipe = <String, Evaluation>{};
  final result = <String, Evaluation>{};
  for (final name in names) {
    if (!manifest.containsKey(name)) continue;
    final recipe = recipeOf(name);
    final String key;
    try {
      key = recipe != null ? 'recipes:${situations.path(name).map(recipeOf).join('>')}' : 'moment:$name';
    } on MomentsError catch (error) {
      result[name] = Evaluation(recipe: recipe, dataReason: error.message);
      continue;
    }
    onMoment?.call(name);
    result[name] = byRecipe[key] ??= await () async {
      try {
        final first = await situations.prepare(name), second = await situations.prepare(name);
        return Evaluation(
          recipe: recipe ?? (first['recipe'] as String?),
          data: [
            (first['projection']! as Map).cast<String, Object?>(),
            (second['projection']! as Map).cast<String, Object?>(),
          ],
        );
      } on MomentsError catch (error) {
        // Shared by every Moment of the recipe, so it must not name this one.
        final message = error.message;
        return Evaluation(
          recipe: recipe,
          dataReason: message.startsWith('$name ') ? message.substring(name.length + 1) : message,
        );
      }
    }();
  }
  return result;
}

/// A suite result's last screen report, normalized: the declared projection
/// with the journey's outcome (`screen`) and the verbs it offered (`offered`).
Map<String, Object?>? screenOf(Map<String, Object?> result) {
  final observation = result['observation'] as Map?;
  if (observation == null) return null;
  final ids = <String, String>{};
  final screen = normalize({'journey': result['status'], ...?(observation['projection'] as Map?)?.cast()}, ids);
  final offered = normalize((observation['offered'] as List?) ?? const [], ids)! as List;
  return {
    'screen': screen,
    'offered': {for (final verb in offered) '$verb': true},
  };
}

/// Each of [names] run twice as `suite --headless` does (flutter_tester and
/// the runner's look), keeping each journey's last screen report, merged into
/// [evaluations]. [suite] stands for that run (`runSuite` with `observe`).
Future<Map<String, Evaluation>> observeScreens(
  String project,
  List<String> names,
  Map<String, Evaluation> evaluations, {
  int workers = 2,
  void Function(String line)? progress,
  Future<Map<String, Object?>> Function(List<String> names)? suite,
}) async {
  final run =
      suite ??
      (names) => runSuite(
        project: project,
        names: names,
        workers: workers,
        runtime: 'headless',
        observe: true,
        onEvent: (event) {
          if (event['phase'] == 'moment') progress?.call('    ${event['status']} · ${event['name']}');
        },
      );
  final declared = _moments(project);
  final known = [
    for (final name in names)
      if (declared.containsKey(name)) name,
  ];
  final runs = <Map<String, Map<String, Object?>>>[];
  String? failure;
  for (var round = 1; round <= 2 && known.isNotEmpty && failure == null; round++) {
    progress?.call('  journeys, run $round of 2…');
    try {
      final results = (await run(known))['results']! as List;
      runs.add({for (final result in results.cast<Map>()) result['name']! as String: result.cast()});
    } on MomentsError catch (error) {
      failure = error.message;
    }
  }
  return {
    for (final name in known)
      name: () {
        final evaluation = evaluations[name] ?? const Evaluation();
        if (failure != null) return evaluation.withScreens(const [], failure);
        final results = [for (final run in runs) run[name]];
        final screens = [for (final result in results) result == null ? null : screenOf(result)];
        if (screens.any((screen) => screen == null)) {
          final result = results.firstWhere((r) => r != null && screenOf(r) == null, orElse: () => null);
          return evaluation.withScreens(const [], '${result?['reason'] ?? 'the journey left no screen report'}');
        }
        return evaluation.withScreens(screens.cast(), null);
      }(),
  };
}

String _entryKey(Map entry) =>
    '${entry['subject']} ${entry['action']}${entry['verb'] != null ? ' (${entry['verb']})' : ''}';

Map<String, Object?> _entryFields(Map entry) => {
  'outcome': entry['outcome'],
  'actor': entry['actorKind'],
  'before': entry['before'],
  'after': entry['after'],
};

/// Field by field, through the observed layer's comparison.
Map<String, Object?> _fieldDiff(Map<String, Object?> a, Map<String, Object?> b) =>
    (diffProjections({'observe': a}, {'observe': b})['observe']! as Map).cast();

/// History entries one side recorded and the other not, paired by subject,
/// action and verb in the order they happened: a pair is the same step with
/// different values, an unpaired entry a step only one side took.
({List<(String, Map, Map)> pairs, List<(String, Map)> onlyA, List<(String, Map)> onlyB}) _pair(Map history) {
  final a = ((history['onlyA'] as List?) ?? const []).cast<Map>();
  final b = ((history['onlyB'] as List?) ?? const []).cast<Map>();
  final waiting = <String, List<Map>>{};
  for (final entry in b) {
    waiting.putIfAbsent(_entryKey(entry), () => []).add(entry);
  }
  final pairs = <(String, Map, Map)>[], onlyA = <(String, Map)>[];
  for (final entry in a) {
    final key = _entryKey(entry), match = waiting[key];
    if (match != null && match.isNotEmpty) {
      pairs.add((key, entry, match.removeAt(0)));
    } else {
      onlyA.add((key, entry));
    }
  }
  return (
    pairs: pairs,
    onlyA: onlyA,
    onlyB: [
      for (final entry in b)
        if (waiting[_entryKey(entry)]!.contains(entry)) (_entryKey(entry), entry),
    ],
  );
}

/// What differs between two evaluations of one version: none of it can be
/// read as a change between versions.
final class _Unstable {
  final rows = <String>{}, observed = <String>{}, entries = <String>{}, fields = <String>{};

  void add(List<Map<String, Object?>> evaluations) {
    for (final other in evaluations.skip(1)) {
      final noise = diffProjections(evaluations.first, other);
      final data = noise['data']! as Map;
      rows.addAll((data['tables']! as Map).keys.cast());
      observed.addAll((noise['observe']! as Map).keys.cast());
      final paired = _pair(data['history']! as Map);
      for (final (key, a, b) in paired.pairs) {
        fields.addAll([for (final field in _fieldDiff(_entryFields(a), _entryFields(b)).keys) '$key\u0000$field']);
      }
      entries.addAll([
        for (final (key, _) in [...paired.onlyA, ...paired.onlyB]) key,
      ]);
    }
  }

  List<String> describe() => [
    for (final table in rows) 'rows $table',
    for (final path in observed) 'observed $path',
    for (final key in entries) 'history $key',
    for (final field in fields) 'history ${field.replaceFirst('\u0000', ' · ')}',
  ]..sort();
}

/// One screen layer's differences between versions, without the fields that
/// differ between two runs of one version.
({List<Map<String, Object?>> changes, Set<String> unstable}) _compareLayer(
  String layer,
  List<Map<String, Object?>> base,
  List<Map<String, Object?>> head,
) {
  Map<String, Object?> of(Map<String, Object?> screen) => ((screen[layer] as Map?) ?? const {}).cast();
  final unstable = <String>{
    for (final runs in [base, head])
      for (final other in runs.skip(1)) ..._fieldDiff(of(runs.first), of(other)).keys,
  };
  return (
    changes: [
      for (final MapEntry(key: field, value: pair as List) in _fieldDiff(of(base.first), of(head.first)).entries)
        if (!unstable.contains(field)) {'field': field, 'base': pair.first, 'head': pair.last},
    ],
    unstable: unstable,
  );
}

/// The behaviour differences of one Moment: per projection, the field and
/// its value at the base and at the head, without what is unreproducible at
/// either version. Either half is compared only when both versions have it.
({Map<String, List<Map<String, Object?>>> changes, List<String> unreproducible}) compareMoment(
  Evaluation before,
  Evaluation after,
) {
  final screens = <String, List<Map<String, Object?>>>{};
  final unreproducible = <String>[];
  if (before.screens.isNotEmpty && after.screens.isNotEmpty) {
    for (final layer in _screenLayers) {
      final result = _compareLayer(layer, before.screens, after.screens);
      if (result.changes.isNotEmpty) screens[layer] = result.changes;
      unreproducible.addAll([for (final field in result.unstable) '$layer $field']);
    }
  }
  if (before.data.isEmpty || after.data.isEmpty) {
    return (changes: screens, unreproducible: unreproducible..sort());
  }
  final data = _compareData(before.data, after.data);
  return (changes: {...data.changes, ...screens}, unreproducible: [...data.unreproducible, ...unreproducible]..sort());
}

({Map<String, List<Map<String, Object?>>> changes, List<String> unreproducible}) _compareData(
  List<Map<String, Object?>> base,
  List<Map<String, Object?>> head,
) {
  final noise = _Unstable()
    ..add(base)
    ..add(head);
  final main = diffProjections(base.first, head.first);
  final data = main['data']! as Map;
  final rows = [
    for (final MapEntry(key: table as String, value: counts as List) in (data['tables']! as Map).entries)
      if (!noise.rows.contains(table)) {'field': table, 'base': counts.first, 'head': counts.last},
  ];
  final observed = [
    for (final MapEntry(key: path as String, value: pair as List) in (main['observe']! as Map).entries)
      if (!noise.observed.contains(path)) {'field': path, 'base': pair.first, 'head': pair.last},
  ];
  final paired = _pair(data['history']! as Map);
  final history = <Map<String, Object?>>[
    for (final (key, a, b) in paired.pairs)
      if (!noise.entries.contains(key))
        for (final MapEntry(key: field, value: pair as List) in _fieldDiff(_entryFields(a), _entryFields(b)).entries)
          if (!noise.fields.contains('$key\u0000$field'))
            {'entry': key, 'field': field, 'base': pair.first, 'head': pair.last},
    for (final (key, entry) in paired.onlyA)
      if (!noise.entries.contains(key)) {'entry': key, 'field': null, 'base': entry, 'head': null},
    for (final (key, entry) in paired.onlyB)
      if (!noise.entries.contains(key)) {'entry': key, 'field': null, 'base': null, 'head': entry},
  ];
  return (
    changes: {
      if (rows.isNotEmpty) 'rows': rows,
      if (history.isNotEmpty) 'history': history,
      if (observed.isNotEmpty) 'observed': observed,
    },
    unreproducible: noise.describe(),
  );
}

/// The report of [names] evaluated at the base and at the head: only the
/// Moments whose behaviour or recipe differs have an entry.
Map<String, Object?> compareVersions(List<String> names, Map<String, Evaluation> base, Map<String, Evaluation> head) {
  final moments = <String, Object?>{}, unreproducible = <String, Object?>{};
  final added = <String>[], removed = <String>[];
  final notCompared = <Map<String, Object?>>[], partly = <Map<String, Object?>>[];
  var compared = 0;
  for (final name in names) {
    final before = base[name], after = head[name];
    if (before == null && after == null) continue;
    if (before == null) {
      added.add(name);
      continue;
    }
    if (after == null) {
      removed.add(name);
      continue;
    }
    final data = before.data.isNotEmpty && after.data.isNotEmpty;
    final screens = before.screens.isNotEmpty && after.screens.isNotEmpty;
    if (!data && !screens) {
      notCompared.add({
        'name': name,
        'reason': [?(after.dataReason ?? before.dataReason), ?(after.screenReason ?? before.screenReason)].join('; '),
      });
      continue;
    }
    if (!data) {
      partly.add({'name': name, 'layers': _dataLayers, 'reason': after.dataReason ?? before.dataReason});
    }
    if (!screens) {
      partly.add({'name': name, 'layers': _screenLayers, 'reason': after.screenReason ?? before.screenReason});
    }
    compared++;
    final result = compareMoment(before, after);
    final redefined =
        before.recipe != after.recipe || (data && before.data.first['recipe'] != after.data.first['recipe']);
    if (result.unreproducible.isNotEmpty) unreproducible[name] = result.unreproducible;
    if (result.changes.isEmpty && !redefined) continue;
    moments[name] = {'recipe': after.recipe, 'redefined': redefined, 'projections': result.changes};
  }
  return {
    'compared': compared,
    'changed': moments.length,
    'moments': moments,
    'added': added,
    'removed': removed,
    'notCompared': notCompared,
    'layersNotCompared': partly,
    'unreproducible': unreproducible,
    'layers': behaviourLayers,
    'normalization': {
      ...normalization,
      'reproducibility':
          'each Moment is evaluated twice at each version; a field that differs between the two is unreproducible and not compared',
    },
    'scope':
        "Each Moment at both versions: its data situation (its recipes prepared in a database of its own, data_scope: true: "
        "rows per table, Mana.History entries, the recipe's observe/2) and its journey run headless as suite --headless runs it "
        '(the last screen report: the declared projection with the journey\'s outcome, and the offered verbs).',
  };
}

String _value(Object? value) {
  final text = jsonEncode(canonical(value));
  return '`${text.length > 120 ? '${text.substring(0, 117)}...' : text}`';
}

String _change(String layer, Map change) {
  final field = change['field'], before = change['base'], after = change['head'];
  return switch (layer) {
    'rows' => '- `${change['field']}`: ${before ?? 0} → ${after ?? 0} rows',
    'history' when field == null =>
      before == null
          ? '- now records `${change['entry']}`: ${_value((after! as Map)['after'])}'
          : '- no longer records `${change['entry']}` (was ${_value((before as Map)['after'])})',
    'history' => '- `${change['entry']}`: `$field` went from ${_value(before)} to ${_value(after)}',
    'offered' => before == null ? '- `$field` is offered now' : '- `$field` is no longer offered',
    _ =>
      before == null
          ? '- `$field` appeared: ${_value(after)}'
          : after == null
          ? '- `$field` disappeared (was ${_value(before)})'
          : '- `$field` went from ${_value(before)} to ${_value(after)}',
  };
}

String _count(int n) => n == 1 ? '1 Moment' : '$n Moments';

const _layerTitles = {
  'rows': 'Rows',
  'history': 'History',
  'observed': 'Observed',
  'screen': 'Screen',
  'offered': 'Offered verbs',
};

/// `- `a`, `b`: reason`, one line per reason.
List<String> _byReason(List<Map> items, String Function(Map item) reason) {
  final reasons = <String, List<String>>{};
  for (final item in items) {
    reasons.putIfAbsent(reason(item), () => []).add('${item['name']}');
  }
  return [for (final MapEntry(:key, :value) in reasons.entries) '- ${value.map((n) => '`$n`').join(', ')}: $key'];
}

/// [report] for a reviewer: what the system does differently, one section
/// per group of Moments that changed the same way.
String behaviourMarkdown(Map<String, Object?> report) {
  final base = (report['base'] as Map?) ?? const {}, head = (report['head'] as Map?) ?? const {};
  final moments = ((report['moments'] as Map?) ?? const {}).cast<String, Object?>();
  final groups = <String, List<String>>{};
  for (final MapEntry(:key, :value) in moments.entries) {
    groups.putIfAbsent(jsonEncode(canonical(value)), () => []).add(key);
  }
  final lines = <String>[
    '## Behaviour diff',
    '',
    '${_count(report['compared']! as int)} compared between `${base['ref']}` (${'${base['commit']}'.substring(0, 7)}) '
        'and ${head['label'] ?? 'the working tree'}: '
        '${switch (moments.length) {
          0 => 'none behaves differently.',
          1 => '1 behaves differently.',
          final n => '$n behave differently.',
        }}',
  ];
  for (final MapEntry(key: digest, value: names) in groups.entries) {
    final entry = jsonDecode(digest) as Map;
    lines
      ..add('')
      ..add('### ${names.map((n) => '`$n`').join(', ')}')
      ..add('');
    if (entry['recipe'] != null) lines.add('Recipe `${entry['recipe']}`.');
    if (entry['redefined'] == true) {
      lines.add(
        '> **Redefined:** the recipe changed between the two versions, so these differences may come from the new recipe rather than from changed behaviour.',
      );
    }
    final projections = (entry['projections']! as Map).cast<String, Object?>();
    if (projections.isEmpty) lines.add('Same projections; only the recipe changed.');
    for (final layer in behaviourLayers) {
      final changes = projections[layer] as List?;
      if (changes == null) continue;
      lines
        ..add('')
        ..add('**${_layerTitles[layer]}**')
        ..addAll([for (final change in changes.cast<Map>()) _change(layer, change)]);
    }
  }
  final added = (report['added'] as List?) ?? const [], removed = (report['removed'] as List?) ?? const [];
  final notCompared = ((report['notCompared'] as List?) ?? const []).cast<Map>();
  final partly = ((report['layersNotCompared'] as List?) ?? const []).cast<Map>();
  final unreproducible = (report['unreproducible'] as Map?) ?? const {};
  if (added.isNotEmpty || removed.isNotEmpty) lines.add('');
  if (added.isNotEmpty) lines.add('New Moments: ${added.map((n) => '`$n`').join(', ')}.');
  if (removed.isNotEmpty) lines.add('Removed Moments: ${removed.map((n) => '`$n`').join(', ')}.');
  if (notCompared.isNotEmpty) {
    lines
      ..add('')
      ..add('<details><summary>${_count(notCompared.length)} not compared</summary>')
      ..add('')
      ..addAll(_byReason(notCompared, (item) => '${item['reason']}'))
      ..add('')
      ..add('</details>');
  }
  if (partly.isNotEmpty) {
    lines
      ..add('')
      ..add('<details><summary>Layers not compared</summary>')
      ..add('')
      ..addAll(_byReason(partly, (item) => '${(item['layers']! as List).join(', ')}: ${item['reason']}'))
      ..add('')
      ..add('</details>');
  }
  lines
    ..add('')
    ..add(
      '<sub>${report['scope']} Ids, times and secrets are normalized'
      '${unreproducible.isEmpty ? '' : '; fields that differ between two evaluations at the same version are left out (${_count(unreproducible.length)}, JSON `unreproducible`)'}.</sub>',
    );
  return '${lines.join('\n')}\n';
}

/// A detached checkout of a commit next to the repository, with its
/// submodules at the commits it records.
final class BaseCheckout {
  BaseCheckout._(this.root, this.directory, this._nested);

  final String root, directory;
  final List<(String, String)> _nested;

  static BaseCheckout open(String root, String commit) {
    _git(root, ['worktree', 'prune']);
    final parent = Directory.systemTemp.createTempSync('moments-diff-');
    final directory = p.join(parent.path, 'base');
    _git(root, ['worktree', 'add', '--detach', '--quiet', directory, commit]);
    final nested = <(String, String)>[];
    final checkout = BaseCheckout._(root, directory, nested);
    try {
      for (final line in const LineSplitter().convert(_git(directory, ['submodule', 'status']))) {
        final match = RegExp(r'^-([0-9a-f]+) (\S+)').firstMatch(line);
        if (match == null) continue;
        final sha = match[1]!, path = match[2]!, own = p.join(root, path);
        // The head's own clone of the submodule usually has the base's commit:
        // a worktree of it needs no network and no second clone.
        final local = Process.runSync('git', ['-C', own, 'cat-file', '-e', '$sha^{commit}']).exitCode == 0;
        if (local) {
          _git(own, ['worktree', 'add', '--detach', '--quiet', p.join(directory, path), sha]);
          nested.add((own, p.join(directory, path)));
        } else {
          _git(directory, ['submodule', 'update', '--init', '--', path]);
        }
      }
    } on Object {
      checkout.close();
      rethrow;
    }
    return checkout;
  }

  void close() {
    for (final (repository, path) in _nested.reversed) {
      Process.runSync('git', ['-C', repository, 'worktree', 'remove', '--force', path]);
    }
    Process.runSync('git', ['-C', root, 'worktree', 'remove', '--force', directory]);
    final parent = Directory(p.dirname(directory));
    if (parent.existsSync()) parent.deleteSync(recursive: true);
    Process.runSync('git', ['-C', root, 'worktree', 'prune']);
    for (final (repository, _) in _nested) {
      Process.runSync('git', ['-C', repository, 'worktree', 'prune']);
    }
  }
}

/// A checkout has none of the ignored files a project installs (packages,
/// Hex deps): `mana setup --runtime-only` runs the project's setup tasks,
/// with its own vendored CLI when it has one.
Future<void> setUpCheckout(String directory, String log) async {
  if (!File(p.join(directory, 'mana.toml')).existsSync()) return;
  final vendored = p.join(directory, 'mana/framework/cli/mana');
  final command = File(vendored).existsSync() ? vendored : 'mana';
  final sink = File(log).openWrite(mode: FileMode.append);
  try {
    final child = await Process.start(command, ['setup', '--runtime-only'], workingDirectory: directory);
    await Future.wait([child.stdout.forEach(sink.add), child.stderr.forEach(sink.add)]);
    final code = await child.exitCode;
    if (code != 0) throw MomentsError('The base checkout did not set up (mana setup exited $code; log: $log)');
  } on ProcessException {
    throw MomentsError('The base checkout needs mana setup and no mana CLI was found (log: $log)');
  } finally {
    await sink.close();
  }
}

/// One version's evaluation through its own temporary backend: the data
/// situations first, then the journeys on the same backend.
EvaluateVersion liveEvaluation(
  Situations Function(String project) situationsFor, {
  int workers = 2,
  void Function(String)? progress,
}) => (project, names, {required discard, required log}) async {
  final backend = File(p.join(project, 'moments/backend.json'));
  if (!backend.existsSync()) throw MomentsError('${p.basename(project)} has no moments/backend.json');
  final initial = () {
    final json = jsonDecode(backend.readAsStringSync()) as Map;
    return (json['initialMoment'] ?? json['name'])! as String;
  }();
  try {
    final backend = await TemporaryBackend.start(
      project: project,
      directory: p.join(project, 'moments/.backend'),
      name: initial,
      log: log,
    );
    try {
      progress?.call('  data situations…');
      final data = await evaluateMoments(situationsFor(project), names);
      return await observeScreens(project, names, data, workers: workers, progress: progress);
    } finally {
      await backend.stop();
    }
  } finally {
    if (discard) {
      if (File(p.join(project, 'moments/.backend/running.json')).existsSync()) await downInstance(project);
      if (File(p.join(project, 'moments/.backend/instance.json')).existsSync()) {
        await resetInstance(project, discardData: true);
      }
    }
  }
};

/// `moments diff --base <ref> [--affected]`: the Moments of [project]
/// evaluated at [base] (a checkout of it) and at the working tree, compared,
/// and written as `behaviour-diff.json` and `behaviour-diff.md` in [out].
Future<Map<String, Object?>> behaviourDiff({
  required String project,
  required String base,
  required EvaluateVersion evaluate,
  bool affected = false,
  String? out,
  void Function(String line)? progress,
}) async {
  final say = progress ?? (_) {};
  project = Directory(project).resolveSymbolicLinksSync();
  final String root, commit, headCommit;
  try {
    root = Directory(_git(project, ['rev-parse', '--show-toplevel']).trim()).resolveSymbolicLinksSync();
    commit = _git(root, ['rev-parse', '--verify', '--end-of-options', '$base^{commit}']).trim();
    headCommit = _git(root, ['rev-parse', 'HEAD']).trim();
  } on MomentsError {
    throw const MomentsError('diff --base needs a Git checkout and a commit to compare with');
  }
  final running = File(p.join(project, 'moments/.backend/running.json'));
  if (running.existsSync()) {
    final supervisor = (jsonDecode(running.readAsStringSync()) as Map)['supervisor'];
    if (supervisor is Map && sameProcess(supervisor.cast())) {
      throw const MomentsError(
        'This app has an instance running; stop it with moments down: diff starts the backend at the base and at the head on the declared ports',
      );
    }
    await downInstance(project);
  }
  final directory = out != null ? p.absolute(out) : p.join(project, 'moments/.diff');
  Directory(directory).createSync(recursive: true);
  Map<String, Object?>? selection;
  var names = declaredMoments(project);
  if (affected) {
    final plan = await affectedMoments(project, base: base);
    if (plan['status'] == 'planned') {
      names = [for (final item in (plan['selected']! as List).cast<Map>()) item['name']! as String];
      selection = {'precision': plan['precision'], 'omitted': (plan['omitted']! as List).length};
    } else {
      selection = {'precision': 'whole-catalog', 'reason': 'affected plan unavailable'};
    }
  }
  final relative = p.relative(project, from: root);
  var baseNames = <String>[];
  var baseResults = <String, Evaluation>{};
  if (names.isNotEmpty || !affected) {
    say('Diff: checking out $base (${commit.substring(0, 7)})…');
    final checkout = BaseCheckout.open(root, commit);
    try {
      final baseProject = p.join(checkout.directory, relative);
      baseNames = declaredMoments(baseProject);
      if (baseNames.isNotEmpty) {
        say('Diff: setting up the base checkout…');
        await setUpCheckout(checkout.directory, p.join(directory, 'base-setup.log'));
        say('Diff: evaluating at the base…');
        baseResults = await evaluate(
          baseProject,
          affected ? names : baseNames,
          discard: true,
          log: p.join(directory, 'base-backend.log'),
        );
      }
    } finally {
      checkout.close();
    }
  }
  say('Diff: evaluating at the head…');
  final headResults = names.isEmpty
      ? <String, Evaluation>{}
      : await evaluate(project, names, discard: false, log: p.join(directory, 'head-backend.log'));
  final all = [
    ...names,
    if (!affected)
      for (final name in baseNames)
        if (!names.contains(name)) name,
  ];
  final dirty = _git(root, ['status', '--porcelain', '--untracked-files=no']).trim().isNotEmpty;
  final report = {
    'version': 1,
    'base': {'ref': base, 'commit': commit},
    'head': {
      'commit': headCommit,
      'label': dirty ? 'the working tree (on ${headCommit.substring(0, 7)}, with changes)' : headCommit.substring(0, 7),
    },
    'project': relative,
    'selection': {'affected': affected, 'moments': all, ...?selection},
    ...compareVersions(all, baseResults, headResults),
  };
  final json = p.join(directory, 'behaviour-diff.json'), markdown = p.join(directory, 'behaviour-diff.md');
  File(json).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  File(markdown).writeAsStringSync(behaviourMarkdown(report));
  return {
    ...report,
    'files': {'json': json, 'markdown': markdown},
  };
}
