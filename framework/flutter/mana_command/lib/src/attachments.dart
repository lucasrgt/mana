import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:mana_primitives/mana_primitives.dart';

/// One file on its way to an attachment: its progress (0–1), the id once
/// stored, or the failure it stopped on and can be retried from.
final class PendingUpload<P> {
  PendingUpload._(this.file);

  final P file;
  double progress = 0;
  String? id;
  Object? failure;

  bool get done => id != null;
  bool get failed => failure != null;
  bool get sending => !done && !failed;
}

/// The uploads of one `Mana.Attachments` attribute as a field keeps them:
/// each picked file goes out with its progress, one that fails waits for
/// [retry] instead of being lost, and no more files are taken than the
/// attribute's `max` (one when it holds a single file). [onReady] receives
/// each file with its stored id, in the order they were picked.
final class AttachmentUploads<P> extends ChangeNotifier {
  AttachmentUploads({
    required this.attachment,
    required this.upload,
    this.onReady,
    this.held = 0,
  });

  final ManaAttachment attachment;

  /// Sends a file, reporting progress, and answers its id.
  final Future<String> Function(
    P file,
    void Function(double progress) onProgress,
  )
  upload;
  final void Function(P file, String id)? onReady;

  /// Files the attribute already holds, counted against its `max`.
  int held;

  final List<PendingUpload<P>> _pending = [];

  List<PendingUpload<P>> get pending => List.unmodifiable(_pending);

  bool get sending => _pending.any((upload) => upload.sending);

  int get _limit => attachment.many ? (attachment.max ?? 1 << 30) : 1;

  /// How many more files the attribute takes now; a single-file attribute
  /// always takes one more, which replaces the one it holds.
  int get room =>
      (_limit -
              (attachment.many ? held : 0) -
              _pending.where((u) => !u.failed).length)
          .clamp(0, _limit);

  /// Sends [files] (only as many as there is [room] for), one after another.
  Future<void> add(Iterable<P> files) async {
    final taken = files.take(room).map(PendingUpload<P>._).toList();
    _pending.addAll(taken);
    notifyListeners();
    for (final upload in taken) {
      await _send(upload);
    }
  }

  Future<void> retry(PendingUpload<P> upload) async {
    if (!upload.failed) return;
    upload
      ..failure = null
      ..progress = 0;
    notifyListeners();
    await _send(upload);
  }

  /// Forgets a pending or failed upload; a stored one is the field's to remove.
  void discard(PendingUpload<P> upload) {
    _pending.remove(upload);
    notifyListeners();
  }

  Future<void> _send(PendingUpload<P> upload) async {
    try {
      final id = await this.upload(upload.file, (progress) {
        upload.progress = progress;
        notifyListeners();
      });
      upload
        ..id = id
        ..progress = 1;
      _pending.remove(upload);
      held++;
      onReady?.call(upload.file, id);
    } on Object catch (failure) {
      upload.failure = failure;
    }
    notifyListeners();
  }
}

/// A field for one attachment attribute: [builder] draws it from the
/// [uploads] in flight and calls `add` with what it picked.
final class AttachmentField<P> extends StatelessWidget {
  const AttachmentField({
    required this.uploads,
    required this.builder,
    super.key,
  });

  final AttachmentUploads<P> uploads;
  final Widget Function(BuildContext context, AttachmentUploads<P> uploads)
  builder;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: uploads,
    builder: (context, _) => builder(context, uploads),
  );
}
