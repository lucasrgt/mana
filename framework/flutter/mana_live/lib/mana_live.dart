/// Client half of `Mana.Entity`: a record's changes, announced on
/// `entity:<type>:<id>` and `entity:<type>:for:<user>`, reach the screen as a
/// prompt to read again through the API. The announcement carries only the
/// id, so authorization stays with the API read.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:mana_primitives/mana_primitives.dart';
import 'package:phoenix_socket/phoenix_socket.dart';

/// The topics `Mana.Entity` announces on.
abstract final class EntityTopics {
  static String record(String type, String id) => 'entity:$type:$id';

  static String audience(String type, String userId) =>
      'entity:$type:for:$userId';

  /// Every record of [type], for its declared watchers.
  static String all(String type) => 'entity:$type:all';

  /// Stands for "anything may have changed": the socket came back after a
  /// drop, so a screen reads again instead of polling.
  static const missed = '*';
}

/// Where announcements come from; a test passes a fake.
abstract interface class EntityChanges {
  /// The ids changed on [topic], until the subscription is cancelled;
  /// [EntityTopics.missed] after a reconnection, when announcements may have
  /// been lost while it was down.
  Stream<String> watch(String topic);
}

/// Announcements over the API's Phoenix socket, authenticated with [token]
/// on every (re)connection. One socket, one channel per watched topic.
final class PhoenixEntityChanges implements EntityChanges {
  PhoenixEntityChanges({required this.endpoint, required this.token});

  /// The socket of the API at [baseUrl] (`/socket/websocket`, ws or wss).
  factory PhoenixEntityChanges.api(
    String baseUrl, {
    required Future<String?> Function() token,
  }) {
    final base = Uri.parse(baseUrl);
    return PhoenixEntityChanges(
      endpoint: base
          .replace(
            scheme: base.scheme == 'https' ? 'wss' : 'ws',
            path: '/socket/websocket',
          )
          .toString(),
      token: token,
    );
  }

  /// The socket URL, e.g. `wss://api.example.com/socket/websocket`.
  final String endpoint;
  final Future<String?> Function() token;
  PhoenixSocket? _socket;

  Future<PhoenixSocket> _connected() async {
    final socket = _socket ??= PhoenixSocket(
      endpoint,
      socketOptions: PhoenixSocketOptions(
        dynamicParams: () async => {'token': await token() ?? ''},
      ),
    );
    if (!socket.isConnected) await socket.connect();
    return socket;
  }

  final _shared = <String, Stream<String>>{};

  /// One channel per topic however many widgets watch it: joined with the
  /// first listener, left with the last.
  @override
  Stream<String> watch(String topic) => _shared[topic] ??= _channel(topic);

  Stream<String> _channel(String topic) {
    late final StreamController<String> out;
    PhoenixChannel? channel;
    StreamSubscription<Message>? messages;
    final drops = <StreamSubscription<Object?>>[];
    out = StreamController<String>.broadcast(
      onListen: () async {
        try {
          final socket = await _connected();
          var dropped = false;
          drops
            ..add(socket.closeStream.listen((_) => dropped = true))
            ..add(socket.errorStream.listen((_) => dropped = true))
            ..add(
              socket.openStream.listen((_) {
                if (!dropped) return;
                dropped = false;
                out.add(EntityTopics.missed);
              }),
            );
          channel = socket.addChannel(topic: topic);
          messages = channel!.messages.listen((message) {
            final id = message.payload?['id'];
            if (message.event.value == 'changed' && id is String) out.add(id);
          });
          final reply = await channel!.join().future;
          if (!reply.isOk) {
            out.addError(
              StateError('entity channel refused: ${reply.response}'),
            );
          }
        } on Object catch (error) {
          out.addError(error);
        }
      },
      onCancel: () async {
        // A listener may come back while these cancels are awaited, and its
        // join adds to the same lists: take what is here before waiting.
        final leaving = [...drops];
        drops.clear();
        final left = messages;
        messages = null;
        final joined = channel;
        channel = null;
        for (final drop in leaving) {
          await drop.cancel();
        }
        await left?.cancel();
        joined?.leave();
      },
    );
    return out.stream;
  }

  void dispose() => _socket?.dispose();
}

/// Runs [reload] after changes on [changes], at most once per [settle]
/// window, so a burst of announcements causes one read.
final class LiveReload {
  LiveReload(
    Stream<Object?> changes,
    this.reload, {
    this.settle = const Duration(milliseconds: 250),
  }) {
    _subscription = changes.listen((_) => _schedule(), onError: (Object _) {});
  }

  final Future<void> Function() reload;
  final Duration settle;
  late final StreamSubscription<Object?> _subscription;
  Timer? _timer;

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(settle, () => unawaited(reload()));
  }

  @visibleForTesting
  bool get pending => _timer?.isActive ?? false;

  Future<void> dispose() async {
    _timer?.cancel();
    await _subscription.cancel();
  }
}

/// Where the widgets under it hear `Mana.Entity` announcements: put one
/// near the app's root, over the signed-in session's socket. [me] is the
/// signed-in user's id, so a widget follows "my" records without being told
/// who that is.
final class ManaLiveScope extends InheritedWidget {
  const ManaLiveScope({
    required this.changes,
    required super.child,
    this.me,
    super.key,
  });

