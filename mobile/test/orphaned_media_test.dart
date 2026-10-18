/// A photo attached with no internet must still reach the backend.
///
/// Media bytes never cross the mesh — only descriptors do, because one clip
/// would sit in front of every life-critical report behind it. So an SOS
/// sent from an offline phone arrives at the backend describing a photo
/// that only the originating handset holds.
///
/// Three things conspired to make that photo unreachable forever:
///
///  1. The local `mediaJson` column was never written, so once the packet
///     was gone the handset had no record a photo existed.
///  2. Uploads were resolved from the current sync batch only, and a report
///     acknowledged over the mesh is never in a batch again.
///  3. The backend asked for the missing bytes with REQUEST_MEDIA, and the
///     app did not read `commands` at all.
///
/// The visible symptom was "image not retrievable" on the command centre
/// for a photo that had uploaded nowhere and never would.
library;

import 'package:avertis/services/media_uploader.dart';
import 'package:flutter_test/flutter_test.dart';

typedef StoredReport = ({String reportId, List<dynamic> media});

StoredReport stored(String reportId, {String? path, String id = 'med-1'}) => (
  reportId: reportId,
  media: [
    {
      'media_id': id,
      'kind': 'IMAGE',
      'bytes': 135122,
      if (path != null) 'local_path': path,
    },
  ],
);

void main() {
  late MediaUploader uploader;

  setUp(() => uploader = MediaUploader(backend: _NullBackend()));

  test('a photo the backend asks for is found by id — the bug', () {
    final pending = uploader.pendingByMediaId(
      [stored('rpt-1', path: '/data/photo.jpg')],
      {'med-1'},
    );

    expect(pending, hasLength(1));
    expect(pending.single.mediaId, 'med-1');
    expect(pending.single.path, '/data/photo.jpg');
    expect(pending.single.reportId, 'rpt-1');
  });

  test('the report need not be in any sync batch', () {
    // The whole point: this report was acknowledged over the mesh weeks
    // ago and will never be offered to the backend again.
    final pending = uploader.pendingByMediaId(
      [stored('acknowledged-long-ago', path: '/data/photo.jpg')],
      {'med-1'},
    );

    expect(pending, hasLength(1));
  });

  test('media the backend did not ask for is left alone', () {
    final pending = uploader.pendingByMediaId(
      [stored('rpt-1', path: '/data/photo.jpg')],
      {'med-something-else'},
    );

    expect(pending, isEmpty, reason: 'a window is short; send only what '
        'the backend says it is missing');
  });

  test('a descriptor from another handset is skipped', () {
    // We relayed this report. We never had the file, and `local_path` is
    // stripped on the wire, so there is nothing here to send.
    final pending = uploader.pendingByMediaId(
      [stored('rpt-relayed')],
      {'med-1'},
    );

    expect(pending, isEmpty);
  });

  test('nothing is uploaded twice', () async {
    final first = uploader.pendingByMediaId(
      [stored('rpt-1', path: '/data/photo.jpg')],
      {'med-1'},
    );
    await uploader.upload(first, budgetBytes: 1 << 20);

    final second = uploader.pendingByMediaId(
      [stored('rpt-1', path: '/data/photo.jpg')],
      {'med-1'},
    );
    expect(second, isEmpty, reason: 'the backend may keep asking until its '
        'own record catches up; we must not keep resending');
  });

  test('several reports are searched, not just the first', () {
    final pending = uploader.pendingByMediaId(
      [
        stored('rpt-1', path: '/data/a.jpg', id: 'med-a'),
        stored('rpt-2', path: '/data/b.jpg', id: 'med-b'),
        stored('rpt-3', path: '/data/c.jpg', id: 'med-c'),
      ],
      {'med-c'},
    );

    expect(pending.single.path, '/data/c.jpg');
  });

  test('a malformed descriptor does not take the sync down with it', () {
    final pending = uploader.pendingByMediaId(
      [
        (reportId: 'rpt-1', media: ['not a map', 42, null]),
        stored('rpt-2', path: '/data/b.jpg', id: 'med-b'),
      ],
      {'med-b'},
    );

    expect(pending.single.mediaId, 'med-b');
  });
}

/// Records the attempt and claims success; the file is never opened.
class _NullBackend implements MediaBackend {
  @override
  Future<String?> uploadMedia({
    required String mediaId,
    required String reportId,
    required String sha256Hex,
    required dynamic file,
  }) async => 'gs://bucket/$mediaId';
}
