import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';

const _mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
  '.css': 'text/css',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff2': 'font/woff2',
};

String _local(Object? value) {
  final url = Uri.tryParse('${value ?? ''}');
  if (url == null ||
      url.scheme != 'http' ||
      url.host != '127.0.0.1' ||
      !url.hasPort ||
      url.userInfo.isNotEmpty ||
      url.hasQuery ||
      url.hasFragment ||
      (url.path != '/' && url.path.isNotEmpty)) {
    throw const MomentsError('Actor endpoints must be loopback origins');
  }
  return 'http://127.0.0.1:${url.port}';
}

final _surfaceId = RegExp(r'^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$');

Map<String, Object?> _bridge(Map<String, Object?> value) {
  if (!RegExp(r'^[a-f0-9]{48}$').hasMatch('${value['bridgeToken'] ?? ''}')) {
    throw const MomentsError('Invalid actor bridge configuration');
  }
  return {'bridgeUrl': _local(value['bridgeUrl']), 'bridgeToken': value['bridgeToken']};
}

/// Serves an immutable compiled Flutter web artifact, plus the runtime
/// envelope at `/__moments_runtime`. Optional surfaces share one origin/API
/// (and browser storage), but each has its own bridge and runtime claim.
/// Surface ids are selectors, not credentials. No source generation, JS
/// rewriting, proxying or remote requests.
final class WebActor {
  WebActor._(this.url, this._server);
  final String url;
  final HttpServer _server;

  Future<void> close() => _server.close(force: true);

