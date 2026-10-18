/// Node identity must never be the reason the app fails to start.
///
/// Reinstalling on Android restores the previous encrypted preferences
/// without the Keystore key that decrypts them, so every secure-storage
/// read raises a padding error. The identity is awaited before the mesh
/// engine starts, so that one throw meant: no engine, no permission
/// prompt, no connectivity check, and an SOS dying on a null check —
/// three unrelated-looking symptoms from a single unreadable value.
library;

import 'package:avertis/core/node_identity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the platform keystore, including the ways it fails.
class FakeSecureStorage implements FlutterSecureStorage {
  FakeSecureStorage({
    this.readThrows = false,
    this.writeThrows = false,
    this.deleteThrows = false,
    Map<String, String>? initial,
  }) : _values = {...?initial};

  final Map<String, String> _values;
  bool readThrows;
  final bool writeThrows;
  final bool deleteThrows;

  int reads = 0;
  int writes = 0;
  int deletes = 0;

  @override
  Future<String?> read({required String key, dynamic iOptions,
      dynamic aOptions, dynamic lOptions, dynamic webOptions,
      dynamic mOptions, dynamic wOptions}) async {
    reads++;
    if (readThrows) {
      // What Android actually raises after a reinstall.
      throw PlatformException(
        code: 'BadPaddingException',
        message: 'javax.crypto.BadPaddingException: '
            'error:1e000065:Cipher functions:OPENSSL_internal:BAD_DECRYPT',
      );
    }
    return _values[key];
  }

  @override
  Future<void> write({required String key, required String? value,
      dynamic iOptions, dynamic aOptions, dynamic lOptions,
      dynamic webOptions, dynamic mOptions, dynamic wOptions}) async {
    writes++;
    if (writeThrows) throw PlatformException(code: 'WriteFailed');
    if (value != null) _values[key] = value;
  }

  @override
  Future<void> delete({required String key, dynamic iOptions,
      dynamic aOptions, dynamic lOptions, dynamic webOptions,
      dynamic mOptions, dynamic wOptions}) async {
    deletes++;
    if (deleteThrows) throw PlatformException(code: 'DeleteFailed');
    _values.remove(key);
    // A real delete makes the entry readable again (as absent).
    readThrows = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a first launch issues and stores an id', () async {
    final storage = FakeSecureStorage();
    final id = await NodeIdentity(storage).nodeId();

    expect(id, startsWith('n'));
    expect(id, hasLength(6), reason: 'must fit a BLE advertisement');
    expect(storage.writes, 1);
  });

  test('a stored id is reused, not reissued', () async {
    final storage = FakeSecureStorage(initial: {'avertis.node_id': 'nabc12'});
    expect(await NodeIdentity(storage).nodeId(), 'nabc12');
    expect(storage.writes, 0, reason: 'the mesh relies on a stable id');
  });

  group('after a reinstall, when the keystore cannot decrypt', () {
    test('an id is still issued rather than throwing', () async {
      final storage = FakeSecureStorage(readThrows: true);
      final identity = NodeIdentity(storage);

      final id = await identity.nodeId();

      expect(id, startsWith('n'));
      expect(identity.recoveredFromCorruptStorage, isTrue);
    });

    test('the unreadable entry is cleared so it does not recur', () async {
      final storage = FakeSecureStorage(readThrows: true);
      await NodeIdentity(storage).nodeId();

      expect(storage.deletes, 1,
          reason: 'left in place, every launch repeats the failure');
    });

    test('a failing delete does not stop an id being issued', () async {
      final storage =
          FakeSecureStorage(readThrows: true, deleteThrows: true);
      expect(await NodeIdentity(storage).nodeId(), startsWith('n'));
    });
  });

  test('an id is returned even when it cannot be persisted', () async {
    // It will not survive a restart, which is a degradation. Refusing to
    // start would be a failure.
    final storage = FakeSecureStorage(writeThrows: true);
    final identity = NodeIdentity(storage);

    expect(await identity.nodeId(), startsWith('n'));
    expect(identity.recoveredFromCorruptStorage, isTrue);
  });

  test('every failure mode still yields a usable id', () async {
    for (final storage in [
      FakeSecureStorage(readThrows: true),
      FakeSecureStorage(writeThrows: true),
      FakeSecureStorage(readThrows: true, writeThrows: true),
      FakeSecureStorage(readThrows: true, deleteThrows: true),
      FakeSecureStorage(
          readThrows: true, writeThrows: true, deleteThrows: true),
    ]) {
      final id = await NodeIdentity(storage).nodeId();
      expect(id, startsWith('n'));
      expect(id.length, 6);
    }
  });
}
