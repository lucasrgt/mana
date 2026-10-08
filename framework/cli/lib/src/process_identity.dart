import 'dart:io';

/// A process as the kernel knows it: pid, start tick and boot. A pid alone is
/// reused; the triple names one process for the life of the host.
typedef ProcessIdentity = ({int pid, String start, String boot, int parent});

String? _boot;

ProcessIdentity? processIdentity(int pid) {
  if (pid < 1) return null;
  final String stat;
  try {
    stat = File('/proc/$pid/stat').readAsStringSync();
  } on FileSystemException {
    return null;
  }
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  if (const ['Z', 'X'].contains(fields[0])) return null;
  _boot ??= File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim();
  return (
    pid: pid,
    start: fields[19],
    boot: _boot!,
    parent: int.parse(fields[1]),
  );
}

Map<String, Object?> identityJson(ProcessIdentity identity) => {
  'pid': identity.pid,
  'start': identity.start,
  'boot': identity.boot,
  'parent': identity.parent,
};

bool sameProcess(Map<String, Object?>? record) {
  final pid = record?['pid'];
  if (pid is! int) return false;
  final current = processIdentity(pid);
  return current != null &&
      current.start == record!['start'] &&
      current.boot == record['boot'];
}

bool signalOwnedProcess(Map<String, Object?> record, ProcessSignal signal) =>
    sameProcess(record) && Process.killPid(record['pid']! as int, signal);
