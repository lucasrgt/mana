import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mana_primitives/mana_primitives.dart';

/// The newest change in [entries] that can be taken back now: a done entry
/// whose verb declares an `inverse:` the record [offered] at this moment.
/// Only the newest change is undoable, so nothing older is undone under a
/// later one.
(ManaHistoryEntry, ManaVerb)? undoable(
  List<ManaHistoryEntry> entries,
  List<ManaVerb> verbs,
  Iterable<String>? offered,
) {
  final newest = entries.where((entry) => !entry.failed && entry.verb != null);
  if (newest.isEmpty) return null;
  final entry = newest.first;
  final verb = verbs.where((v) => v.name == entry.verb).firstOrNull;
  final inverse = verbs.where((v) => v.name == verb?.inverse).firstOrNull;
  if (inverse == null || !inverse.offeredBy(offered)) return null;
  return (entry, inverse);
}

/// A record's `Mana.History` as a screen shows it, newest first: [load]
/// reads it (again whenever [changes] fires), [entry] draws each change and
/// receives `undo` for the one [undoable] picks, and [asOf], when given,
/// opens how the record stood right after an entry ("ver como estava").
final class HistoryView extends StatefulWidget {
  const HistoryView({
    required this.load,
    required this.entry,
    this.verbs = const [],
    this.offered,
    this.undo,
    this.asOf,
    this.changes,
    this.limit = 20,
    this.wrap,
    super.key,
  });

  final Future<List<ManaHistoryEntry>> Function() load;
  final Widget Function(
    BuildContext context,
    ManaHistoryEntry entry,
    VoidCallback? undo,
    VoidCallback? asOf,
  )
  entry;

  /// The record's verbs (`XVerbs.all`), to find inverses.
  final List<ManaVerb> verbs;

  /// What the record offers now (its `verbs` attribute).
  final Iterable<String>? offered;

  /// Performs the inverse verb; the history reads again after it.
  final Future<void> Function(ManaVerb inverse)? undo;
  final void Function(ManaHistoryEntry entry)? asOf;
  final Listenable? changes;
  final int limit;

  /// Frames the entries (a titled section); nothing is drawn while empty.
  final Widget Function(BuildContext context, List<Widget> entries)? wrap;

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

final class _HistoryViewState extends State<HistoryView> {
  List<ManaHistoryEntry> _entries = const [];
  bool _undoing = false;

  @override
  void initState() {
    super.initState();
    widget.changes?.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(HistoryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.changes != widget.changes) {
      oldWidget.changes?.removeListener(_reload);
      widget.changes?.addListener(_reload);
    }
  }

  @override
  void dispose() {
    widget.changes?.removeListener(_reload);
    super.dispose();
  }

  void _reload() => unawaited(_read());

  Future<void> _read() async {
    try {
      final entries = await widget.load();
      if (mounted) setState(() => _entries = entries);
    } on Object {
      return;
    }
  }

  Future<void> _undo(ManaVerb inverse) async {
    setState(() => _undoing = true);
    try {
      await widget.undo!(inverse);
      await _read();
    } finally {
      if (mounted) setState(() => _undoing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown = _entries
        .where((entry) => !entry.failed)
        .take(widget.limit)
        .toList();
    if (shown.isEmpty) return const SizedBox.shrink();
    final takeBack = widget.undo == null || _undoing
        ? null
        : undoable(shown, widget.verbs, widget.offered);
    final rows = [
      for (final entry in shown)
        widget.entry(
          context,
          entry,
          takeBack != null && identical(takeBack.$1, entry)
              ? () => unawaited(_undo(takeBack.$2))
              : null,
          widget.asOf == null ? null : () => widget.asOf!(entry),
        ),
    ];
    return widget.wrap?.call(context, rows) ??
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}
