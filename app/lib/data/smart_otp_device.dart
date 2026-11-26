import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';

import 'smart_otp.dart';

/// Android only: the key is stored with AES-GCM under an Android Keystore key,
/// and read only after the fingerprint / screen-lock prompt succeeds.
SmartOtp createSmartOtp() {
  final auth = LocalAuthentication();
  return KeyedSmartOtp(
    keys: const _SecureKeys(FlutterSecureStorage()),
    supported: () async =>
        defaultTargetPlatform == TargetPlatform.android &&
        await auth.isDeviceSupported(),
    unlock: (reason) => auth.authenticate(
      localizedReason: reason,
      persistAcrossBackgrounding: true,
    ),
  );
}

class _SecureKeys implements SmartOtpKeys {
  const _SecureKeys(this._storage);
  final FlutterSecureStorage _storage;
  @override
  Future<bool> has(String name) => _storage.containsKey(key: name);
  @override
  Future<String?> read(String name) => _storage.read(key: name);
  @override
  Future<void> write(String name, String value) =>
      _storage.write(key: name, value: value);
  @override
  Future<void> delete(String name) => _storage.delete(key: name);
}
