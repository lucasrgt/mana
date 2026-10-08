// The Markdown map format (MOMENTS.md) shared with the reference Moments runner.
// Kept behaviour-identical so graph topology digests agree.

final _key = RegExp(r'^(from|run|check|memory|verify|expires):\s*(.*)$');
const _unit = {'s': 1000, 'm': 60000, 'h': 3600000, 'd': 86400000};
final _name = RegExp(r'^[a-z0-9][a-z0-9-]*$');

final class MapState {
  MapState(this.name);
  final String name;
  String? from;
  ({String executor, String ref})? run;
  final checks = <String>[];
  final verify = <({String executor, String ref})>[];
  bool memory = false;
  num? expires;
  final _text = <String>[];
  String describe = '';
}

final class MomentMap {
  String title = '';
  final meta = <String, String>{};
  var layers = <({String name, String type})>[];
  final states = <String, MapState>{};
  final order = <String>[];
}

({String executor, String ref}) _executor(String value) {
  final parts = value.trim().split(RegExp(r'\s+'));
  return (executor: parts.first, ref: parts.skip(1).join(' '));
}

MomentMap parseMap(String text) {
  final map = MomentMap();
  MapState? current;
  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('## ')) {
      final name = line.substring(3).trim();
      if (!_name.hasMatch(name)) throw FormatException('invalid state name: "$name"');
      if (map.states.containsKey(name)) throw FormatException('duplicate state: "$name"');
      current = MapState(name);
      map.states[name] = current;
      map.order.add(name);
      continue;
    }
    if (current == null) {
      if (line.startsWith('# ') && map.title.isEmpty) map.title = line.substring(2).trim();
      final kv = RegExp(r'^(\w[\w-]*):\s*(.*)$').firstMatch(line);
      if (kv != null) map.meta[kv[1]!] = kv[2]!;
      continue;
    }
    final kv = _key.firstMatch(line);
    switch (kv?[1]) {
      case 'from':
        final from = kv![2]!.trim();
        current.from = from.isEmpty ? null : from;
      case 'run':
        current.run = _executor(kv![2]!);
      case 'check':
        current.checks.add(kv![2]!.trim());
      case 'verify':
        current.verify.add(_executor(kv![2]!));
      case 'expires':
        final d = RegExp(r'^(\d+(?:[.,]\d+)?)\s*([smhd])$').firstMatch(kv![2]!.trim());
        if (d == null) {
          throw FormatException('invalid expires in "${current.name}": use a number and s, m, h or d (for example 1h)');
        }
        current.expires = num.parse(d[1]!.replaceFirst(',', '.')) * _unit[d[2]]!;
      case 'memory':
        current.memory = !RegExp(r'^(no|false)$', caseSensitive: false).hasMatch(kv![2]!.trim());
      default:
        current._text.add(line);
    }
  }
  map.layers = (map.meta['layers'] ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).map((s) {
    final parts = s.split('=').map((x) => x.trim()).toList();
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
      throw FormatException('invalid layer: "$s" (use name=type)');
    }
    return (name: parts[0], type: parts[1]);
  }).toList();
  for (final state in map.states.values) {
    state.describe = state._text.join('\n').trim();
    final from = state.from;
    if (from != null && !map.states.containsKey(from)) {
      throw FormatException('"${state.name}" comes from "$from", which does not exist');
    }
  }
  return map;
}

String stateSection({
  required String name,
  String? from,
  ({String executor, String ref})? run,
  List<String> checks = const [],
  String? describe,
}) {
  final lines = ['', '## $name'];
  if (from != null && from.isNotEmpty) lines.add('from: $from');
  if (run != null) lines.add('run: ${run.executor} ${run.ref}');
  for (final check in checks) {
    lines.add('check: $check');
  }
  if (describe != null && describe.isNotEmpty) lines.add(describe.trim());
  return '${lines.join('\n')}\n';
}

String withoutRuns(String text) =>
    text.split('\n').where((line) => !RegExp(r'^(run|verify):\s').hasMatch(line)).join('\n');

List<String> chain(MomentMap map, String name) {
  final out = <String>[];
  for (String? current = name; current != null; current = map.states[current]?.from) {
    if (!map.states.containsKey(current)) throw FormatException('state "$current" does not exist');
    out.insert(0, current);
  }
  return out;
}

({String? base, List<String> rest}) persistentAncestor(MomentMap map, String name) {
  final names = chain(map, name);
  var i = names.length - 1;
  while (i >= 0 && map.states[names[i]]!.memory) {
    i--;
  }
  return (base: i >= 0 ? names[i] : null, rest: names.sublist(i + 1));
}
