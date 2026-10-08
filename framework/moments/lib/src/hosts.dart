import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mana/mana.dart' show identityJson, processIdentity, savePrivateState, uuidV4;
import 'package:path/path.dart' as p;

import 'browser.dart';
import 'errors.dart';
import 'preview_host.dart';
import 'private_fs.dart';

const hostUsage =
    'Usage: moments host browser <private-dir> | moments host preview <private-dir> <port> <actor-origin> [...]';

Future<ProcessSignal> _stopped() =>
    Future.any([ProcessSignal.sigint.watch().first, ProcessSignal.sigterm.watch().first]);

/// A browser host for tools whose browser APIs run in a constrained REPL: this
/// process owns the Unix socket, the tool consumes bounded request files with
/// its browser API and answers with response files.
Future<int> _browserHost(String input) async {
  final directory = p.normalize(p.absolute(input));
  if (entityType(directory) != FileSystemEntityType.directory ||
      realPath(directory) != directory ||
      !private(directory)) {
    throw const MomentsError('Private host directory required');
  }
  final bindings = readJsonObject(p.join(directory, 'bindings.json'), 65536, 'Invalid browser bindings');
  final providerId = bindings['provider'];
  if (providerId is! String) throw const MomentsError('Invalid browser bindings');
  Future<Map<String, Object?>> request(String method, String target) async {
    final id = uuidV4();
    final requestFile = p.join(directory, '$id.request.json'), responseFile = p.join(directory, '$id.response.json');
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    savePrivateState(requestFile, {
      'version': 1,
      'id': id,
      'method': method,
      if (const ['open', 'find'].contains(method)) 'url': target else 'tabId': target,
      'provider': providerId,
      'deadline': deadline.millisecondsSinceEpoch,
    });
    try {
      while (DateTime.now().isBefore(deadline)) {
        if (exists(responseFile)) {
          final response = readJsonObject(responseFile, 16384, 'Invalid host response');
          if (response['version'] != 1 ||
              response['id'] != id ||
              response['error'] != null ||
              response['result'] is! Map) {
            throw const MomentsError('Browser host did not confirm operation');
          }
          return (response['result']! as Map).cast();
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      throw const MomentsError('Browser tool host timed out');
    } finally {
      for (final file in [requestFile, responseFile]) {
        if (exists(file)) File(file).deleteSync();
      }
    }
  }

  final tabs = [
    for (final tab in ((bindings['tabs'] as List?) ?? const []).cast<Map>())
      (id: tab['id']! as String, url: tab['url']! as String),
  ];
  final host = await BrowserHost.serve(
    path: p.join(directory, 'browser.sock'),
    tabs: tabs,
    openOrigins: ((bindings['openOrigins'] as List?) ?? const []).cast<String>(),
    provider: BrowserProvider(
      id: providerId,
      open: (url) => request('open', url),
      find: (url) => request('find', url),
      inspect: (tab) => request('inspect', tab),
      close: (tab) async {
        final result = await request('close', tab);
        if (result['id'] != tab || result['status'] != 'absent') throw const MomentsError('Close not confirmed');
      },
    ),
  );
  final supervisor = processIdentity(pid);
  savePrivateState(p.join(directory, 'host.json'), {
    'version': 1,
    'supervisor': supervisor == null ? null : identityJson(supervisor),
    'socket': host.path,
  });
  final stopped = _stopped();
  print(
    jsonEncode({
      'status': 'ready',
      'socket': host.path,
      'provider': providerId,
      'boundTabs': tabs.map((t) => t.id).toList(),
    }),
  );
  await stopped;
  await host.close();
  return 0;
}

Future<int> _previewHost(String directory, String port, List<String> origins) async {
  if (!RegExp(r'^\d+$').hasMatch(port) || origins.isEmpty) throw const MomentsError(hostUsage);
  final host = await PreviewHost.serve(directory: directory, port: int.parse(port), origins: origins);
  final stopped = _stopped();
  print(jsonEncode({'status': 'ready', ...host.toJson()}));
  await stopped;
  try {
    await host.close();
    return 0;
  } on Object {
    return 2;
  }
}

Future<int> runHost(List<String> args) async {
  try {
    return await switch (args) {
      ['browser', final directory] => _browserHost(directory),
      ['preview', final directory, final port, ...final origins] => _previewHost(directory, port, origins),
      _ => throw const MomentsError(hostUsage),
    };
  } on Object catch (error) {
    stderr.writeln(error is MomentsError ? error.message : '$error');
    return 2;
  }
}
