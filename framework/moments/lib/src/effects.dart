import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'action_evidence.dart' show actionReceipt;

final _action = RegExp(r'^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\.[a-z_][a-zA-Z0-9_?!]{0,127}$');
final _resource = RegExp(r'^[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*$');

/// `backendGraph.actions` from `mix moments.export` (`Moments.ActionGraph`):
/// the files only create/update/destroy actions reach, keyed by Git path,
/// the action each step verb runs and the resources each recipe reaches.
typedef ActionMap = ({Map<String, List<String>> effects, Map<String, String> verbs, Map<String, Set<String>> recipes});

/// Why a Moment is selected by effect, or why it stays selected without one.
typedef Evidence = ({Set<String> hits, String? missing});

Never _invalid() => throw const FormatException('Invalid backend action map');

List<String> _strings(Object? value, RegExp shape) {
  if (value is! List || value.length > 20000 || value.any((v) => v is! String || !shape.hasMatch(v))) _invalid();
  return value.cast<String>();
}

/// Null when the export has no available action map; a malformed one throws.
/// [gitPath] maps a graph file (relative to the manifest) to its Git path;
/// [files] are the graph's files, which the action map may only name.
ActionMap? actionMap(Object? graph, Set<String> files, String Function(String file) gitPath) {
  final map = graph is Map ? graph['actions'] : null;
  if (map is! Map || map['version'] != 1 || map['status'] != 'available') return null;
  final effects = map['effects'], verbs = map['verbs'], recipes = map['recipes'];
  if (map['engine'] != 'ash-resource-info+mix-xref' || effects is! Map || verbs is! Map || recipes is! Map) _invalid();
  if (effects.length > 20000 || verbs.length > 20000 || recipes.length > 20000) _invalid();
  final result = (effects: <String, List<String>>{}, verbs: <String, String>{}, recipes: <String, Set<String>>{});
  for (final MapEntry(:key, :value) in effects.entries) {
    if (key is! String || !files.contains(key)) _invalid();
    result.effects[gitPath(key)] = _strings(value, _action);
  }
  for (final MapEntry(:key, :value) in verbs.entries) {
    if (key is! String || value is! String || !_action.hasMatch(value)) _invalid();
    result.verbs[key] = value;
  }
  for (final MapEntry(:key, :value) in recipes.entries) {
    if (key is! String) _invalid();
    result.recipes[key] = _strings(value, _resource).toSet();
  }
  return result;
}

String _resourceOf(String action) => action.substring(0, action.lastIndexOf('.'));

/// The actions each Moment's latest passed journey called, from the reports
/// `moments run` keeps in `moments/.proofs`: every receipt's actions and the
/// changes it reports, and whether they kept every write they saw. Unreadable or
/// foreign reports are skipped; a Moment without one has no receipt.
Map<String, ({List<String> steps, Set<String> actions, bool writesComplete})> latestReceipts(String project) {
  final directory = Directory(p.join(project, 'moments/.proofs'));
  final latest = <String, ({List<String> steps, Set<String> actions, bool writesComplete})>{};
  if (!directory.existsSync()) return latest;
  final files = [
    for (final entry in directory.listSync(followLinks: false).whereType<File>())
      if (entry.path.endsWith('.json')) entry.path,
  ]..sort();
  // Report names start with their UTC start time, so the newest come last.
  for (final file in files.skip(files.length > 2000 ? files.length - 2000 : 0)) {
    try {
      if (File(file).lengthSync() > 4 * 1024 * 1024) continue;
      final report = jsonDecode(File(file).readAsStringSync()) as Map;
      final actions = report['actions'] as Map?;
      if (report['name'] is! String ||
          report['operation'] != 'journey' ||
          report['status'] != 'passed' ||
          actions?['status'] != 'observed') {
        continue;
      }
      // A report adds the step each receipt came from to what the bridge received.
      final receipts = [
        for (final raw in actions!['receipts']! as List) actionReceipt({...raw as Map}..remove('step')),
      ];
      latest[report['name']! as String] = (
        steps: [for (final step in (report['steps']! as List).cast<Map>()) step['name']! as String],
        actions: {
          for (final receipt in receipts) ...[
            for (final a in (receipt['actions']! as List).cast<Map>()) '${a['resource']}.${a['action']}',
            for (final c in ((receipt['changes'] as List?) ?? const []).cast<Map>()) '${c['resource']}.${c['action']}',
          ],
        },
        // Effects are only ever writes: a receipt that dropped reads alone is complete for them.
        writesComplete:
            actions['overflow'] != true &&
            receipts.every((receipt) => receipt['truncated'] != true || receipt['writesComplete'] == true),
      );
    } on Object {
      // A partial, foreign or older report is no evidence.
    }
  }
  return latest;
}

