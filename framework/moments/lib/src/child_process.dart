import 'dart:async';
import 'dart:io';

import 'platform.dart';

/// Starts [argv] leading a process group of its own, so stopping it reaches
/// the descendants it left in that group (a server's workers, a shell's
/// background job), not only the process the runner started.
Future<Process> startGroup(
  List<String> argv, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  HostPlatform? platform,
}) {
  final command = (platform ?? host).inOwnGroup(argv);
  return Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
  );
}

/// [signal] to [child]'s whole group; to [child] alone when the group is gone.
bool signalGroup(Process child, ProcessSignal signal) => Process.killPid(-child.pid, signal) || child.kill(signal);

/// SIGTERM to the group, SIGKILL after [grace]; then SIGKILL to whatever of
/// the group outlived its leader. [exit] is the caller's exit future when it
/// does more than `child.exitCode` (it must itself be bounded, see
/// [readUntilExit]).
Future<int> stopGroup(Process child, {Future<int>? exit, Duration grace = const Duration(seconds: 5)}) async {
  signalGroup(child, ProcessSignal.sigterm);
  await child.exitCode.timeout(
    grace,
    onTimeout: () {
      signalGroup(child, ProcessSignal.sigkill);
      return child.exitCode;
    },
  );
  Process.killPid(-child.pid, ProcessSignal.sigkill);
  return exit ?? child.exitCode;
}

/// Reads [child]'s output into [stdout] and [stderr] until both pipes close,
/// or until [drain] after the child exited: a descendant that keeps a pipe
/// open (a daemon started by a script) never holds the caller past its child.
Future<void> readUntilExit(
  Process child, {
  required void Function(List<int> data) stdout,
  required void Function(List<int> data) stderr,
  Duration drain = const Duration(milliseconds: 500),
}) async {
  final out = Completer<void>(), err = Completer<void>();
  void finish(Completer<void> done) {
    if (!done.isCompleted) done.complete();
  }

  final subscriptions = [
    child.stdout.listen(stdout, onDone: () => finish(out), onError: (Object _) => finish(out), cancelOnError: true),
    child.stderr.listen(stderr, onDone: () => finish(err), onError: (Object _) => finish(err), cancelOnError: true),
  ];
  final closed = Future.wait([out.future, err.future]);
  final afterExit = child.exitCode.then((_) => Future<void>.delayed(drain));
  await Future.any([closed, afterExit]);
  for (final subscription in subscriptions) {
    await subscription.cancel();
  }
}
