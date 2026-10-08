import 'package:flutter_test/flutter_test.dart';
import 'package:mana_command/mana_command.dart';

const _gallery = ManaAttachment(
  resource: 'property',
  attribute: 'gallery_ids',
  many: true,
  max: 3,
  kinds: [
    AttachmentKind(name: 'photo', accept: ['image/png'], maxBytes: 10),
  ],
);

void main() {
  test(
    'files go out with progress, a failure waits for retry, and max is kept',
    () async {
      var fail = true;
      final ready = <String>[];
      final uploads = AttachmentUploads<String>(
        attachment: _gallery,
        held: 1,
        onReady: (_, id) => ready.add(id),
        upload: (file, onProgress) async {
          onProgress(0.5);
          if (file == 'b' && fail) throw StateError('dropped');
          return 'id-$file';
        },
      );

      expect(uploads.room, 2);
      await uploads.add(['a', 'b', 'c']);
      expect(ready, ['id-a']);
      expect(uploads.pending.single.failed, isTrue);
      expect(uploads.room, 1);

      fail = false;
      await uploads.retry(uploads.pending.single);
      expect(ready, ['id-a', 'id-b']);
      expect(uploads.pending, isEmpty);
      expect(uploads.room, 0);
    },
  );

  test('a single-file attribute takes one', () async {
    final uploads = AttachmentUploads<String>(
      attachment: const ManaAttachment(
        resource: 'host',
        attribute: 'profile_photo_id',
        kinds: [],
      ),
      upload: (file, _) async => file,
    );
    expect(uploads.room, 1);
    await uploads.add(['first']);
    expect(uploads.room, 1);
  });
}