/// Keeps what `Moments.Recipes` answered in `x-mana-preparation` for
/// [recipe]'s last preparation, as `<recipe>.json` in [directory]. A missing
/// or invalid answer keeps nothing: preparation evidence never fails a run.
void recordPreparation(String directory, String recipe, String? header) {
  if (header == null || header.length > 7000 || !RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(recipe)) return;
  try {
    final value = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(header))));
    if (value is! Map ||
        value.keys.any((key) => !const ['version', 'truncated', 'writesComplete', 'actions'].contains(key)) ||
        value['version'] != 1 ||
        value['truncated'] is! bool ||
        (value['writesComplete'] != null && value['writesComplete'] is! bool) ||
        value['actions'] is! List ||
        (value['actions'] as List).length > 1024 ||
        (value['actions'] as List).any((a) => a is! String || !_action.hasMatch(a))) {
      return;
    }
    // Like the reports beside it, the directory is the owner's only.
    for (final dir in [p.dirname(directory), directory]) {
      if (!Directory(dir).existsSync()) {
        Directory(dir).createSync(recursive: true);
        Process.runSync('chmod', ['700', dir]);
      }
    }
    final file = p.join(directory, '$recipe.json'), temp = '$file.$pid.tmp';
    File(temp).writeAsStringSync(
      '${jsonEncode({'version': 1, 'recipe': recipe, 'complete': value['truncated'] == false || value['writesComplete'] == true, 'actions': value['actions']})}\n',
    );
    File(temp).renameSync(file);
  } on Object {
    // A preparation that ran is not undone by its evidence going missing.
  }
}

/// The writes each recipe's last complete preparation ran (reads may have
/// given way to them past the capture's limit), as
/// [recordPreparation] kept them in `moments/.proofs/preparations`.
Map<String, Set<String>> latestPreparations(String project) {
  final directory = Directory(p.join(project, 'moments/.proofs/preparations'));
  final observed = <String, Set<String>>{};
  if (!directory.existsSync()) return observed;
  for (final entry in directory.listSync(followLinks: false).whereType<File>().take(5000)) {
    try {
      if (!entry.path.endsWith('.json') || entry.lengthSync() > 256 * 1024) continue;
      final value = jsonDecode(entry.readAsStringSync()) as Map;
      final recipe = value['recipe'];
      if (value['version'] != 1 || value['complete'] != true || recipe is! String) continue;
      if (p.basenameWithoutExtension(entry.path) != recipe) continue;
      observed[recipe] = _strings(value['actions'], _action).toSet();
    } on Object {
      // A partial or foreign file is no evidence.
    }
  }
  return observed;
}

/// The resources a saved exploration's trace touches.
Set<String> _explorationResources(Map trace) => {
  ...((trace['resources'] as List?) ?? const []).whereType<String>(),
  ?(trace['resource'] is String ? trace['resource'] as String : null),
  for (final move in ((trace['moves'] as List?) ?? const []).whereType<Map>()) ...[
    ?(move['resource'] is String ? move['resource'] as String : null),
    if (move['ref'] case [final String resource, _]) resource,
  ],
};

/// Which of [reached] each Moment's evidence names, over the Moment and its
/// ancestors: its steps' verbs, its recipes (the actions their last complete
/// preparation ran, from [preparations], else the resources their module
/// reaches), the resources of an exploration's trace and its latest
/// receipts. A Moment whose evidence is incomplete (a step without a
/// receipt, a truncated receipt, a recipe or verb the export does not map, a
/// trace naming no resource) reports what is missing instead, so it stays
/// selected.
Map<String, Evidence> effectEvidence(
  Map<String, Object?> manifest,
  ActionMap map,
  Map<String, ({List<String> steps, Set<String> actions, bool writesComplete})> receipts,
  Set<String> reached, {
  Map<String, Set<String>> preparations = const {},
}) {
  final moments = (manifest['moments']! as Map).cast<String, Object?>();
  return {
    for (final name in moments.keys)
      name: () {
        final hits = <String>{};
        String? missing;
        final seen = <String>{};
        for (String? current = name; current != null && seen.add(current);) {
          final scene = (moments[current] as Map?)?.cast<String, Object?>() ?? const {};
          final steps = ((scene['steps'] as List?) ?? const []).cast<Map>();
          final backend = scene['backend'] as Map?;
          for (final recipe in [backend?['base'], backend?['recipe']].whereType<String>()) {
            final resources = map.recipes[recipe], ran = preparations[recipe];
            if (ran != null) {
              hits.addAll(reached.where(ran.contains));
            } else if (resources == null) {
              missing ??= 'recipe not exported: $recipe';
            } else {
              hits.addAll(reached.where((action) => resources.contains(_resourceOf(action))));
            }
          }
          if ((scene['exploration'] as Map?)?['trace'] case final Map trace) {
            final resources = _explorationResources(trace);
            if (resources.isEmpty) missing ??= 'exploration names no resource';
            hits.addAll(reached.where((action) => resources.contains(_resourceOf(action))));
          }
          for (final verb in steps.map((step) => step['verb']).whereType<String>()) {
            final action = map.verbs[verb];
            if (action == null) {
              missing ??= 'verb not exported: $verb';
            } else if (reached.contains(action)) {
              hits.add(action);
            }
          }
          if (steps.isNotEmpty) {
            final receipt = receipts[current];
            final names = [for (final step in steps) step['name']];
            // Receipts of other steps say nothing about the current ones.
            if (receipt == null || receipt.steps.join('\x00') != names.join('\x00')) {
              missing ??= 'no receipt';
            } else {
              hits.addAll(reached.where(receipt.actions.contains));
              if (!receipt.writesComplete) missing ??= 'receipt truncated';
            }
          }
          current = scene['from'] as String?;
        }
        return (hits: hits, missing: missing);
      }(),
  };
}
