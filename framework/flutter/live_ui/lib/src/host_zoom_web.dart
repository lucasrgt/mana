import 'dart:js_interop';

@JS('window')
external _Window get _window;

extension type _Window(JSObject _) implements JSObject {
  external _Window get parent;
  external void addEventListener(String type, JSFunction listener, JSAny options);
  external void postMessage(JSAny? message, String targetOrigin);
}

extension type _Input(JSObject _) implements JSObject {
  external bool get ctrlKey;
  external bool get metaKey;
  external double get deltaY;
  external String get key;
  external void preventDefault();
}

/// A framed app owns its pointer and keys, so the browser would zoom the
/// whole page on Ctrl+wheel; the zoom gestures go to the host page instead.
var _relaying = false;

void relayZoomToHost() {
  if (_relaying) return;
  _relaying = true;
  final window = _window, host = window.parent;
  if (host.strictEquals(window).toDart) return;
  final options = {'passive': false, 'capture': true}.jsify()!;
  window.addEventListener(
    'wheel',
    ((_Input e) {
      if (!e.ctrlKey && !e.metaKey) return;
      e.preventDefault();
      host.postMessage({'studio': 'wheel', 'deltaY': e.deltaY}.jsify(), '*');
    }).toJS,
    options,
  );
  window.addEventListener(
    'keydown',
    ((_Input e) {
      if ((!e.ctrlKey && !e.metaKey) || !['+', '=', '-', '0'].contains(e.key)) return;
      e.preventDefault();
      host.postMessage({'studio': 'zoomKey', 'key': e.key}.jsify(), '*');
    }).toJS,
    options,
  );
}
