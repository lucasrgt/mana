import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'bridge.dart';
import 'errors.dart';
import 'incorporate.dart';
import 'json.dart';

const liveUsage =
    'Usage: moments live serve|run [flutter args]|status|patch \'{"property":"value"}\' [--wait]|reset [--wait]|incorporate [--prefix reviews.] [--write] [--project <dir>]';

final _pretty = const JsonEncoder.withIndent('  ');

Future<Map<String, Object?>> _request(String project, String path, [Map<String, Object?>? data]) async {
  final backend = p.join(project, 'moments/.backend/.runtime.json');
  final file = File(File(backend).existsSync() ? backend : p.join(project, 'live-ui/.runtime.json'));
  if (!file.existsSync()) throw const MomentsError('No live UI bridge is running; start it with moments live serve');
  final session = asObject(jsonDecode(file.readAsStringSync()));
  final client = HttpClient();
  try {
    final request = await client.openUrl(data == null ? 'GET' : 'POST', Uri.parse('${session['url']}$path'));
    request.headers
      ..set('Authorization', 'Bearer ${session['token']}')
      ..set('Content-Type', 'application/json');
    if (data != null) request.add(utf8.encode(jsonEncode(data)));
    final response = await request.close().timeout(const Duration(seconds: 5));
    final result = asObject(jsonDecode(await utf8.decoder.bind(response).join()));
    if (response.statusCode < 200 || response.statusCode >= 300) throw MomentsError('${result['error']}');
    return result;
  } finally {
    client.close(force: true);
  }
}

/// The live UI preview: a bridge serving typed overrides to a running app,
/// frame acknowledgments, and the explicit promotion of overrides to source.
Future<int> runLive(List<String> input, String cwd, String Function(String cwd, String? explicit) findProject) async {
  final args = [...input];
  String? take(String flag) {
    final index = args.indexOf(flag);
    if (index < 0) return null;
    if (index + 1 >= args.length) throw MomentsError('$flag needs a value.');
    final value = args[index + 1];
    args.removeRange(index, index + 2);
    return value;
  }

  final project = findProject(cwd, take('--project'));
  final directory = p.join(project, 'live-ui');
  final command = args.firstOrNull;
  final wait = args.remove('--wait');
  switch (command) {
    case 'serve' || 'run':
      final bridge = await Bridge.start(
        directory: directory,
        port: int.parse(Platform.environment['LIVE_UI_PORT'] ?? '18740'),
      );
      print('Live UI bridge: ${bridge.url}');
      Process? child;
      final done = Completer<int>();
      var stopping = false;
      Future<void> stop([int code = 0]) async {
        if (stopping) return;
        stopping = true;
        child?.kill();
        await bridge.close();
        if (!done.isCompleted) done.complete(code);
      }

      final signals = [
        for (final signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) signal.watch().listen((_) => stop()),
      ];
      if (command == 'run') {
        final port = Platform.environment['WEB_PORT'] ?? '5184';
        print('Open http://127.0.0.1:$port/#/sign-up?debugSession=0');
        try {
          child = await Process.start(
            'flutter',
            [
              'run',
              '-d',
              'web-server',
              '--web-hostname=127.0.0.1',
              '--web-port=$port',
              '--dart-define-from-file=${bridge.definesFile}',
              ...args.skip(1),
            ],
            workingDirectory: project,
            mode: ProcessStartMode.inheritStdio,
          );
          unawaited(child.exitCode.then(stop));
        } on ProcessException catch (error) {
          stderr.writeln(error.message);
          await stop(1);
        }
      }
      final code = await done.future;
      for (final signal in signals) {
        await signal.cancel();
      }
      return code;
    case 'status':
      print(_pretty.convert(await _request(project, '/state')));
      return 0;
    case 'patch' || 'reset':
      final Map<String, Object?> body;
      if (command == 'patch') {
        if (args.length != 2) throw const MomentsError(liveUsage);
        body = asObject(jsonDecode(args[1]));
      } else {
        body = {};
      }
      final result = await _request(project, '/$command', body);
      if (wait) {
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        Object? acknowledgment;
        while (DateTime.now().isBefore(deadline)) {
          final acknowledgments = (await _request(project, '/state'))['acknowledgments'] as List? ?? const [];
          acknowledgment = acknowledgments.cast<Map>().where((a) => a['revision'] == result['revision']).firstOrNull;
          if (acknowledgment != null) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        if (acknowledgment == null) {
          print(jsonEncode({...result, 'frameAcknowledged': false}));
          throw const MomentsError(
            'Saved, but no Flutter frame acknowledgment within 8 seconds. Is the pilot running in a visible tab?',
          );
        }
        result['acknowledgment'] = acknowledgment;
      }
      print(_pretty.convert(result));
      return 0;
    case 'incorporate':
      final prefix = take('--prefix');
      if (args.remove('--write')) {
        print(_pretty.convert(applyPlan(project, prefix: prefix)));
      } else {
        final plan = savePlan(project, prefix: prefix);
        print(
          _pretty.convert({
            'changes': plan['changes'],
            'next':
                'Review these replacements, then run incorporate --write with the same --prefix, if specified. Source files are unchanged.',
          }),
        );
      }
      return 0;
    default:
      throw const MomentsError(liveUsage);
  }
}
