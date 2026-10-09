import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'errors.dart';

final _answered = Expando<bool>('answered');
final _gone = Expando<bool>('gone');

/// Watches for the client going away, so a long poll can be dropped.
void trackClose(HttpResponse response, void Function() onClose) {
  unawaited(
    response.done.then(
      (_) {
        _gone[response] = true;
        onClose();
      },
      onError: (_) {
        _gone[response] = true;
        onClose();
      },
    ),
  );
}

bool answered(HttpResponse response) => _answered[response] == true || _gone[response] == true;

/// Writes one JSON reply at most; later replies to the same response are
/// ignored, as the JS runner's `res.writableEnded` guard did.
void reply(HttpResponse response, int code, [Object? data]) {
  if (answered(response)) return;
  _answered[response] = true;
  try {
    response
      ..statusCode = code
      ..headers.contentType = ContentType.json
      ..headers.set('Cache-Control', 'no-store');
    if (code != 204) response.write(jsonEncode(data));
    unawaited(response.close().catchError((_) {}));
  } on Object {
    // The client disconnected first.
  }
}

typedef Reply = void Function(HttpResponse response, int code, [Object? data]);
typedef Body = Future<Map<String, Object?>> Function();

/// Reads and decodes a JSON object body, refusing more than [limit] bytes.
Future<Map<String, Object?>> readJson(HttpRequest request, {int limit = 16384}) async {
  final bytes = <int>[];
  await for (final chunk in request) {
    bytes.addAll(chunk);
    if (bytes.length > limit) throw const MomentsError('Request exceeds the body limit');
  }
  final value = jsonDecode(utf8.decode(bytes));
  if (value is! Map) throw const MomentsError('Expected a JSON object');
  return value.cast();
}

/// One body read per request, shared by every handler that asks for it.
Body onceBody(HttpRequest request, {int limit = 16384}) {
  Future<Map<String, Object?>>? parsed;
  return () => parsed ??= readJson(request, limit: limit);
}

/// When the bridge first saw a request, so handlers can report time spent
/// before they ran.
final arrivals = Expando<double>('arrival');
