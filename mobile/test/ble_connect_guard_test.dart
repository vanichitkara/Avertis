/// A guard that is never released takes the peer out of service.
///
/// Two GATT setups must not run at once on one connection, so the
/// transport holds the peer id in an in-flight set while it connects,
/// discovers services and subscribes. Only `connect` carries a timeout of
/// its own: `discoverServices` and the CCCD write can both wait forever on
/// a link that has been torn down underneath them.
///
/// When that happened the peer id stayed in the set for the rest of the
/// session. Nothing retried, nothing reported an error, and the phone that
/// was supposed to dial never dialled again — while the other handset sat
/// on "found a peer, waiting for it to connect to us", which is exactly
/// what both phones showed.
library;

import 'dart:async';

import 'package:avertis/mesh/transport/ble_mesh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

const Duration limit = Duration(milliseconds: 50);

void main() {
  late Set<String> inFlight;
  late List<String> events;

  setUp(() {
    inFlight = <String>{};
    events = <String>[];
  });

  Future<void> run(Future<void> Function() body) => runOnceGuarded(
    inFlight,
    'n563b4',
    body,
    limit,
    onTimeout: () => events.add('timeout'),
    onError: (error) => events.add('error: $error'),
  );

  test('a body that never returns still releases the peer — the bug', () async {
    await run(() => Completer<void>().future);

    expect(events, ['timeout']);
    expect(
      inFlight,
      isEmpty,
      reason: 'a wedged setup must not retire the peer permanently',
    );
  });

  test('and the next attempt is allowed to start', () async {
    await run(() => Completer<void>().future);
    await run(() async => events.add('second attempt ran'));

    expect(events, ['timeout', 'second attempt ran']);
  });

  test('a successful setup releases it too', () async {
    await run(() async => events.add('connected'));

    expect(events, ['connected']);
    expect(inFlight, isEmpty);
  });

  test('a failing setup releases it and reports why', () async {
    await run(() async => throw Exception('no such device'));

    expect(events.single, contains('no such device'));
    expect(inFlight, isEmpty);
  });

  test('a second attempt while one is in flight is skipped', () async {
    final first = run(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      events.add('first');
    });
    await run(() async => events.add('second'));
    await first;

    expect(
      events,
      ['first'],
      reason: 'two setups on one GATT connection is what the guard exists '
          'to prevent',
    );
  });

  test('the bound is longer than the connect attempt it contains', () {
    // `connect` waits 8 s. A shorter overall bound would abandon healthy
    // connections before they had finished.
    expect(
      BleMeshTransport.linkSetupTimeout,
      greaterThan(const Duration(seconds: 8)),
    );
    expect(
      BleMeshTransport.linkSetupTimeout,
      lessThan(const Duration(minutes: 1)),
      reason: 'and short enough that a wedged peer recovers within a demo',
    );
  });
}
