import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mana_primitives/mana_primitives.dart';

/// What a person can turn off, from the notices the API declares: each
/// category with the channels its notices go out on beyond the inbox, in
/// the order they first appear. The inbox itself is never a choice.
List<(String category, List<String> channels)> notificationChoices(
  Iterable<ManaNotification> notices,
) {
  final channels = <String, Set<String>>{};
  for (final notice in notices) {
    final outbound = notice.channels.where((channel) => channel != 'inbox');
    if (outbound.isEmpty) continue;
    (channels[notice.category] ??= <String>{}).addAll(outbound);
  }
  const order = ['push', 'email', 'sms'];
  return [
    for (final MapEntry(key: category, value: set) in channels.entries)
      (
        category,
        [
          for (final channel in order)
            if (set.contains(channel)) channel,
          for (final channel in set)
            if (!order.contains(channel)) channel,
        ],
      ),
  ];
}

/// The category × channel switches of [choices]: [isOn] answers each one,
/// [onChanged] stores a change, [category] draws a category with its
/// [channel] cells.
final class NotificationPreferences extends StatelessWidget {
  const NotificationPreferences({
    required this.choices,
    required this.isOn,
    required this.onChanged,
    required this.category,
    required this.channel,
    super.key,
  });

  final List<(String, List<String>)> choices;
  final bool Function(String category, String channel) isOn;
  final ValueChanged<(String category, String channel, bool on)>? onChanged;
  final Widget Function(
    BuildContext context,
    String category,
    List<Widget> channels,
  )
  category;
  final Widget Function(
    BuildContext context,
    String category,
    String channel,
    bool on,
    ValueChanged<bool>? onChanged,
  )
  channel;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (name, channels) in choices)
        category(context, name, [
          for (final each in channels)
            channel(
              context,
              name,
              each,
              isOn(name, each),
              onChanged == null ? null : (on) => onChanged!((name, each, on)),
            ),
        ]),
    ],
  );
}

/// A person's notices as an inbox keeps them: the list [load] reads, the
/// category filter, the unread count, and reading one marked at once and
/// put back if the server refuses. [category] and [link] come from the
/// notice's declaration (`ManaNotices.all`) by its template.
final class InboxController<T> extends ChangeNotifier {
  InboxController({
    required this.load,
    required this.id,
    required this.unread,
    required this.template,
    required this.markRead,
    this.notices = const [],
  });

  final Future<List<T>> Function() load;
  final String Function(T notice) id;
  final bool Function(T notice) unread;
  final String Function(T notice) template;
  final Future<void> Function(String id) markRead;
  final List<ManaNotification> notices;

  List<T>? _items;
  Object? error;
  String? _filter;
  final _optimistic = <String>{};

  List<T>? get items => _items;
  String? get filter => _filter;

  /// The declaration of [notice], if its template is declared.
  ManaNotification? declared(T notice) =>
      ManaNotification.of(notices, template(notice));

  String? category(T notice) => declared(notice)?.category;

  List<T> get visible => [
    for (final notice in _items ?? <T>[])
      if (_filter == null || category(notice) == _filter) notice,
  ];

  bool isUnread(T notice) =>
      unread(notice) && !_optimistic.contains(id(notice));

  int get unreadCount => (_items ?? <T>[]).where(isUnread).length;

  /// Reads the list again; [quietly] keeps the current one on screen.
  Future<void> refresh({bool quietly = false}) async {
    if (!quietly) {
      _items = null;
      error = null;
      notifyListeners();
    }
    try {
      final fresh = await load();
      _optimistic.removeWhere(
        (read) => fresh.any((n) => id(n) == read && !unread(n)),
      );
      _items = fresh;
      error = null;
    } on Object catch (failure) {
      if (!quietly) error = failure;
    }
    notifyListeners();
  }

  void filterBy(String? category) {
    _filter = category;
    notifyListeners();
  }

  /// Marks [notice] read now; false (and unread again) when the server refuses.
  Future<bool> read(T notice) async {
    if (!isUnread(notice)) return true;
    final key = id(notice);
    _optimistic.add(key);
    notifyListeners();
    try {
      await markRead(key);
      return true;
    } on Object {
      _optimistic.remove(key);
      notifyListeners();
      return false;
    }
  }

  /// Where [notice] leads, from its declaration's `opens` and its payload.
  String? link(T notice, Map payload) => declared(notice)?.link(payload);

  void refreshQuietly() => unawaited(refresh(quietly: true));
}
