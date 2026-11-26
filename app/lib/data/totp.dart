import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// RFC 6238 time-based codes with the parameters Supabase Auth uses for TOTP
/// factors: HMAC-SHA1, 30-second steps and 6 digits.
const totpPeriodSeconds = 30;

/// The 30-second time step that contains [time].
int totpStep(DateTime time) =>
    time.toUtc().millisecondsSinceEpoch ~/ 1000 ~/ totpPeriodSeconds;

/// When the time step after [step] begins.
DateTime totpStepStart(int step) => DateTime.fromMillisecondsSinceEpoch(
  step * totpPeriodSeconds * 1000,
  isUtc: true,
);

/// The 6-digit code for [base32Secret] in time step [step].
/// Throws [FormatException] for a malformed secret.
String totpCode(String base32Secret, int step) {
  final key = base32Decode(base32Secret);
  // Two 32-bit writes: setUint64 is unsupported when compiled to JavaScript.
  final counter = ByteData(8)
    ..setUint32(0, step ~/ 0x100000000)
    ..setUint32(4, step % 0x100000000);
  final hash = Hmac(sha1, key).convert(counter.buffer.asUint8List()).bytes;
  final offset = hash.last & 0x0f;
  final binary =
      ((hash[offset] & 0x7f) << 24) |
      (hash[offset + 1] << 16) |
      (hash[offset + 2] << 8) |
      hash[offset + 3];
  return (binary % 1000000).toString().padLeft(6, '0');
}

/// Decodes RFC 4648 base32, ignoring case, spaces, hyphens and padding.
Uint8List base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final clean = input.toUpperCase().replaceAll(RegExp(r'[\s=-]'), '');
  if (clean.isEmpty) throw const FormatException('Empty secret.');
  final out = <int>[];
  var buffer = 0, bits = 0;
  for (final unit in clean.codeUnits) {
    final value = alphabet.indexOf(String.fromCharCode(unit));
    if (value < 0) throw const FormatException('Invalid secret.');
    buffer = (buffer << 5) | value;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
    buffer &= (1 << bits) - 1;
  }
  return Uint8List.fromList(out);
}