  static Future<WebActor> start({
    required String artifact,
    required int port,
    required String apiUrl,
    String? bridgeUrl,
    String? bridgeToken,
    Map<String, Map<String, Object?>>? surfaces,
    bool immutable = false,
    bool crossOriginIsolated = false,
  }) async {
    final root = Directory(artifact).resolveSymbolicLinksSync();
    if (port < 1 || port > 65535) throw const MomentsError('Invalid actor web configuration');
    final origin = 'http://127.0.0.1:$port';
    final common = {'origin': origin, 'apiUrl': _local(apiUrl)};
    Map<String, Object?>? configuration;
    Map<String, Map<String, Object?>>? bindings;
    if (surfaces == null) {
      configuration = {
        'version': 1,
        ...common,
        ..._bridge({'bridgeUrl': bridgeUrl, 'bridgeToken': bridgeToken}),
      };
    } else {
      if (bridgeUrl != null || bridgeToken != null || surfaces.length < 2 || surfaces.length > 8) {
        throw const MomentsError('Declare 2–8 independent surfaces without a default bridge');
      }
      bindings = {
        for (final MapEntry(key: id, :value) in surfaces.entries)
          id: () {
            if (!_surfaceId.hasMatch(id)) throw const MomentsError('Invalid owned surface identity');
            return {'version': 2, ...common, 'surface': id, ..._bridge(value)};
          }(),
      };
      if (bindings.values.map((v) => v['bridgeUrl']).toSet().length != bindings.length ||
          bindings.values.map((v) => v['bridgeToken']).toSet().length != bindings.length) {
        throw const MomentsError('Each surface requires an independent bridge and credential');
      }
    }
    if (!File(p.join(root, 'index.html')).existsSync() || !File(p.join(root, 'main.dart.js')).existsSync()) {
      throw const MomentsError('Compiled Flutter web artifact required');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    server.autoCompress = false;
    server.listen((request) async {
      final response = request.response;
      Future<void> reject(int code) async {
        response.statusCode = code;
        await response.close();
      }

      response.headers
        ..set('Cache-Control', 'no-store')
        ..set('X-Content-Type-Options', 'nosniff')
        ..set('Cross-Origin-Resource-Policy', 'same-origin');
      // Multi-threaded wasm rendering needs SharedArrayBuffer, which browsers
      // only grant to cross-origin isolated pages.
      if (crossOriginIsolated) {
        response.headers
          ..set('Cross-Origin-Opener-Policy', 'same-origin')
          ..set('Cross-Origin-Embedder-Policy', 'require-corp');
      }
      try {
        if (request.headers.value('host') != '127.0.0.1:$port') {
          await reject(403);
          return;
        }
        if (request.method != 'GET' && request.method != 'HEAD') {
          await reject(405);
          return;
        }
        final url = request.uri;
        if (url.path == '/__moments_runtime') {
          final requestOrigin = request.headers.value('origin');
          final site = request.headers.value('sec-fetch-site');
          if (request.method != 'GET' ||
              (requestOrigin != null && requestOrigin != origin) ||
              (site != null && !const ['same-origin', 'none'].contains(site))) {
            {
              await reject(403);
              return;
            }
          }
          var selected = configuration;
          if (bindings != null) {
            final ids = url.queryParametersAll['momentsActor'] ?? const [];
            if (ids.length != 1 ||
                !bindings.containsKey(ids.single) ||
                url.queryParametersAll.keys.any((k) => k != 'momentsActor')) {
              {
                await reject(404);
                return;
              }
            }
            selected = bindings[ids.single];
          }
          response.headers.contentType = ContentType.json;
          response.write(jsonEncode(selected));
          await response.close();
          return;
        }
        var file = p.normalize(p.join(root, '.${Uri.decodeComponent(url.path)}'));
        if (p.relative(file, from: root).startsWith('..')) {
          await reject(403);
          return;
        }
        if (FileSystemEntity.typeSync(file, followLinks: false) != FileSystemEntityType.file) {
          if (request.headers.value('accept')?.contains('text/html') ?? false) {
            file = p.join(root, 'index.html');
          } else {
            {
              await reject(404);
              return;
            }
          }
        }
        if (p.relative(File(file).resolveSymbolicLinksSync(), from: root).startsWith('..') ||
            FileSystemEntity.isLinkSync(file)) {
          {
            await reject(403);
            return;
          }
        }
        // A content-keyed artifact never changes under its URL; letting the
        // browser keep it skips refetching and recompiling the app on every
        // runtime start.
        if (immutable && !file.endsWith('index.html')) {
          response.headers.set('Cache-Control', 'private, max-age=31536000, immutable');
        }
        response.headers
          ..set('Content-Type', _mime[p.extension(file)] ?? 'application/octet-stream')
          ..contentLength = File(file).lengthSync();
        if (request.method == 'HEAD') {
          await response.close();
          return;
        }
        await response.addStream(File(file).openRead());
        await response.close();
      } on Object {
        try {
          await reject(400);
        } on Object {
          // The client went away.
        }
      }
    });
    return WebActor._(origin, server);
  }
}

/// Serves one actor's compiled artifact from a private configuration until
/// SIGINT or SIGTERM.
Future<int> runWebActorWorker(String file) async {
  if (FileSystemEntity.typeSync(file, followLinks: false) != FileSystemEntityType.file ||
      File(file).lengthSync() > 16384 ||
      FileStat.statSync(file).mode & 0x3f != 0) {
    throw const MomentsError('Private web actor configuration required');
  }
  final config = (jsonDecode(File(file).readAsStringSync()) as Map).cast<String, Object?>();
  final server = await WebActor.start(
    artifact: config['artifact']! as String,
    port: config['port']! as int,
    apiUrl: config['apiUrl']! as String,
    bridgeUrl: config['bridgeUrl'] as String?,
    bridgeToken: config['bridgeToken'] as String?,
    surfaces: (config['surfaces'] as Map?)?.map(
      (key, value) => MapEntry(key as String, (value as Map).cast<String, Object?>()),
    ),
    immutable: config['immutable'] == true,
    crossOriginIsolated: config['crossOriginIsolated'] == true,
  );
  final stopped = Future.any([ProcessSignal.sigint.watch().first, ProcessSignal.sigterm.watch().first]);
  stdout.writeln('Compiled Flutter is being served at ${server.url}');
  await stopped;
  await server.close();
  return 0;
}
