import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'failure.dart';
import 'features.dart';
import 'toolchain.dart';

/// The reasoning that outlives a session: decisions and attempts, each
/// addressed by coordinate (`feature:`, `verb:`, `moment:`, `entity:`),
/// carrying the receipt that backed it (a sensors verdict) and the hash of
/// what it describes, so it reads `stale` once that code moved on. Kept in
/// `notebook/<area>.jsonl`, versioned with the code, never edited by hand.
final class Notebook {
  Notebook(this.root);

  final String root;

  Directory get _dir => Directory(p.join(root, 'notebook'));

  static final _coordinate = RegExp(
    r'^(feature|verb|moment|entity):[\w./:*-]+$',
  );

  /// Appends a note; answers it.
  Map<String, Object?> add({
    required String why,
    required List<String> about,
    String outcome = 'decided',
    String? receipt,
    List<String> paths = const [],
  }) {
    if (why.trim().isEmpty) throw const ManaFailure('A note needs its why');
    if (about.isEmpty || !about.every(_coordinate.hasMatch)) {
      throw const ManaFailure(
        'Address the note with feature:<name>, verb:<type.verb>, moment:<app:name> or entity:<type:id>',
      );
    }
    if (!const ['decided', 'tried', 'failed', 'kept'].contains(outcome)) {
      throw ManaFailure(
        'Outcome is decided, tried, failed or kept, not $outcome',
      );
    }
    final features = FeatureMap.tryLoad(root);
    final described = {
      ...paths,
      if (features != null)
        for (final c in about.where((c) => c.startsWith('feature:')))
          ...?(features.describe(features.named(c.substring(8)))['files']
                  as List?)
              ?.cast<String>(),
    }.toList()..sort();
    final note = {
      'id':
          '${DateTime.now().toUtc().millisecondsSinceEpoch.toRadixString(36)}-${about.first.hashCode.abs().toRadixString(36)}',
      'at': DateTime.now().toUtc().toIso8601String(),
      'about': about,
      'why': why.trim(),
      'outcome': outcome,
      if (receipt != null) 'receipt': _receipt(receipt),
      'describes': _hash(described),
      'files': described.length,
    };
    final area = about.first.split(':')[1].split(RegExp(r'[./]')).first;
    _dir.createSync(recursive: true);
    File(p.join(_dir.path, '$area.jsonl')).writeAsStringSync(
      '${jsonEncode({...note, 'paths': described})}\n',
      mode: FileMode.append,
    );
    return note;
  }

  Map<String, Object?> _receipt(String path) {
    final file = File(p.isAbsolute(path) ? path : p.join(root, path));
    if (!file.existsSync()) throw ManaFailure('No receipt at $path');
    final verdict = jsonDecode(file.readAsStringSync()) as Map;
    return {
      'path': p.relative(file.path, from: root),
      'outcome': verdict['outcome'],
      'acceptanceScore': verdict['acceptanceScore'],
      'results': [
        for (final r in (verdict['results'] as List? ?? const []).cast<Map>())
          '${r['criterionId']}:${r['status']}',
      ],
    };
  }

  String _hash(List<String> paths) {
    final digest = StringBuffer();
    for (final path in paths) {
      final file = File(p.join(root, path));
      digest.write(
        '$path:${file.existsSync() ? sha256Hex(file.readAsBytesSync()) : 'missing'};',
      );
    }
    return sha256Hex(utf8.encode(digest.toString()));
  }

  /// Every note, oldest first, each with `stale` when what it describes changed.
  List<Map<String, Object?>> all() {
    if (!_dir.existsSync()) return [];
    final notes = <Map<String, Object?>>[];
    for (final file in _dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.jsonl'),
    )) {
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final note = (jsonDecode(line) as Map).cast<String, Object?>();
        final paths = ((note['paths'] as List?) ?? const []).cast<String>();
        notes.add({
          ...note,
          'stale': paths.isNotEmpty && _hash(paths) != note['describes'],
        });
      }
    }
    return notes..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
  }

  /// The notes about [coordinate] (`verb:booking.cancel`, `feature:bookings`
  /// also matches `feature:bookings/check-in`), newest first.
  List<Map<String, Object?>> about(String coordinate) => [
    for (final note in all().reversed)
      if ((note['about'] as List).any(
        (c) => c == coordinate || '$c'.startsWith('$coordinate/'),
      ))
        note,
  ];

  /// The note with [id], or null.
  Map<String, Object?>? find(String id) =>
      all().where((n) => n['id'] == id).firstOrNull;
}

/// Verbs whose `because:` names a note [notebook] does not have.
List<String> unexplainedRules(Object? contract, Notebook notebook) {
  final schemas =
      ((contract as Map?)?['components'] as Map?)?['schemas'] as Map? ??
      const {};
  return [
    for (final MapEntry(key: type, :value) in schemas.entries)
      if (value is Map && value['x-mana-verbs'] is List)
        for (final verb in (value['x-mana-verbs'] as List).cast<Map>())
          if (verb['because'] case final String id
              when notebook.find(id) == null)
            '$type.${verb['name']} → $id',
  ];
}
