import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mana/runtime.dart' show ProcessIdentity;
import 'package:path/path.dart' as p;

import 'errors.dart';

/// Runs a host command and answers its result; tests inject fakes for `ps`
/// and `sysctl`.
typedef Exec = ProcessResult Function(String executable, List<String> arguments, {Map<String, String>? environment});

ProcessResult _exec(String executable, List<String> arguments, {Map<String, String>? environment}) =>
    Process.runSync(executable, arguments, environment: environment);

/// What the runner needs from the operating system to own processes: who a
/// process is (pid, start and boot, so a reused pid is never mistaken for
/// ours), every live process, an exclusive lock that dies with its holder,
/// starting a child in a process group of its own, and opening a URL.
abstract interface class HostPlatform {
  String get name;
  ProcessIdentity? identity(int pid);

  /// Every live process by pid; null when the listing failed and the caller
  /// should try again.
  Map<int, ProcessIdentity>? processes();

  /// An exclusive, non-blocking lock on [file], released by the returned
  /// function or by the holder's death; refused while another holds it.
  Future<Future<void> Function()> lock(String file);

  /// [argv] wrapped so the child leads a process group of its own (pid ==
  /// pgid): stopping the group reaches every descendant still in it.
  List<String> inOwnGroup(List<String> argv);

  List<String> openUrl(String url);

  /// The command line of [pid], or null when it is gone or unreadable.
  String? commandLine(int pid);

  /// The parent of every listed process, zombies included.
  Map<int, int> parents();

  /// Bytes of memory [root] and its descendants use: proportional set size
  /// on Linux, resident set size on macOS (shared pages counted per process).
  int treeMemory(int root);
}

/// The host this process runs on, chosen at runtime.
final HostPlatform host = Platform.isMacOS
    ? MacPlatform()
    : Platform.isLinux
    ? LinuxPlatform()
    : const _Unsupported();

ProcessIdentity? processIdentity(int pid) => host.identity(pid);

bool sameProcess(Map<String, Object?>? record, {HostPlatform? platform}) {
  final pid = record?['pid'];
  if (pid is! int) return false;
  final current = (platform ?? host).identity(pid);
  return current != null && current.start == record!['start'] && current.boot == record['boot'];
}

bool signalOwnedProcess(Map<String, Object?> record, ProcessSignal signal) =>
    sameProcess(record) && Process.killPid(record['pid']! as int, signal);

