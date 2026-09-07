/// The upload client against a real HTTP server.
///
/// The unit tests use a fake backend, which proves the policy but not the
/// wire. This starts an actual server, sends an actual multipart request, and
/// checks what arrived — the multipart encoding, the field names and the
/// integrity digest are all things a fake would happily get wrong.
library;

import 'dart:convert';
import 'dart:io';

import 'package:avertis/services/media_uploader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late String baseUrl;
  late List<Map<String, String>> received;
  late List<int> lastFileBytes;
  int status = 200;

  setUp(() async {
    received = [];
    lastFileBytes = [];
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = 'http://127.0.0.1:${server.port}';

    server.listen((request) async {
      final chunks = <int>[];
      await for (final chunk in request) {
        chunks.addAll(chunk);
      }
      final body = chunks;
      final text = latin1.decode(body, allowInvalid: true);

      // Pull the simple text fields out of the multipart body.
      final fields = <String, String>{};
      for (final part in text.split('--')) {
        final nameMatch = RegExp(r'name="([^"]+)"').firstMatch(part);
        if (nameMatch == null) continue;
        final name = nameMatch.group(1)!;
        final split = part.split('\r\n\r\n');
        if (split.length < 2) continue;
        final value = split[1].replaceAll(RegExp(r'[\r\n]+$'), '');
        if (part.contains('filename=')) {
          lastFileBytes = latin1.encode(value);
          continue;
        }
        fields[name] = value;
      }
      received.add(fields);

      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      if (status == 200) {
        request.response.write(jsonEncode({
          'media_id': fields['media_id'],
          'uri': 'gs://avertis/${fields['media_id']}',
        }));
      } else {
        request.response.write(jsonEncode({'error': 'nope'}));
      }
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Directory tmpDir() => Directory.systemTemp.createTempSync('avertis_http');

  test('a real multipart upload carries the contract fields', () async {
    final tmp = tmpDir();
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/photo.jpg')
      ..writeAsBytesSync(utf8.encode('pretend jpeg bytes'));

    final uploader =
        MediaUploader(backend: HttpMediaBackend(baseUrl: baseUrl));

    final result = await uploader.upload(
      [
        PendingMedia(
          mediaId: 'med-http-1',
          reportId: 'rpt-http-1',
          path: file.path,
          bytes: file.lengthSync(),
          kind: 'IMAGE',
        )
      ],
      budgetBytes: 100000,
    );

    expect(result.uploaded, 1);
    expect(result.uris['med-http-1'], 'gs://avertis/med-http-1');

    final sent = received.single;
    expect(sent['media_id'], 'med-http-1');
    expect(sent['report_id'], 'rpt-http-1');

    // The digest must match the bytes the server actually received.
    final expected =
        sha256.convert(utf8.encode('pretend jpeg bytes')).toString();
    expect(sent['sha256'], expected);
    expect(utf8.decode(lastFileBytes), 'pretend jpeg bytes');
  });

  test('a server error leaves the media retryable', () async {
    status = 500;
    final tmp = tmpDir();
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/photo.jpg')..writeAsBytesSync([1, 2, 3]);

    final uploader =
        MediaUploader(backend: HttpMediaBackend(baseUrl: baseUrl));
    final result = await uploader.upload(
      [
        PendingMedia(
          mediaId: 'med-fail',
          reportId: 'rpt-1',
          path: file.path,
          bytes: 3,
          kind: 'IMAGE',
        )
      ],
      budgetBytes: 100000,
    );

    expect(result.uploaded, 0);
    expect(result.failed, 1);
    // Still offered next window — the failure was the server's, not ours.
    expect(uploader.uploadedMediaIds, isNot(contains('med-fail')));
  });

  test('an unreachable server does not throw', () async {
    final tmp = tmpDir();
    addTearDown(() => tmp.deleteSync(recursive: true));
    final file = File('${tmp.path}/photo.jpg')..writeAsBytesSync([1, 2, 3]);

    // Port 1 is not listening.
    final uploader = MediaUploader(
      backend: HttpMediaBackend(baseUrl: 'http://127.0.0.1:1'),
    );
    final result = await uploader.upload(
      [
        PendingMedia(
          mediaId: 'med-unreachable',
          reportId: 'rpt-1',
          path: file.path,
          bytes: 3,
          kind: 'IMAGE',
        )
      ],
      budgetBytes: 100000,
    );

    expect(result.failed, 1);
    expect(result.uploaded, 0);
  });
}
