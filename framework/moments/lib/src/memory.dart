import 'dart:io';

/// Proportional set size of [root] and its descendants, read from /proc.
/// Shared pages are split among their users, so sums do not double count.
int treeMemory(int root) {
  final parents = <int, int>{};
  for (final entry in Directory('/proc').listSync(followLinks: false)) {
    final name = entry.path.substring(6);
    final pid = int.tryParse(name);
    if (pid == null) continue;
    try {
      final stat = File('/proc/$pid/stat').readAsStringSync();
      parents[pid] = int.parse(stat.substring(stat.lastIndexOf(')') + 2).split(' ')[1]);
    } on Object {
      // The process ended while listing.
    }
  }
  var total = 0;
  for (final pid in parents.keys) {
    var current = pid;
    while (current > 1 && current != root) {
      current = parents[current] ?? 0;
    }
    if (current != root) continue;
    try {
      final rollup = File('/proc/$pid/smaps_rollup').readAsStringSync();
      final match = RegExp(r'^Pss:\s+(\d+) kB', multiLine: true).firstMatch(rollup);
      if (match != null) total += int.parse(match[1]!) * 1024;
    } on Object {
      // Not readable or already gone.
    }
  }
  return total;
}

/// Every descendant pid of [root] (not including it).
List<int> descendants(int root) {
  final parents = <int, int>{};
  for (final entry in Directory('/proc').listSync(followLinks: false)) {
    final pid = int.tryParse(entry.path.substring(6));
    if (pid == null) continue;
    try {
      final stat = File('/proc/$pid/stat').readAsStringSync();
      parents[pid] = int.parse(stat.substring(stat.lastIndexOf(')') + 2).split(' ')[1]);
    } on Object {
      // Gone.
    }
  }
  return [
    for (final pid in parents.keys)
      if (pid != root &&
          () {
            var current = pid;
            while (current > 1 && current != root) {
              current = parents[current] ?? 0;
            }
            return current == root;
          }())
        pid,
  ];
}
