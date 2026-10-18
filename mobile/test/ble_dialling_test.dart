/// Only one of a pair places the call.
///
/// Both phones scan, both find each other, and both used to connect.
/// Android then has a GATT client and a GATT server at each end of a
/// single ACL link, and the pair does not survive it: the second
/// connection lands on the existing link, one side's subscription never
/// registers, and the link ends up carrying traffic one way only.
///
/// The phone that cannot write falls back to notifying, and its own
/// notifications are refused because the peer never subscribed — which
/// is the "the GATT server refused a notification … is the peer
/// subscribed?" that both handsets reported while a report sat queued
/// on one of them and the other showed nothing at all.
library;

import 'package:avertis/mesh/transport/ble_mesh_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exactly one of a pair dials', () {
    expect(dialsFirst('n2b5cd', 'n563b4'), isTrue);
    expect(dialsFirst('n563b4', 'n2b5cd'), isFalse);
  });

  test('that holds for any pair of ids', () {
    // The two from the handsets, plus ids that stress the ordering.
    const ids = [
      'n2b5cd',
      'n563b4',
      'n00000',
      'nfffff',
      'nabcde',
      'n7ac20',
      'naaaaa',
    ];
    for (final a in ids) {
      for (final b in ids) {
        if (a == b) continue;
        expect(
          dialsFirst(a, b) != dialsFirst(b, a),
          isTrue,
          reason:
              'both ends of $a/$b must reach opposite conclusions, '
              'or they both dial and the link breaks',
        );
      }
    }
  });

  test('a node does not dial itself', () {
    expect(dialsFirst('n2b5cd', 'n2b5cd'), isFalse);
  });

  test('the decision is stable across reconnections', () {
    // Nothing in it depends on timing, link state or who was seen
    // first, so a dropped connection cannot swap the roles and leave
    // both sides waiting.
    for (var i = 0; i < 50; i++) {
      expect(dialsFirst('n2b5cd', 'n563b4'), isTrue);
    }
  });

  test('the waiting side retries after one further scan window', () {
    // If the designated dialler cannot see the other phone's advertisement,
    // the waiting side must take over promptly. Three additional windows
    // meant a gateway could sit idle for about 30 seconds.
    expect(BleMeshTransport.waitScansBeforeDialling, 1);
  });
}
