import 'package:flutter/foundation.dart';

import 'entry.dart';

/// Stateful headless controller for an app's notification inbox.
final class ManaInboxController extends ChangeNotifier {
  ManaInboxController({List<ManaInboxEntry> initial = const []})
    : _entries = List.of(initial);

  final List<ManaInboxEntry> _entries;

  List<ManaInboxEntry> get entries => List.unmodifiable(_entries);

  List<ManaInboxEntry> get unreadEntries =>
      List.unmodifiable(_entries.where((e) => e.unread));

  int get unreadCount => _entries.where((e) => e.unread).length;

  bool get hasUnread => unreadCount > 0;

  /// Prepends a new entry (deduplicating by [ManaInboxEntry.id]).
  void push(ManaInboxEntry entry) {
    _entries.removeWhere((e) => e.id == entry.id);
    _entries.insert(0, entry);
    notifyListeners();
  }

  void replaceAll(List<ManaInboxEntry> entries) {
    _entries
      ..clear()
      ..addAll(entries);
    notifyListeners();
  }

  void markRead(String id) {
    final idx = _entries.indexWhere((e) => e.id == id);
    if (idx < 0 || !_entries[idx].unread) return;
    _entries[idx] = _entries[idx].copyWith(unread: false);
    notifyListeners();
  }

  void markAllRead() {
    var changed = false;
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].unread) {
        _entries[i] = _entries[i].copyWith(unread: false);
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  void remove(String id) {
    final before = _entries.length;
    _entries.removeWhere((e) => e.id == id);
    if (_entries.length != before) notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }
}
