import 'smart_otp_stub.dart'
    if (dart.library.io) 'smart_otp_device.dart'
    as device;
import 'totp.dart';

/// Nene Smart OTP keeps the authenticator setup key on this phone and
/// produces the same 6-digit code an authenticator app would, after the
/// person unlocks it with a fingerprint or the phone's screen lock.
///
/// The server is unchanged: it still checks an ordinary TOTP code bound to
/// the reviewed operation. The unlock prompt is enforced by the app; the key
/// is encrypted with an Android Keystore key, not bound to the fingerprint.
abstract interface class SmartOtp {
  /// Whether this phone can hold a Smart OTP key (Android with a screen lock).
  Future<bool> available();

  /// Whether a key is saved for [userId] on this phone.
  Future<bool> enabled(String userId);

  /// Asks for a fingerprint or the screen lock, then returns a fresh code
  /// from the key saved for [userId]. Null when cancelled or no key is saved.
  /// Waits for the next 30-second step if this phone already used the current
  /// one, because the server accepts each code once.
  Future<String?> code(String userId);

  /// Asks for a fingerprint or the screen lock, saves [secret] as the key for
  /// [userId] and returns its first code. Any previous key is kept until
  /// [keep] or [restore]. Null when cancelled or unavailable.
  Future<String?> adopt(String userId, String secret);

  /// Confirms the key saved by [adopt] after the server accepted its code.
  Future<void> keep(String userId);

  /// Puts back the key from before [adopt], or removes it if there was none.
  Future<void> restore(String userId);

  /// Removes the key for [userId] from this phone.
  Future<void> remove(String userId);
}

/// For web and desktop previews and tests: Smart OTP is never offered.
class UnavailableSmartOtp implements SmartOtp {
  const UnavailableSmartOtp();
  @override
  Future<bool> available() async => false;
  @override
  Future<bool> enabled(String userId) async => false;
  @override
  Future<String?> code(String userId) async => null;
  @override
  Future<String?> adopt(String userId, String secret) async => null;
  @override
  Future<void> keep(String userId) async {}
  @override
  Future<void> restore(String userId) async {}
  @override
  Future<void> remove(String userId) async {}
}

/// Smart OTP backed by the Android Keystore and the device unlock prompt;
/// unavailable on web.
SmartOtp createDeviceSmartOtp() => device.createSmartOtp();

/// Encrypted key storage on the phone.
abstract interface class SmartOtpKeys {
  Future<bool> has(String name);
  Future<String?> read(String name);
  Future<void> write(String name, String value);
  Future<void> delete(String name);
}

/// The Smart OTP rules, independent of the platform plugins.
class KeyedSmartOtp implements SmartOtp {
  KeyedSmartOtp({
    required this.keys,
    required this.supported,
    required this.unlock,
    DateTime Function()? clock,
    Future<void> Function(Duration)? wait,
  }) : _clock = clock ?? DateTime.now,
       _wait = wait ?? Future<void>.delayed;

  final SmartOtpKeys keys;
  final Future<bool> Function() supported;

  /// Shows the fingerprint / screen-lock prompt; true when the person passed.
  final Future<bool> Function(String reason) unlock;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _wait;

  /// Last time step used per key, so a code is never offered twice.
  final _lastStep = <String, int>{};

  /// Keys replaced by [adopt] that are not yet confirmed or restored.
  final _previous = <String, String?>{};

  static String _name(String userId) => 'nene.smart_otp.$userId';

  @override
  Future<bool> available() async {
    try {
      return await supported();
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> enabled(String userId) async {
    if (!await available()) return false;
    try {
      return await keys.has(_name(userId));
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> code(String userId) async {
    if (!await enabled(userId)) return null;
    if (!await _unlock('Confirm with Nene Smart OTP')) return null;
    final secret = await keys.read(_name(userId));
    if (secret == null || secret.isEmpty) return null;
    try {
      return await _fresh(secret);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<String?> adopt(String userId, String secret) async {
    if (!await available()) return null;
    try {
      base32Decode(secret);
    } on FormatException {
      return null;
    }
    if (!await _unlock('Turn on Nene Smart OTP')) return null;
    final name = _name(userId);
    if (!_previous.containsKey(userId)) {
      _previous[userId] = await keys.read(name);
    }
    await keys.write(name, secret);
    return _fresh(secret);
  }

  @override
  Future<void> keep(String userId) async => _previous.remove(userId);

  @override
  Future<void> restore(String userId) async {
    if (!_previous.containsKey(userId)) return;
    final previous = _previous.remove(userId);
    if (previous == null) {
      await keys.delete(_name(userId));
    } else {
      await keys.write(_name(userId), previous);
    }
  }

  @override
  Future<void> remove(String userId) async {
    _previous.remove(userId);
    await keys.delete(_name(userId));
  }

  Future<bool> _unlock(String reason) async {
    try {
      return await unlock(reason);
    } catch (_) {
      return false;
    }
  }

  Future<String> _fresh(String secret) async {
    var step = totpStep(_clock());
    final last = _lastStep[secret];
    if (last != null && step <= last) {
      step = last + 1;
      final left = totpStepStart(step).difference(_clock().toUtc());
      if (left > Duration.zero) await _wait(left);
    }
    _lastStep[secret] = step;
    return totpCode(secret, step);
  }
}