/// Every descendant pid of [root] (not including it), from [processes].
List<int> descendantsOf(int root, Map<int, int> parents) => [
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

List<int> descendants(int root, {HostPlatform? platform}) => descendantsOf(root, (platform ?? host).parents());

final class _Unsupported implements HostPlatform {
  const _Unsupported();
  static Never _refuse() => throw MomentsError('Moments runs on Linux and macOS, not ${Platform.operatingSystem}');
  @override
  String get name => Platform.operatingSystem;
  @override
  ProcessIdentity? identity(int pid) => _refuse();
  @override
  Map<int, ProcessIdentity>? processes() => _refuse();
  @override
  Future<Future<void> Function()> lock(String file) => _refuse();
  @override
  List<String> inOwnGroup(List<String> argv) => _refuse();
  @override
  List<String> openUrl(String url) => _refuse();
  @override
  String? commandLine(int pid) => _refuse();
  @override
  Map<int, int> parents() => _refuse();
  @override
  int treeMemory(int root) => _refuse();
}

/// `/proc` for identity and memory, `flock(1)` for the lock, `setsid(1)` for
/// process groups (util-linux, like `flock`). [proc] is a fake root in tests.
final class LinuxPlatform implements HostPlatform {
  LinuxPlatform({this.proc = '/proc'});
  final String proc;
  String? _boot;

  @override
  String get name => 'linux';

  @override
  ProcessIdentity? identity(int pid) {
    if (pid < 1) return null;
    final String stat;
    try {
      stat = File('$proc/$pid/stat').readAsStringSync();
    } on FileSystemException {
      return null;
    }
    final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
    if (const ['Z', 'X'].contains(fields[0])) return null;
    _boot ??= File('$proc/sys/kernel/random/boot_id').readAsStringSync().trim();
    return (pid: pid, start: fields[19], boot: _boot!, parent: int.parse(fields[1]));
  }

  @override
  Map<int, ProcessIdentity>? processes() {
    final List<FileSystemEntity> entries;
    try {
      entries = Directory(proc).listSync(followLinks: false);
    } on FileSystemException {
      // A process can exit while /proc is being listed.
      return null;
    }
    return {
      for (final entry in entries)
        if (int.tryParse(p.basename(entry.path)) case final id?)
          if (identity(id) case final value?) id: value,
    };
  }

  /// `flock(1)` holds the kernel lock in a child that lives until released,
  /// so even two acquisitions from one process exclude each other.
  @override
  Future<Future<void> Function()> lock(String file) async {
    final Process child;
    try {
      child = await Process.start('flock', [
        '--exclusive',
        '--nonblock',
        file,
        'sh',
        '-c',
        'echo locked; read _ || true',
      ]);
    } on ProcessException {
      throw const MomentsError('Cannot start flock for instance ownership');
    }
    final exited = child.exitCode;
    final locked = Completer<void>();
    child.stdout.transform(utf8.decoder).listen((chunk) {
      if (chunk.contains('locked') && !locked.isCompleted) locked.complete();
    });
    child.stderr.drain<void>();
    unawaited(
      exited.then((_) {
        if (!locked.isCompleted)
          locked.completeError(const MomentsError('Another instance lifecycle operation is running'));
      }),
    );
    try {
      await locked.future;
    } on Object {
      await child.stdin.close().catchError((_) {});
      await exited;
      rethrow;
    }
    var released = false;
    return () async {
      if (!released) {
        released = true;
        await child.stdin.close().catchError((_) {});
      }
      await exited;
    };
  }

  @override
  List<String> inOwnGroup(List<String> argv) => ['setsid', ...argv];

  @override
  List<String> openUrl(String url) => ['xdg-open', url];

  @override
  String? commandLine(int pid) {
    try {
      return File('$proc/$pid/cmdline').readAsStringSync();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Map<int, int> parents() {
    final parents = <int, int>{};
    for (final entry in Directory(proc).listSync(followLinks: false)) {
      final pid = int.tryParse(p.basename(entry.path));
      if (pid == null) continue;
      try {
        final stat = File('$proc/$pid/stat').readAsStringSync();
        parents[pid] = int.parse(stat.substring(stat.lastIndexOf(')') + 2).split(' ')[1]);
      } on Object {
        // The process ended while listing.
      }
    }
    return parents;
  }

  /// Shared pages are split among their users, so sums do not double count.
  @override
  int treeMemory(int root) {
    var total = 0;
    final parents = this.parents();
    for (final pid in [root, ...descendantsOf(root, parents)]) {
      if (!parents.containsKey(pid)) continue;
      try {
        final rollup = File('$proc/$pid/smaps_rollup').readAsStringSync();
        final match = RegExp(r'^Pss:\s+(\d+) kB', multiLine: true).firstMatch(rollup);
        if (match != null) total += int.parse(match[1]!) * 1024;
      } on Object {
        // Not readable or already gone.
      }
    }
    return total;
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
final _uuid = RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$');

/// `ps` for identity and memory, `sysctl` for the boot, an fcntl lock
/// (`RandomAccessFile.lock`) and Perl's `setpgrp` for process groups; macOS
/// ships no `/proc`, `flock(1)` or `setsid(1)`. [exec] is a fake in tests.
final class MacPlatform implements HostPlatform {
  MacPlatform({Exec exec = _exec}) : _run = exec;
  final Exec _run;
  String? _boot;
  final _held = <String>{};

  // C locale and UTC: `lstart` must read the same in every process.
  static const _psEnvironment = {'LC_ALL': 'C', 'TZ': 'UTC'};

  @override
  String get name => 'macos';

  String _command(String executable, List<String> arguments, {Map<String, String>? environment}) {
    final result = _run(executable, arguments, environment: environment);
    return result.exitCode == 0 ? '${result.stdout}' : '';
  }

  /// A boot as a UUID: `kern.bootsessionuuid`, else one derived from
  /// `kern.boottime`, which changes only when the host restarts.
  String _bootId() => _boot ??= () {
    final session = _command('sysctl', ['-n', 'kern.bootsessionuuid']).trim().toLowerCase();
    if (_uuid.hasMatch(session)) return session;
    final time = RegExp(r'sec = (\d+), usec = (\d+)').firstMatch(_command('sysctl', ['-n', 'kern.boottime']));
    if (time == null) throw const MomentsError('Cannot read the macOS boot identity (sysctl kern.boottime)');
    final hex = sha256.convert(utf8.encode('kern.boottime:${time[1]}.${time[2]}')).toString();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }();

  /// `lstart` (`Mon Nov  1 10:00:00 2026`, UTC) as digits, `20261101100000`:
  /// second resolution, which the pid narrows to one process.
  static String? _start(List<String> fields) {
    if (fields.length != 5) return null;
    final month = _months.indexOf(fields[1]) + 1;
    final day = int.tryParse(fields[2]), year = int.tryParse(fields[4]);
    final time = RegExp(r'^(\d{2}):(\d{2}):(\d{2})$').firstMatch(fields[3]);
    if (month == 0 || day == null || year == null || time == null) return null;
    String two(int value) => value.toString().padLeft(2, '0');
    return '$year${two(month)}${two(day)}${time[1]}${time[2]}${time[3]}';
  }

  ProcessIdentity? _line(String line, {int? pid}) {
    final fields = line.trim().split(RegExp(r'\s+'));
    final offset = pid == null ? 1 : 0;
    if (fields.length != offset + 7) return null;
    final id = pid ?? int.tryParse(fields[0]), parent = int.tryParse(fields[offset]);
    final state = fields[offset + 1], start = _start(fields.sublist(offset + 2));
    if (id == null || parent == null || start == null || state.startsWith('Z')) return null;
    return (pid: id, start: start, boot: _bootId(), parent: parent);
  }

  @override
  ProcessIdentity? identity(int pid) {
    if (pid < 1) return null;
    final out = _command('ps', ['-o', 'ppid=,stat=,lstart=', '-p', '$pid'], environment: _psEnvironment).trim();
    return out.isEmpty ? null : _line(out, pid: pid);
  }

  @override
  Map<int, ProcessIdentity>? processes() {
    final result = _run('ps', ['-axo', 'pid=,ppid=,stat=,lstart='], environment: _psEnvironment);
    if (result.exitCode != 0) return null;
    return {
      for (final line in '${result.stdout}'.split('\n'))
        if (_line(line) case final value?) value.pid: value,
    };
  }

  @override
  Future<Future<void> Function()> lock(String file) async {
    final path = p.normalize(p.absolute(file));
    // fcntl locks belong to the process: a second acquisition from this one
    // would succeed, so it is refused here as flock refuses it on Linux.
    if (!_held.add(path)) throw const MomentsError('Another instance lifecycle operation is running');
    final RandomAccessFile handle;
    try {
      handle = await File(path).open(mode: FileMode.append);
    } on FileSystemException {
      _held.remove(path);
      throw const MomentsError('Cannot open the instance ownership lock');
    }
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException {
      await handle.close();
      _held.remove(path);
      throw const MomentsError('Another instance lifecycle operation is running');
    }
    var released = false;
    return () async {
      if (released) return;
      released = true;
      await handle.unlock().catchError((_) => handle);
      await handle.close();
      _held.remove(path);
    };
  }

  @override
  List<String> inOwnGroup(List<String> argv) => [
    '/usr/bin/perl',
    '-e',
    r'setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"',
    '--',
    ...argv,
  ];

  @override
  List<String> openUrl(String url) => ['open', url];

  @override
  String? commandLine(int pid) {
    final out = _command('ps', ['-o', 'command=', '-p', '$pid']).trim();
    return out.isEmpty ? null : out;
  }

  @override
  Map<int, int> parents() => {
    for (final line in _command('ps', ['-axo', 'pid=,ppid=']).split('\n'))
      if (line.trim().split(RegExp(r'\s+')) case [final pid, final parent])
        if ((int.tryParse(pid), int.tryParse(parent)) case (final int id, final int up)) id: up,
  };

  @override
  int treeMemory(int root) {
    final parents = <int, int>{}, resident = <int, int>{};
    for (final line in _command('ps', ['-axo', 'pid=,ppid=,rss=']).split('\n')) {
      final fields = line.trim().split(RegExp(r'\s+'));
      if (fields.length != 3) continue;
      final [pid, parent, kilobytes] = [for (final field in fields) int.tryParse(field)];
      if (pid == null || parent == null || kilobytes == null) continue;
      parents[pid] = parent;
      resident[pid] = kilobytes * 1024;
    }
    return [root, ...descendantsOf(root, parents)].fold(0, (sum, pid) => sum + (resident[pid] ?? 0));
  }
}
