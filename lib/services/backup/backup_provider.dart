import 'dart:io';

/// A pluggable backup destination. The app talks only to this interface (via
/// [BackupManager]) — never to a concrete provider — so swapping Google Drive
/// for AWS S3 later is a one-line change at the composition root and nothing
/// else in the codebase moves.
///
/// See [BackupRecord] for the listing shape every provider must return.
abstract class BackupProvider {
  /// Human label for the destination, e.g. 'Google Drive'. Used in UI copy.
  String get name;

  /// Uploads [dbFile] under [fileName] to the destination, pruning to a small
  /// rolling window of recent backups (the implementation decides the cap).
  Future<void> upload(File dbFile, String fileName);

  /// Downloads the backup identified by [backupId] to [localPath], returning the
  /// written file.
  Future<File> download(String backupId, String localPath);

  /// Lists existing backups, newest first.
  Future<List<BackupRecord>> listBackups();

  /// Permanently deletes the backup identified by [backupId].
  Future<void> deleteBackup(String backupId);

  /// Whether the provider currently has valid credentials / a signed-in session.
  Future<bool> isAuthenticated();

  /// Begins an interactive sign-in (e.g. OAuth consent). No-op for providers
  /// that don't authenticate.
  Future<void> signIn();

  /// Clears the current session / credentials.
  Future<void> signOut();
}

/// One backup as seen in a provider's listing.
class BackupRecord {
  final String id;
  final String fileName;
  final DateTime createdAt;
  final int fileSizeBytes;
  final String provider; // 'google_drive' | 'aws_s3' | 'local'

  const BackupRecord({
    required this.id,
    required this.fileName,
    required this.createdAt,
    required this.fileSizeBytes,
    required this.provider,
  });

  /// Human-readable size, e.g. "1.4 MB".
  String get sizeLabel {
    if (fileSizeBytes < 1024) return '$fileSizeBytes B';
    if (fileSizeBytes < 1024 * 1024) {
      return '${(fileSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
