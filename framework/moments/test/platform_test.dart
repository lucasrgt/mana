import 'dart:io';

import 'package:mana/runtime.dart' as mana show processIdentity;
import 'package:moments/src/platform.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

Matcher throwing(String text) => throwsA(predicate((e) => '$e'.contains(text), 'mentions "$text"'));

const boot = '0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0';

/// A /proc tree with one process per entry: `pid: (parent, state, start, pss kB)`.
String fakeProc(Map<int, (int, String, int, int)> processes) {
  final root = temporary('moments-proc-');
  Directory(p.join(root, 'sys/kernel/random')).createSync(recursive: true);
  File(p.join(root, 'sys/kernel/random/boot_id')).writeAsStringSync('$boot\n');
  for (final MapEntry(key: pid, value: (parent, state, start, pss)) in processes.entries) {
    Directory(p.join(root, '$pid')).createSync();
    final fields = [state, '$parent', ...List.filled(17, '0'), '$start', '0'];
    File(p.join(root, '$pid/stat')).writeAsStringSync('$pid (a) b) ${fields.join(' ')}\n');
    File(p.join(root, '$pid/smaps_rollup')).writeAsStringSync('Rss: 9 kB\nPss:    $pss kB\n');
    File(p.join(root, '$pid/cmdline')).writeAsStringSync('cmd-$pid\x00--flag');
  }
  return root;
}

typedef Call = ({String executable, List<String> arguments, Map<String, String>? environment});

/// `ps` and `sysctl` answers keyed by their argv; anything else fails.
({MacPlatform platform, List<Call> calls}) fakeMac(Map<String, String> answers) {
  final calls = <Call>[];
  ProcessResult exec(String executable, List<String> arguments, {Map<String, String>? environment}) {
    calls.add((executable: executable, arguments: arguments, environment: environment));
    final answer = answers[[executable, ...arguments].join(' ')];
    return ProcessResult(0, answer == null ? 1 : 0, answer ?? '', '');
  }

  return (platform: MacPlatform(exec: exec), calls: calls);
}

const session = {'sysctl -n kern.bootsessionuuid': 'A1B2C3D4-0000-4000-8000-00000000BEEF\n'};

