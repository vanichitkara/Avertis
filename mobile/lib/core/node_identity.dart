/// This device's stable node identity.
///
/// The node ID must survive reinstalls-in-place and reboots, otherwise the
/// mesh sees a new stranger every launch and dedup/custody break.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

const _nodeIdKey = 'avertis.node_id';

class NodeIdentity {
  NodeIdentity(this._storage);

  final FlutterSecureStorage _storage;

  Future<String> nodeId() async {
    final existing = await _storage.read(key: _nodeIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    // Six characters keeps it inside a BLE advertisement payload.
    final id = 'n${const Uuid().v4().replaceAll('-', '').substring(0, 5)}';
    await _storage.write(key: _nodeIdKey, value: id);
    return id;
  }
}
