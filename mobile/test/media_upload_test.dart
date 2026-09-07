/// Media upload spends what the reports left of a connectivity window.
///
/// The invariant under test throughout: a photo is evidence, a report is a
/// person. Nothing about media may ever cost a report its delivery.
library;

import 'dart:io';

import 'package:avertis/services/media_uploader.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMediaBackend implements MediaBackend {
  FakeMediaBackend({this.failFor = const {}, this.throwFor = const {}});

  final Set<String> failFor;
  final Set<String> throwFor;
  final List<String> uploadedIds = [];
  final Map<String, String> receivedDigests = {};

  @override
  Future<String?> uploadMedia({
    required String mediaId,
    required String reportId,
    required String sha256Hex,
    required File file,
  }) async {
    if (throwFor.contains(mediaId)) throw const SocketException('down');
    receivedDigests[mediaId] = sha256Hex;
    if (failFor.contains(mediaId)) return null;
    uploadedIds.add(mediaId);
    return 'gs://avertis/$mediaId';
  }
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('avertis_media'));
  tearDown(() => tmp.deleteSync(recursive: true));

  File makeFile(String name, int bytes) {
    final f = File('${tmp.path}/$name')
      ..writeAsBytesSync(List.filled(bytes, 65));
    return f;
  }

  PendingMedia pending(String id, File file, {String report = 'rpt-1'}) =>
      PendingMedia(
        mediaId: id,
        reportId: report,
        path: file.path,
        bytes: file.lengthSync(),
        kind: 'IMAGE',
      );

  group('selecting what to upload', () {
    test('only media from accepted reports is uploaded', () {
      final uploader = MediaUploader(backend: FakeMediaBackend());
      final selected = uploader.pendingFor([
        {
          'report_id': 'rpt-accepted',
          'media': [
            {'media_id': 'med-1', 'local_path': '/tmp/a.jpg', 'bytes': 10}
          ],
        },
        {
          'report_id': 'rpt-rejected',
          'media': [
            {'media_id': 'med-2', 'local_path': '/tmp/b.jpg', 'bytes': 10}
          ],
        },
      ], {
        'rpt-accepted'
      });

      // Bytes are useless to the backend until it has an incident to attach
      // them to.
      expect(selected.map((m) => m.mediaId), ['med-1']);
    });

    test('a relayed report\'s media is skipped — we do not hold the bytes',
        () {
      final uploader = MediaUploader(backend: FakeMediaBackend());
      final selected = uploader.pendingFor([
        {
          'report_id': 'rpt-1',
          // No local_path: another node originated this and holds the file.
          'media': [
            {'media_id': 'med-remote', 'bytes': 900}
          ],
        },
      ], {
        'rpt-1'
      });
      expect(selected, isEmpty);
    });

    test('already-uploaded media is not offered again', () async {
      final backend = FakeMediaBackend();
      final uploader = MediaUploader(backend: backend);
      final file = makeFile('a.jpg', 100);

      await uploader.upload([pending('med-1', file)], budgetBytes: 10000);

      final again = uploader.pendingFor([
        {
          'report_id': 'rpt-1',
          'media': [
            {'media_id': 'med-1', 'local_path': file.path, 'bytes': 100}
          ],
        },
      ], {
        'rpt-1'
      });
      expect(again, isEmpty);
    });
  });

  group('spending the window', () {
    test('uploads what fits and defers the rest', () async {
      final backend = FakeMediaBackend();
      final uploader = MediaUploader(backend: backend);
      final small = makeFile('small.jpg', 100);
      final huge = makeFile('huge.jpg', 100000);

      final result = await uploader.upload(
        [pending('med-small', small), pending('med-huge', huge)],
        budgetBytes: 1000,
      );

      expect(result.uploaded, 1);
      expect(result.deferred, 1);
      expect(backend.uploadedIds, ['med-small']);
    });

    test('smallest first, to deliver the most evidence per window', () async {
      final backend = FakeMediaBackend();
      final uploader = MediaUploader(backend: backend);
      final big = makeFile('big.jpg', 800);
      final mid = makeFile('mid.jpg', 400);
      final small = makeFile('small.jpg', 100);

      await uploader.upload(
        [pending('med-big', big), pending('med-mid', mid),
         pending('med-small', small)],
        budgetBytes: 1000,
      );

      expect(backend.uploadedIds, ['med-small', 'med-mid']);
    });

    test('a file too large for the whole window is never started', () async {
      final backend = FakeMediaBackend();
      final uploader = MediaUploader(backend: backend);
      final huge = makeFile('huge.jpg', 50000);

      final result =
          await uploader.upload([pending('med-1', huge)], budgetBytes: 1000);

      // Starting it would spend the window and deliver nothing.
      expect(result.uploaded, 0);
      expect(result.deferred, 1);
      expect(backend.uploadedIds, isEmpty);
    });

    test('a zero budget uploads nothing and defers everything', () async {
      final backend = FakeMediaBackend();
      final uploader = MediaUploader(backend: backend);
      final file = makeFile('a.jpg', 10);

      final result =
          await uploader.upload([pending('med-1', file)], budgetBytes: 0);

      expect(result.uploaded, 0);
      expect(result.deferred, 1);
      expect(backend.uploadedIds, isEmpty);
    });

    test('an integrity digest is sent with every upload', () async {
      final backend = FakeMediaBackend();
      final uploader = MediaUploader(backend: backend);
      final file = makeFile('a.jpg', 64);

      await uploader.upload([pending('med-1', file)], budgetBytes: 10000);

      // sha256 of 64 'A' bytes.
      expect(backend.receivedDigests['med-1'], hasLength(64));
      expect(backend.receivedDigests['med-1'],
          matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('failure never costs a report', () {
    test('a transient failure is retried on the next window', () async {
      final backend = FakeMediaBackend(failFor: {'med-1'});
      final uploader = MediaUploader(backend: backend);
      final file = makeFile('a.jpg', 100);

      final first =
          await uploader.upload([pending('med-1', file)], budgetBytes: 10000);
      expect(first.failed, 1);
      expect(first.uploaded, 0);

      // Not marked done, so it is still offered.
      expect(uploader.uploadedMediaIds, isNot(contains('med-1')));
    });

    test('a thrown backend error is caught, not propagated', () async {
      final backend = FakeMediaBackend(throwFor: {'med-1'});
      final uploader = MediaUploader(backend: backend);
      final file = makeFile('a.jpg', 100);

      // A media failure must never surface as a sync failure.
      final result =
          await uploader.upload([pending('med-1', file)], budgetBytes: 10000);
      expect(result.failed, 1);
      expect(result.uploaded, 0);
    });

    test('a vanished file is abandoned, not retried forever', () async {
      final backend = FakeMediaBackend();
      final uploader = MediaUploader(backend: backend);

      final result = await uploader.upload(
        [
          PendingMedia(
            mediaId: 'med-gone',
            reportId: 'rpt-1',
            path: '${tmp.path}/never-existed.jpg',
            bytes: 100,
            kind: 'IMAGE',
          )
        ],
        budgetBytes: 10000,
      );

      expect(result.failed, 1);
      // Android clears caches. This is unrecoverable, so it must not block
      // every future window.
      expect(uploader.uploadedMediaIds, contains('med-gone'));
    });

    test('one failure does not stop the others', () async {
      final backend = FakeMediaBackend(throwFor: {'med-bad'});
      final uploader = MediaUploader(backend: backend);
      final bad = makeFile('bad.jpg', 100);
      final good = makeFile('good.jpg', 200);

      final result = await uploader.upload(
        [pending('med-bad', bad), pending('med-good', good)],
        budgetBytes: 10000,
      );

      expect(result.uploaded, 1);
      expect(result.failed, 1);
      expect(backend.uploadedIds, ['med-good']);
    });
  });

  group('wire descriptors', () {
    test('local paths never reach the backend', () {
      final wire = wireMediaDescriptors([
        {
          'kind': 'IMAGE',
          'media_id': 'med-1',
          'local_path': '/data/user/0/com.avertis.avertis/files/a.jpg',
          'bytes': 84213,
          'inline': false,
        }
      ]);

      // A filesystem path leaks a username and means nothing off-device.
      expect(wire.single.containsKey('local_path'), isFalse);
      expect(wire.single['media_id'], 'med-1');
      expect(wire.single['bytes'], 84213);
    });

    test('the original descriptor is not mutated', () {
      final original = {
        'media_id': 'med-1',
        'local_path': '/tmp/a.jpg',
      };
      wireMediaDescriptors([original]);
      // The uploader still needs the path afterwards.
      expect(original.containsKey('local_path'), isTrue);
    });

    test('a missing or malformed media field yields nothing', () {
      expect(wireMediaDescriptors(null), isEmpty);
      expect(wireMediaDescriptors('nonsense'), isEmpty);
      expect(wireMediaDescriptors([]), isEmpty);
    });
  });
}
