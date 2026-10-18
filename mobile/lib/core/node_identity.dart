/// This device's stable node identity.
///
/// The node ID must survive reinstalls-in-place and reboots, otherwise the
/// mesh sees a new stranger every launch and dedup/custody break.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

const _nodeIdKey = 'avertis.node_id';

/// Six characters keeps it inside a BLE advertisement payload.
String _freshId() =>
    'n${const Uuid().v4().replaceAll('-', '').substring(0, 5)}';

class NodeIdentity {
  NodeIdentity(this._storage);

  final FlutterSecureStorage _storage;

  /// True when the stored identity could not be read and a new one was
  /// issued. The mesh treats this node as a stranger; worth surfacing.
  bool recoveredFromCorruptStorage = false;

  /// This device's stable node id.
  ///
  /// Never throws. Secure storage fails in a way that is easy to meet and
  /// hard to diagnose: reinstalling the app on Android restores the old
  /// encrypted preferences while the Keystore key that decrypts them does
  /// not come back, so every read raises BadPaddingException.
  ///
  /// That used to take the whole app down. The identity is awaited before
  /// the mesh engine starts, so a throw here meant no engine, no
  /// permission prompt, no connectivity check, and an SOS that died on a
  /// null check — three unrelated-looking symptoms from one failed read.
  ///
  /// A forgotten node id costs deduplication history. Not starting costs
  /// the user everything, so the trade is not close.
  Future<String> nodeId() async {
    String? existing;
    try {
      existing = await _storage.read(key: _nodeIdKey);
    } on Exception catch (error) {
      debugPrint('avertis: could not read the stored node id ($error); '
          'issuing a new one');
      existing = null;
      recoveredFromCorruptStorage = true;
      // Clear the unreadable entry, or every launch repeats this.
      try {
        await _storage.delete(key: _nodeIdKey);
      } on Exception {
        // Nothing more to try; the write below may still fail, and that
        // is handled too.
      }
    }

    if (existing != null && existing.isNotEmpty) return existing;

    final id = _freshId();
    try {
      await _storage.write(key: _nodeIdKey, value: id);
    } on Exception catch (error) {
      // An id that does not persist still lets this launch work. The node
      // looks like a new device next time, which is a degradation, not a
      // failure.
      debugPrint('avertis: could not persist the node id ($error); '
          'it will not survive a restart');
      recoveredFromCorruptStorage = true;
    }
    return id;
  }
}
