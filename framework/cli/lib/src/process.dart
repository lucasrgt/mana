import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'manifest.dart';

typedef RunResult = ({int code, String output});

List<String> agentCommand(
  String root,
  Config config,
  String name, [
  Map<String, String>? variables,
]) {
  final agent = (table(config, 'agents')[name]! as Map).cast<String, Object?>();
  final values = {...variables ?? Platform.environment, 'MANA_PROJECT': root};
  final command = [
    for (final value in argv(agent['command'] ?? [name], 'agent.command'))
      expand(value, values),
  ];
  final override = Platform.environment['MANA_${name.toUpperCase()}_BIN'];
  if (override != null && override.isNotEmpty) {
    command[0] = override;
  } else if (command.length == 1 && command[0] == name) {
    try {
      final lookup = Process.runSync('mise', [
        'which',
        name,
      ], workingDirectory: root);
      final found = (lookup.stdout as String).trim();
      if (lookup.exitCode == 0 && found.startsWith('/')) command[0] = found;
    } on ProcessException {
      // Without mise the bare name resolves through PATH.
    }
  }
  return command;
}

/// Runs [command] without a shell. SIGINT and SIGTERM reach the child, which
/// gets three seconds before SIGKILL; a timeout reports 124 as `timeout` does.
Future<RunResult> run(
  List<String> command, {
  required String cwd,
  Map<String, String>? environment,
  Duration? timeout,
  bool capture = false,
}) async {
  final child = await Process.start(
    command.first,
    command.skip(1).toList(),
    workingDirectory: cwd,
    environment: environment,
    includeParentEnvironment: environment == null,
    mode: capture ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
  );
  final output = StringBuffer();
  final drained = <Future<void>>[];
  if (capture) {
    void collect(String chunk) {
      output.write(chunk);
      if (output.length > 65536) {
        final kept = output.toString().substring(output.length - 65536);
        output
          ..clear()
          ..write(kept);
      }
    }

    drained
      ..add(
        child.stdout.transform(utf8.decoder).listen(collect).asFuture<void>(),
      )
      ..add(
        child.stderr.transform(utf8.decoder).listen(collect).asFuture<void>(),
      );
  }
  var expired = false;
  Timer? escalation;
  void stop(ProcessSignal signal) {
    child.kill(signal);
    escalation ??= Timer(
      const Duration(seconds: 3),
      () => child.kill(ProcessSignal.sigkill),
    );
  }

  final subscriptions = [
    ProcessSignal.sigint.watch().listen((_) => stop(ProcessSignal.sigint)),
    ProcessSignal.sigterm.watch().listen((_) => stop(ProcessSignal.sigterm)),
  ];
  final timer = timeout == null
      ? null
      : Timer(timeout, () {
          expired = true;
          stop(ProcessSignal.sigterm);
        });
  try {
    final code = await child.exitCode;
    await Future.wait(drained);
    return (
      code: expired
          ? 124
          : code == -2
          ? 130
          : code < 0
          ? 143
          : code,
      output: output.toString(),
    );
  } finally {
    timer?.cancel();
    escalation?.cancel();
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
  }
}
