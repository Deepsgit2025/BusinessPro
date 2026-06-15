import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hashing helper for the optional PIN lock.
///
/// The PIN is NEVER stored in plain text — only its SHA-256 digest is persisted
/// (in the `settings` table under `security_pin_hash`). This is a device-local
/// guard, not a cryptographic secret store, so a plain SHA-256 (no salt) is the
/// intentional, simple choice.
class PinHashUtil {
  PinHashUtil._();

  /// Returns the hex-encoded SHA-256 digest of [pin].
  static String hash(String pin) {
    final digest = sha256.convert(utf8.encode(pin));
    return digest.toString();
  }

  /// Returns true when [pin] hashes to [storedHash].
  static bool verify(String pin, String storedHash) {
    if (storedHash.isEmpty) return false;
    return hash(pin) == storedHash;
  }
}
