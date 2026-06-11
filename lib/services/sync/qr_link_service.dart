import 'package:cloud_firestore/cloud_firestore.dart';

/// One-time device linking over Firestore. This is the **only** use of Firebase
/// in the app, and it never carries business data — just a short-lived Drive
/// OAuth token plus the Android device id, deposited by Android and fetched once
/// by Windows, then deleted.
///
/// Flow: Android calls [generateLinkCode] → writes a `link_tokens/<CODE>` doc
/// with a 60-second TTL and shows `<CODE>` as a QR. Windows scans it, calls
/// [fetchTokenFromCode], reads the doc, deletes it, and keeps the token locally.
class QrLinkService {
  static const _collection = 'link_tokens';
  /// Firestore collection holding the latest Drive token per Android device, so
  /// Windows can refresh transparently after its handed-off token expires
  /// (instead of forcing a re-link). Still no business data — just the OAuth
  /// access token + expiry, overwritten by Android on each sync.
  static const _relayCollection = 'device_tokens';
  static const tokenTtlSeconds = 60;

  FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// ANDROID: publishes the current fresh Drive [accessToken] (+ [expiry]) to the
  /// relay doc keyed by Android's [androidDeviceId]. Called on every Android sync
  /// so the doc stays fresh. Best-effort — a failure here never breaks the sync.
  Future<void> publishToken({
    required String androidDeviceId,
    required String accessToken,
    required DateTime expiry,
  }) async {
    if (androidDeviceId.isEmpty || accessToken.isEmpty) return;
    try {
      await _db.collection(_relayCollection).doc(androidDeviceId).set({
        'access_token': accessToken,
        'expires_at': expiry.toIso8601String(),
        'updated_at': FieldValue.serverTimestamp(),
      });
    } catch (_) {/* ignore — sync continues with the in-memory token */}
  }

  /// WINDOWS: fetches the latest relayed token for [androidDeviceId], or null if
  /// none/expired. Lets Windows refresh without re-linking.
  Future<RelayToken?> fetchRelayToken(String androidDeviceId) async {
    if (androidDeviceId.isEmpty) return null;
    try {
      final doc =
          await _db.collection(_relayCollection).doc(androidDeviceId).get();
      if (!doc.exists) return null;
      final data = doc.data()!;
      final token = data['access_token'] as String?;
      final expiry = DateTime.tryParse(data['expires_at'] as String? ?? '');
      if (token == null || token.isEmpty || expiry == null) return null;
      if (DateTime.now().isAfter(expiry)) return null; // relayed token also stale
      return RelayToken(token, expiry);
    } catch (_) {
      return null;
    }
  }

  /// Deposits [accessToken] + [deviceId] under a fresh short code and returns the
  /// code (the QR payload). The doc self-expires: Windows deletes it on read, and
  /// a [Future.delayed] sweep removes it if no one ever scans.
  Future<String> generateLinkCode({
    required String accessToken,
    required String deviceId,
    String? deviceName,
  }) async {
    final code = _shortCode();
    final now = DateTime.now();
    await _db.collection(_collection).doc(code).set({
      'access_token': accessToken,
      'device_id': deviceId,
      'device_name': deviceName,
      'device_type': 'android',
      'created_at': FieldValue.serverTimestamp(),
      'expires_at':
          now.add(const Duration(seconds: tokenTtlSeconds)).toIso8601String(),
    });

    // Best-effort auto-cleanup if the code is never scanned. Failures here are
    // harmless (the doc is also deleted on a successful scan, and is useless
    // after expiry regardless).
    Future.delayed(const Duration(seconds: tokenTtlSeconds), () async {
      try {
        await _db.collection(_collection).doc(code).delete();
      } catch (_) {/* ignore */}
    });

    return code;
  }

  /// Looks up [code] (case-insensitive), returning the handoff payload. Deletes
  /// the doc immediately on a successful read so the token can't be reused.
  Future<LinkResult> fetchTokenFromCode(String code) async {
    final id = code.trim().toUpperCase();
    if (id.isEmpty) return LinkResult.notFound();

    final ref = _db.collection(_collection).doc(id);
    final doc = await ref.get();
    if (!doc.exists) return LinkResult.notFound();

    final data = doc.data()!;
    final expires = DateTime.tryParse(data['expires_at'] as String? ?? '');
    if (expires != null && DateTime.now().isAfter(expires)) {
      await ref.delete();
      return LinkResult.expired();
    }

    await ref.delete(); // single-use

    final token = data['access_token'] as String?;
    if (token == null || token.isEmpty) return LinkResult.notFound();

    return LinkResult.success(
      accessToken: token,
      androidDeviceId: (data['device_id'] as String?) ?? '',
      androidDeviceName: data['device_name'] as String?,
    );
  }

  /// An 8-char uppercase code (e.g. "A1B2C3D4"). Avoids look-alike characters so
  /// manual entry (the QR fallback) is less error-prone.
  String _shortCode() {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final now = DateTime.now().microsecondsSinceEpoch;
    var seed = now;
    final buf = StringBuffer();
    for (var i = 0; i < 8; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      buf.write(alphabet[seed % alphabet.length]);
    }
    return buf.toString();
  }
}

/// Outcome of a Windows-side [QrLinkService.fetchTokenFromCode].
class LinkResult {
  final LinkStatus status;
  final String? accessToken;
  final String? androidDeviceId;
  final String? androidDeviceName;

  const LinkResult._(
    this.status, {
    this.accessToken,
    this.androidDeviceId,
    this.androidDeviceName,
  });

  factory LinkResult.success({
    required String accessToken,
    required String androidDeviceId,
    String? androidDeviceName,
  }) =>
      LinkResult._(LinkStatus.success,
          accessToken: accessToken,
          androidDeviceId: androidDeviceId,
          androidDeviceName: androidDeviceName);

  factory LinkResult.expired() => const LinkResult._(LinkStatus.expired);
  factory LinkResult.notFound() => const LinkResult._(LinkStatus.notFound);

  bool get isSuccess => status == LinkStatus.success;
}

enum LinkStatus { success, expired, notFound }

/// A token pulled from the Firestore relay (Windows token auto-refresh).
class RelayToken {
  final String accessToken;
  final DateTime expiry;
  const RelayToken(this.accessToken, this.expiry);
}