  final EntityChanges changes;
  final ValueListenable<String?>? me;

  static ManaLiveScope? _of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ManaLiveScope>();

  static EntityChanges? maybeOf(BuildContext context) => _of(context)?.changes;

  @override
  bool updateShouldNotify(ManaLiveScope oldWidget) =>
      !identical(changes, oldWidget.changes) || !identical(me, oldWidget.me);
}

/// A part of the screen that follows records live: while it is mounted it
/// listens to [topics] through the nearest [ManaLiveScope] and runs
/// [onChange] (debounced by [settle]) when one of them changes; it stops
/// when it leaves the tree and follows new topics when they change. No
/// subscription code in view models — the widget that shows the records
/// says it follows them.
///
///     LiveEntity.view(BookingViews.reservationCard, onChange: viewModel.load, child: list)
final class LiveEntity extends StatefulWidget {
  const LiveEntity({
    required this.onChange,
    required this.child,
    this.topics = const [],
    this.mine = const [],
    this.settle = const Duration(milliseconds: 250),
    super.key,
  });

  /// Follows the records of a [ManaView] declared `live: true`: one record
  /// ([id]), every record of an audience member ([audience]), or, with
  /// neither, the signed-in user's records ([ManaLiveScope.me]).
  factory LiveEntity.view(
    ManaView view, {
    required Future<void> Function() onChange,
    required Widget child,
    String? id,
    String? audience,
    Duration settle = const Duration(milliseconds: 250),
    Key? key,
  }) {
    assert(view.live, '$view is not declared live: true');
    return LiveEntity(
      key: key,
      settle: settle,
      onChange: onChange,
      topics: [
        if (id != null) EntityTopics.record(view.resource, id),
        if (audience != null) EntityTopics.audience(view.resource, audience),
      ],
      mine: [if (id == null && audience == null) view.resource],
      child: child,
    );
  }

  /// Follows the records of a live resource (`XEntity.entity`): one record
  /// ([id]), every record of an audience member ([audience]), every record
  /// of the type ([all], for its declared watchers), or, with none, the
  /// signed-in user's records ([ManaLiveScope.me]).
  factory LiveEntity.of(
    ManaEntity entity, {
    required Future<void> Function() onChange,
    required Widget child,
    String? id,
    String? audience,
    bool all = false,
    Duration settle = const Duration(milliseconds: 250),
    Key? key,
  }) {
    assert(
      id != null || audience != null || all || entity.audience.isNotEmpty,
      '${entity.resource} declares no audience; follow a record id',
    );
    assert(!all || entity.watchable, '${entity.resource} declares no watchers');
    return LiveEntity(
      key: key,
      settle: settle,
      onChange: onChange,
      topics: [
        if (id != null) EntityTopics.record(entity.topic, id),
        if (audience != null) EntityTopics.audience(entity.topic, audience),
        if (all) EntityTopics.all(entity.topic),
      ],
      mine: [if (id == null && audience == null && !all) entity.topic],
      child: child,
    );
  }

  final List<String> topics;

  /// Resource types whose records the signed-in user is audience of.
  final List<String> mine;
  final Future<void> Function() onChange;
  final Duration settle;
  final Widget child;

  @override
  State<LiveEntity> createState() => _LiveEntityState();
}

final class _LiveEntityState extends State<LiveEntity> {
  LiveReload? _reload;
  EntityChanges? _source;
  ValueListenable<String?>? _me;
  List<String> _topics = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final me = ManaLiveScope._of(context)?.me;
    if (!identical(me, _me)) {
      _me?.removeListener(_follow);
      _me = me?..addListener(_follow);
    }
    _follow();
  }

  @override
  void didUpdateWidget(LiveEntity oldWidget) {
    super.didUpdateWidget(oldWidget);
    _follow();
  }

  void _follow() {
    final source = ManaLiveScope.maybeOf(context);
    final me = _me?.value;
    final topics = [
      ...widget.topics,
      if (me != null)
        for (final type in widget.mine) EntityTopics.audience(type, me),
    ];
    if (identical(source, _source) && listEquals(topics, _topics)) {
      return;
    }
    unawaited(_reload?.dispose());
    _reload = null;
    _source = source;
    _topics = topics;
    if (source == null || _topics.isEmpty) return;
    final merged = StreamGroupLite.merge([
      for (final t in _topics) source.watch(t),
    ]);
    _reload = LiveReload(
      merged,
      () => widget.onChange(),
      settle: widget.settle,
    );
  }

  @override
  void dispose() {
    _me?.removeListener(_follow);
    unawaited(_reload?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Merges streams into one that ends its subscriptions when cancelled.
abstract final class StreamGroupLite {
  static Stream<T> merge<T>(List<Stream<T>> streams) {
    late final StreamController<T> out;
    final subscriptions = <StreamSubscription<T>>[];
    out = StreamController<T>(
      onListen: () {
        for (final s in streams) {
          subscriptions.add(s.listen(out.add, onError: out.addError));
        }
      },
      onCancel: () => Future.wait([for (final s in subscriptions) s.cancel()]),
    );
    return out.stream;
  }
}
