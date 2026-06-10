import 'dart:io';

import 'backup_provider.dart';

/// Placeholder S3 backup provider. Intentionally unimplemented — it exists so a
/// future AWS migration is a one-line swap at the composition root
/// (`BackupManager(GoogleDriveBackup())` → `BackupManager(AwsS3Backup())`) and
/// touches no other file. Every method throws [UnimplementedError] until the
/// real S3 client is wired up.
class AwsS3Backup implements BackupProvider {
  @override
  String get name => 'AWS S3';

  @override
  Future<void> upload(File dbFile, String fileName) async =>
      throw UnimplementedError('AWS backup not configured yet');

  @override
  Future<File> download(String backupId, String localPath) async =>
      throw UnimplementedError('AWS backup not configured yet');

  @override
  Future<List<BackupRecord>> listBackups() async =>
      throw UnimplementedError('AWS backup not configured yet');

  @override
  Future<void> deleteBackup(String backupId) async =>
      throw UnimplementedError('AWS backup not configured yet');

  @override
  Future<bool> isAuthenticated() async => false;

  @override
  Future<void> signIn() async =>
      throw UnimplementedError('AWS backup not configured yet');

  @override
  Future<void> signOut() async {}
}
