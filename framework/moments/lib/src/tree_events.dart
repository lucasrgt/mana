import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One non-recursive watch per directory: on Linux, `Directory.watch` with
/// `recursive: true` reports only the top level (Dart 3.13), so nested
/// libraries would go unseen. Events only signal that something may have
/// changed; callers still decide from content.
final class TreeEvents {
  TreeEvents(Iterable<String> roots, this._onChange, {Iterable<String> shallow = const []}) {
    for (final root in roots) {
      _addTree(p.normalize(root));
    }
    for (final directory in shallow) {
      _add(p.normalize(directory), descend: false);
    }
  }

  final void Function() _onChange;
  final _watches = <String, StreamSubscription<FileSystemEvent>>{};
  var _failed = false, _closed = false;

  /// False once a watch could not be set up or reported an error; callers
  /// must then stop trusting the absence of events.
  bool get reliable => !_failed && !_closed;

  void _addTree(String directory) => _add(directory, descend: true);

  void _add(String directory, {required bool descend}) {
    if (_closed || _watches.containsKey(directory) || !FileSystemEntity.isDirectorySync(directory)) return;
    try {
      _watches[directory] = Directory(directory).watch().listen((event) {
        if (descend && event is FileSystemCreateEvent && event.isDirectory) _addTree(p.normalize(event.path));
        if (descend && event is FileSystemMoveEvent && event.isDirectory && event.destination != null) {
          _addTree(p.normalize(event.destination!));
        }
        _onChange();
      }, onError: (Object _) => _fail());
      if (!descend) return;
      for (final entry in Directory(directory).listSync(followLinks: false)) {
        if (entry is Directory) _addTree(p.normalize(entry.path));
      }
    } on Object {
      _fail();
    }
  }

  void _fail() {
    _failed = true;
    _onChange();
  }

  Future<void> close() async {
    _closed = true;
    final watches = [..._watches.values];
    _watches.clear();
    for (final watch in watches) {
      await watch.cancel();
    }
  }
}
