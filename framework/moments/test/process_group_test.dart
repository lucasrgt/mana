import 'dart:convert';
import 'dart:io';

import 'package:moments/src/child_process.dart';
import 'package:moments/src/platform.dart';
import 'package:moments/src/services.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

final dart = Platform.resolvedExecutable;

int? groupOf(int pid) => int.tryParse('${Process.runSync('ps', ['-o', 'pgid=', '-p', '$pid']).stdout}'.trim());

bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

Future<int> pidIn(String file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final text = File(file).existsSync() ? File(file).readAsStringSync().trim() : '';
    if (int.tryParse(text) case final pid?) return pid;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('No pid in $file');
}

/// A service whose shell leaves a grandchild holding the shared stdout: the
/// shape of a server that starts a watcher or daemon of its own.
Future<({Services services, String cwd})> service(String grandchild) async {
  final cwd = temporary('moment-group-'), port = await freePort();
  File(p.join(cwd, 'source')).writeAsStringSync('one');
  final serve = [
    'sh',
    '-c',
    '$grandchild & echo \$! > ${p.join(cwd, 'grandchild.pid')}; exec $dart ${p.join(package, 'test/programs/source_server.dart')} $port',
  ];
  final services = Services(
    directory: cwd,
    log: (_) {},
    definitions: [
      ServiceDefinition(
        name: 'held',
        cwd: cwd,
        port: port,
        serve: serve,
        watch: const ['source'],
        timeout: const Duration(seconds: 20),
        ready: () async {
          final client = HttpClient()..connectionTimeout = const Duration(milliseconds: 500);
          try {
            final response = await (await client.getUrl(Uri.parse('http://127.0.0.1:$port'))).close();
            await response.drain<void>();
            return response.statusCode == 200;
          } on Object {
            return false;
          } finally {
            client.close(force: true);
          }
        },
      ),
    ],
  );
  await services.ensure();
  return (services: services, cwd: cwd);
}

void main() {
  test('a child leads its own process group, so a group signal reaches what it started', () async {
    final child = await startGroup(['sh', '-c', 'sleep 600 & echo \$!; wait']);
    final grandchild = int.parse((await child.stdout.transform(utf8.decoder).first).trim());
    expect(groupOf(child.pid), child.pid);
    expect(groupOf(grandchild), child.pid);
    await stopGroup(child, grace: const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(alive(grandchild), isFalse);
  });

  test('the macOS launcher (Perl setpgrp) also makes the child a group leader with the same pid', () async {
    final argv = MacPlatform().inOwnGroup(['sh', '-c', r'echo $$; sleep 600']);
    expect(argv.first, '/usr/bin/perl');
    // This host's Perl runs the same script; macOS ships it at /usr/bin/perl.
    final child = await Process.start('perl', argv.skip(1).toList());
    final reported = int.parse((await child.stdout.transform(utf8.decoder).first).trim());
    expect(reported, child.pid, reason: 'exec keeps the pid, so the runner signals what it recorded');
    expect(groupOf(child.pid), child.pid);
    await stopGroup(child, grace: const Duration(seconds: 2));
  });

  test('stopping a service whose grandchild ignores SIGTERM and holds stdout does not hang', () async {
    final s = await service(r'(trap "" TERM; exec sleep 600)');
    final grandchild = await pidIn(p.join(s.cwd, 'grandchild.pid'));
    addTearDown(() => Process.killPid(grandchild, ProcessSignal.sigkill));
    expect(alive(grandchild), isTrue);
    await s.services.close().timeout(const Duration(seconds: 15));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(alive(grandchild), isFalse, reason: 'the group outlived its leader and is stopped with it');
    expect(s.services.status().first['phase'], 'stopped');
  });

  test('a descendant that left the group keeps the pipe, but shutdown stops waiting once the child exited', () async {
    final s = await service('setsid sleep 600');
    final grandchild = await pidIn(p.join(s.cwd, 'grandchild.pid'));
    addTearDown(() => Process.killPid(grandchild, ProcessSignal.sigkill));
    final clock = Stopwatch()..start();
    await s.services.close().timeout(const Duration(seconds: 15));
    expect(clock.elapsed, lessThan(const Duration(seconds: 6)));
    // Outside the group nothing reaches it; the lifecycle's process records
    // are what `moments down` stops.
    expect(alive(grandchild), isTrue);
  });

  test('a command whose grandchild holds the pipe finishes when the command exits', () async {
    final child = await startGroup(['sh', '-c', 'setsid sleep 600 & echo \$!; exit 3']);
    final out = <int>[];
    final read = readUntilExit(child, stdout: out.addAll, stderr: (_) {}, drain: const Duration(milliseconds: 200));
    await read.timeout(const Duration(seconds: 5));
    final grandchild = int.parse(utf8.decode(out).trim());
    addTearDown(() => Process.killPid(grandchild, ProcessSignal.sigkill));
    expect(await child.exitCode, 3);
    expect(alive(grandchild), isTrue);
  });

  test('the host platform is chosen at runtime', () {
    expect(host.name, Platform.isMacOS ? 'macos' : 'linux');
    expect(host.inOwnGroup(['x']).last, 'x');
  });
}