void main() {
  group('Linux', () {
    test('identity reads /proc exactly as the CLI does, for the real process', () {
      final linux = LinuxPlatform();
      expect(linux.identity(pid), mana.processIdentity(pid));
      expect(linux.identity(pid)!.boot, File('/proc/sys/kernel/random/boot_id').readAsStringSync().trim());
    }, testOn: 'linux');

    test('identity parses start and parent past a command name with spaces and parentheses', () {
      final linux = LinuxPlatform(proc: fakeProc({10: (1, 'S', 4242, 0), 11: (10, 'Z', 5, 0)}));
      expect(linux.identity(10), (pid: 10, start: '4242', boot: boot, parent: 1));
      expect(linux.identity(11), isNull, reason: 'a zombie is no longer the process that was recorded');
      expect(linux.identity(12), isNull);
      expect(linux.identity(0), isNull);
    });

    test('processes, parents, command line and memory follow the tree', () {
      final linux = LinuxPlatform(
        proc: fakeProc({
          1: (0, 'S', 1, 100),
          10: (1, 'S', 2, 1),
          11: (10, 'S', 3, 2),
          12: (11, 'Z', 4, 4),
          20: (1, 'S', 5, 8),
        }),
      );
      expect(linux.processes()!.keys.toSet(), {1, 10, 11, 20});
      expect(linux.parents(), {1: 0, 10: 1, 11: 10, 12: 11, 20: 1});
      expect(descendants(10, platform: linux)..sort(), [11, 12]);
      expect(linux.treeMemory(10), (1 + 2 + 4) * 1024);
      expect(linux.commandLine(11), 'cmd-11\x00--flag');
      expect(linux.commandLine(99), isNull);
      expect(linux.inOwnGroup(['flutter', 'run']), ['setsid', 'flutter', 'run']);
      expect(linux.openUrl('http://127.0.0.1:1/x'), ['xdg-open', 'http://127.0.0.1:1/x']);
    });

    test('an unreadable /proc listing is unavailable, not an empty process table', () {
      expect(LinuxPlatform(proc: p.join(temporary(), 'missing')).processes(), isNull);
    });

    test('sameProcess needs the recorded start and boot, not only the pid', () {
      final linux = LinuxPlatform(proc: fakeProc({10: (1, 'S', 4242, 0)}));
      expect(sameProcess({'pid': 10, 'start': '4242', 'boot': boot}, platform: linux), isTrue);
      expect(sameProcess({'pid': 10, 'start': '4243', 'boot': boot}, platform: linux), isFalse);
      expect(sameProcess({'pid': 10, 'start': '4242', 'boot': 'other'}, platform: linux), isFalse);
      expect(sameProcess({'pid': '10'}, platform: linux), isFalse);
    });
  });

  group('macOS (fake ps and sysctl)', () {
    test('identity reads ppid, state and lstart in UTC and the C locale', () {
      final mac = fakeMac({...session, 'ps -o ppid=,stat=,lstart= -p 42': '    1 Ss   Mon Nov  2 09:05:07 2026\n'});
      expect(mac.platform.identity(42), (
        pid: 42,
        start: '20261102090507',
        boot: 'a1b2c3d4-0000-4000-8000-00000000beef',
        parent: 1,
      ));
      expect(mac.calls.first.environment, {'LC_ALL': 'C', 'TZ': 'UTC'});
    });

    test('a gone, zombie or unparseable process has no identity', () {
      final mac = fakeMac({
        ...session,
        'ps -o ppid=,stat=,lstart= -p 43': '    1 Z    Mon Nov  2 09:05:07 2026\n',
        'ps -o ppid=,stat=,lstart= -p 44': '    1 S    yesterday\n',
      });
      expect(mac.platform.identity(41), isNull);
      expect(mac.platform.identity(43), isNull);
      expect(mac.platform.identity(44), isNull);
      expect(mac.platform.identity(0), isNull);
    });

    test('without kern.bootsessionuuid the boot is derived from kern.boottime, stable until a restart', () {
      String bootOf(String boottime) => fakeMac({
        'sysctl -n kern.boottime': boottime,
        'ps -o ppid=,stat=,lstart= -p 42': '1 S Mon Nov  2 09:05:07 2026',
      }).platform.identity(42)!.boot;
      final first = bootOf('{ sec = 1761980000, usec = 12 } Sat Nov  1 07:33:20 2026\n');
      expect(first, matches(RegExp(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')));
      expect(bootOf('{ sec = 1761980000, usec = 12 } Sat Nov  1 07:33:20 2026\n'), first);
      expect(bootOf('{ sec = 1761990000, usec = 12 } Sat Nov  1 10:20:00 2026\n'), isNot(first));
      expect(
        () => fakeMac({'ps -o ppid=,stat=,lstart= -p 42': '1 S Mon Nov  2 09:05:07 2026'}).platform.identity(42),
        throwing('boot identity'),
      );
    });

    test('process listing, parents, command line and memory come from ps', () {
      final mac = fakeMac({
        ...session,
        'ps -axo pid=,ppid=,stat=,lstart=':
            '    1     0 Ss   Sat Nov  1 07:33:20 2026\n'
            '   10     1 S    Sat Nov  1 08:00:00 2026\n'
            '   11    10 Z    Sat Nov  1 08:00:01 2026\n',
        'ps -axo pid=,ppid=': '1 0\n10 1\n11 10\n12 11\n',
        'ps -axo pid=,ppid=,rss=': '1 0 100\n10 1 1\n11 10 2\n12 11 4\n20 1 8\n',
        'ps -o command= -p 10': 'flutter test w0_test.dart\n',
      });
      expect(mac.platform.processes()!.keys.toSet(), {1, 10});
      expect(mac.platform.processes()![10]!.start, '20261101080000');
      expect(mac.platform.parents(), {1: 0, 10: 1, 11: 10, 12: 11});
      expect(descendants(10, platform: mac.platform)..sort(), [11, 12]);
      expect(mac.platform.treeMemory(10), (1 + 2 + 4) * 1024);
      expect(mac.platform.commandLine(10), 'flutter test w0_test.dart');
      expect(mac.platform.commandLine(99), isNull);
      expect(fakeMac(const {}).platform.processes(), isNull);
    });

    test('process groups use Perl setpgrp; URLs open with open(1)', () {
      final mac = MacPlatform();
      expect(mac.inOwnGroup(['flutter', 'run']).sublist(3), ['--', 'flutter', 'run']);
      expect(mac.openUrl('http://127.0.0.1:1/x'), ['open', 'http://127.0.0.1:1/x']);
    });

    test('the fcntl lock excludes this process and others, and is free again once released', () async {
      final directory = temporary(), file = p.join(directory, '.operation.lock');
      final mac = MacPlatform();
      final release = await mac.lock(file);
      await expectLater(mac.lock(file), throwing('Another instance lifecycle operation is running'));
      final other = await Process.run(Platform.resolvedExecutable, [
        'run',
        p.join(package, 'test/programs/try_lock.dart'),
        file,
      ]);
      expect(other.stdout, contains('refused'), reason: '${other.stderr}');
      await release();
      final again = await mac.lock(file);
      await again();
    });
  });
}
