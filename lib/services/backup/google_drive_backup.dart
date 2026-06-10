import 'dart:io';

import 'backup_provider.dart';

/// Google Drive backup provider — scaffolded but not yet activated.
///
/// The full data flow (find/create a "BusinessPro Backups" folder, upload the
/// .db there, keep the latest 10, list/download/delete by Drive file id) is
/// designed here, but the actual network calls are gated behind [_configured]
/// and currently throw a clear "not configured" error. Turning Drive on is a
/// self-contained job that lives entirely in this file:
///
///   1. Add to pubspec: google_sign_in, googleapis, googleapis_auth.
///   2. Provision an OAuth client (Android: SHA-1 + package; iOS: reversed
///      client id; desktop has no official google_sign_in support — Drive is
///      mobile-only for now).
///   3. Replace the bodies below with the real google_sign_in + Drive v3 calls
///      using the `drive.file` scope (app-created files only — safest for Play
///      review). Flip [_configured] to true.
///
/// Nothing outside this file changes when Drive is enabled — the app only ever
/// sees the [BackupProvider] interface through [BackupManager].
class GoogleDriveBackup implements BackupProvider {
  static const _folderName = 'BusinessPro Backups';

  /// Max backups retained on Drive; the oldest is pruned on each upload.
  static const _maxBackups = 10;

  /// Flip to true once google_sign_in + googleapis are wired up and OAuth
  /// credentials are in place. While false, every network method throws a
  /// friendly "not configured" error and the Backup screen hides the cloud
  /// section's actions.
  static const bool _configured = false;

  @override
  String get name => 'Google Drive';

  /// Describes how Drive backups will behave once activated — surfaced in the
  /// Backup screen's info text. Also keeps [_folderName] / [_maxBackups]
  /// referenced while the network bodies are still stubbed out.
  static String get planDescription =>
      'Backups upload to a "$_folderName" folder; the latest $_maxBackups are kept.';

  Never _notConfigured() => throw const _DriveNotConfigured();

  @override
  Future<bool> isAuthenticated() async {
    if (!_configured) return false;
    // return _googleSignIn.isSignedIn();  // when wired up
    _notConfigured();
  }

  @override
  Future<void> signIn() async {
    if (!_configured) _notConfigured();
    // await _googleSignIn.signIn();
  }

  @override
  Future<void> signOut() async {
    if (!_configured) return;
    // await _googleSignIn.signOut();
  }

  @override
  Future<void> upload(File dbFile, String fileName) async {
    if (!_configured) _notConfigured();
    // 1. Obtain authenticated Drive client from the signed-in account.
    // 2. Find or create the `_folderName` folder.
    // 3. Upload `dbFile` as `fileName` (mime application/x-sqlite3) into it.
    // 4. List the folder; if > `_maxBackups`, delete the oldest by createdTime.
  }

  @override
  Future<File> download(String backupId, String localPath) async {
    // Stream the Drive file `backupId` to `localPath` and return File(localPath).
    _notConfigured();
  }

  @override
  Future<List<BackupRecord>> listBackups() async {
    if (!_configured) return const [];
    // Query files in `_folderName`, map to BackupRecord(provider: 'google_drive'),
    // sorted by createdAt DESC.
    _notConfigured();
  }

  @override
  Future<void> deleteBackup(String backupId) async {
    if (!_configured) _notConfigured();
    // Delete the Drive file by id.
  }
}

/// Thrown by every [GoogleDriveBackup] network method while Drive is disabled.
/// The Backup screen catches this and shows a "Connect Google Drive later"
/// hint rather than a raw stack trace.
class _DriveNotConfigured implements Exception {
  const _DriveNotConfigured();
  @override
  String toString() =>
      'Google Drive backup isn\'t set up yet. Use Local backup / Share for now.';
}
