import 'dart:convert';
import 'dart:io';

/// Serves `{value, pid, ...environment}` from `./source` on the given port.
Future<void> main(List<String> args) async {
  final value = File('source').readAsStringSync();
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, int.parse(args.first));
  final env = Platform.environment;
  await for (final request in server) {
    request.response
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'value': value,
          'pid': pid,
          'leaked': env.containsKey('MANA_AMBIENT_CANARY'),
          'setting': env['APP_SETTING'],
          'home': env['HOME'],
          'tmp': env['TMPDIR'],
          'run': env['MANA_RESOURCE_RUN'],
        }),
      );
    await request.response.close();
  }
}
