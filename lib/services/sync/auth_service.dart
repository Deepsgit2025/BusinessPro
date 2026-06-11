import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:google_sign_in/google_sign_in.dart';

import '../../core/constants/app_strings.dart';
import '../../core/database/database_helper.dart';

/// Google Sign-In wrapper — **Android only**. It produces the Drive OAuth access
/// token the [DriveService] needs, caches it (plus the account email and expiry)
/// in the settings table, and exposes it for the QR handoff to Windows.
///
/// Windows never constructs this class: it has no google_sign_in plugin and
/// receives its token over the QR link instead. Every method guards on
/// [Platform.isAndroid] so an accidental call on Windows is a safe no-op rather
/// than a missing-plugin crash.
class AuthService {
  /// `drive.file` — app-created files only, the least-privilege Drive scope.
  static const _scopes = <String>['https://www.googleapis.com/auth/drive.file'];

  /// The OAuth **Web** client id (client_type 3 in google-services.json).
  /// google_sign_in on Android needs this as `serverClientId` to mint a token
  /// that the Drive REST API will accept. Without it, sign-in completes but the
  /// returned token is for the Android client and Drive rejects it.
  static const _serverClientId =
      '772018233967-97rj7rd2qc23efce1gvos9bkrd45o24i.apps.googleusercontent.com';

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: _scopes,
    serverClientId: _serverClientId,
  );

  bool get _supported => Platform.isAndroid;

  /// Interactive sign-in. Returns the chosen account, or null if the user
  /// cancelled (closed the picker). Throws [SignInException] on a real failure
  /// (misconfigured OAuth client, network, etc.) so the UI can show why rather
  /// than appearing to do nothing.
  Future<GoogleSignInAccount?> signIn() async {
    if (!_supported) return null;
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) return null; // user dismissed the picker
      await _cacheToken(account);
      return account;
    } on PlatformException catch (e) {
      throw SignInException(_friendlyMessage(e), e.code);
    }
  }

  /// Maps the raw platform error to something actionable. Code '10' is
  /// DEVELOPER_ERROR — almost always a SHA-1 / OAuth-client mismatch.
  String _friendlyMessage(PlatformException e) {
    switch (e.code) {
      case 'sign_in_failed':
        if ((e.message ?? '').contains('10') || (e.details?.toString() ?? '').contains('10')) {
          return 'Google rejected the sign-in (DEVELOPER_ERROR / code 10). '
              'The app\'s SHA-1 or OAuth client is not registered for this build.';
        }
        return 'Google sign-in failed: ${e.message ?? e.code}.';
      case 'network_error':
        return 'No internet connection for Google sign-in.';
      default:
        return 'Google sign-in failed: ${e.message ?? e.code}.';
    }
  }

  /// Silent re-auth (used on app start / before a sync). Returns the account if
  /// a session is still valid, refreshing the cached token along the way.
  Future<GoogleSignInAccount?> signInSilently() async {
    if (!_supported) return null;
    final account = await _googleSignIn.signInSilently();
    if (account != null) await _cacheToken(account);
    return account;
  }

  Future<void> signOut() async {
    if (_supported) {
      await _googleSignIn.signOut();
    }
    await _clearStoredToken();
  }

  Future<bool> isSignedIn() async {
    if (!_supported) {
      // On Windows "signed in" means we hold a (handed-off) token.
      return (await DatabaseHelper.getSettingStr(AppStrings.kDriveAccessToken))
          .isNotEmpty;
    }
    return _googleSignIn.isSignedIn();
  }

  /// A currently-valid Drive access token, refreshing via Google if needed
  /// (Android) or returning the handed-off token while it's unexpired (Windows).
  /// Null when no valid token is available.
  Future<String?> getAccessToken() async {
    if (_supported) {
      final account =
          await _googleSignIn.signInSilently() ?? _googleSignIn.currentUser;
      if (account == null) return null;
      final auth = await account.authentication;
      final token = auth.accessToken;
      if (token != null) {
        await _saveToken(token, account.email);
      }
      return token;
    }
    // Windows: use the cached handoff token until it expires.
    if (await isTokenExpired()) return null;
    final token = await DatabaseHelper.getSettingStr(AppStrings.kDriveAccessToken);
    return token.isEmpty ? null : token;
  }

  /// The cached Google account email (for the settings screen). Empty if none.
  Future<String> accountEmail() =>
      DatabaseHelper.getSettingStr(AppStrings.kSyncAccountEmail);

  /// Whether the cached token's expiry has passed. Treated as expired when no
  /// expiry was recorded, forcing a refresh.
  Future<bool> isTokenExpired() async {
    final expiryStr =
        await DatabaseHelper.getSettingStr(AppStrings.kDriveTokenExpiry);
    final expiry = DateTime.tryParse(expiryStr);
    if (expiry == null) return true;
    // 2-minute safety margin so we refresh before a long sync hits a 401.
    return DateTime.now()
        .isAfter(expiry.subtract(const Duration(minutes: 2)));
  }

  Future<void> _cacheToken(GoogleSignInAccount account) async {
    final auth = await account.authentication;
    if (auth.accessToken != null) {
      await _saveToken(auth.accessToken!, account.email);
    }
  }

  /// Persists the token + email. Google access tokens are short-lived (~1 hour);
  /// we record a conservative expiry so the refresh logic kicks in on time.
  Future<void> _saveToken(String accessToken, String email) async {
    await DatabaseHelper.setSetting(AppStrings.kDriveAccessToken, accessToken);
    await DatabaseHelper.setSetting(AppStrings.kSyncAccountEmail, email);
    await DatabaseHelper.setSetting(
      AppStrings.kDriveTokenExpiry,
      DateTime.now().add(const Duration(minutes: 55)).toIso8601String(),
    );
  }

  Future<void> _clearStoredToken() async {
    await DatabaseHelper.setSetting(AppStrings.kDriveAccessToken, '');
    await DatabaseHelper.setSetting(AppStrings.kSyncAccountEmail, '');
    await DatabaseHelper.setSetting(AppStrings.kDriveTokenExpiry, '');
  }
}

/// A genuine sign-in failure (not a user cancel). [code] is the underlying
/// platform error code (e.g. 'sign_in_failed'); [message] is UI-ready.
class SignInException implements Exception {
  final String message;
  final String code;
  const SignInException(this.message, this.code);

  @override
  String toString() => message;
}
