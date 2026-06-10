import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/constants/app_strings.dart';
import '../../core/database/database_helper.dart';
import 'backup_provider.dart';

/// The single entry point the app uses for all backup/restore work. It owns the
/// "checkpoint the DB, copy the file, hand off to a destination" choreography
/// and delegates only the *where* (cloud upload/list/download/delete) to the
/// injected [BackupProvider]. Local backup, share, and restore-from-file work
/// without any provider and run fully offline.
class BackupManager {
  final BackupProvider provider;
  BackupManager(this.provider);

  // ── Naming & paths ─────────────────────────────────────────────────────────

  /// A timestamped, filesystem-safe backup file name keyed to the business.
  /// e.g. BusinessPro_Acme_Traders_20260610_1718000000000.db
  Future<String> createBackupFileName(String businessName) async {
    final now = DateTime.now();
    final clean = businessName.trim().isEmpty
        ? 'Business'
        : businessName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    final y = now.year.toString();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return 'BusinessPro_${clean}_$y$m${d}_${now.millisecondsSinceEpoch}.db';
  }

  /// The live SQLite database file.
  Future<File> getDatabaseFile() async =>
      File(await DatabaseHelper.databasePath());

  // ── Producing a consistent snapshot ────────────────────────────────────────

  /// Copies the live DB to [destPath], first flushing the WAL into the main
  /// file so the copy is self-contained (no dependence on the -wal/-shm
  /// sidecars). Returns the written file.
  Future<File> _snapshotTo(String destPath) async {
    final db = await DatabaseHelper.database;
    // Fold the write-ahead log back into the main database file so a plain copy
    // captures every committed change.
    await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    final src = await getDatabaseFile();
    await Directory(p.dirname(destPath)).create(recursive: true);
    return src.copy(destPath);
  }

  // ── Local backup / share ───────────────────────────────────────────────────

  /// Saves a backup copy to a user-browsable location and returns its path.
  ///
  /// The whole point is that the saved file must be findable later in a file
  /// manager and the "Restore from File" picker — so this deliberately avoids
  /// the app's private sandbox (`Android/data/<pkg>/…`), which Android 11+ hides
  /// from both. Target, in order of preference:
  ///   • Android → the public Downloads folder (`/storage/emulated/0/Download`)
  ///     in a `BusinessPro` subfolder.
  ///   • Desktop → the OS Downloads directory via path_provider.
  ///   • Fallback (e.g. Downloads unavailable) → app documents/backups.
  Future<String> backupToLocal(String businessName) async {
    final fileName = await createBackupFileName(businessName);
    final dir = await _browsableBackupDir();
    try {
      final file = await _snapshotTo(p.join(dir.path, fileName));
      await _markBackedUp();
      return file.path;
    } on FileSystemException {
      // Some devices deny direct writes to the public Downloads path. Fall back
      // to the app documents folder so the backup still succeeds (it's just
      // less visible); the caller surfaces the returned path either way.
      final docs = await getApplicationDocumentsDirectory();
      final fallback = Directory(p.join(docs.path, 'BusinessPro', 'backups'));
      await fallback.create(recursive: true);
      final file = await _snapshotTo(p.join(fallback.path, fileName));
      await _markBackedUp();
      return file.path;
    }
  }

  /// Resolves a directory the user can actually browse to, creating it if
  /// needed. See [backupToLocal] for the platform preference order.
  Future<Directory> _browsableBackupDir() async {
    if (Platform.isAndroid) {
      // The public Downloads path is a stable, well-known location that file
      // managers and the document picker both surface. Writing here needs no
      // runtime permission on Android 10+ for files the app creates.
      final downloads = Directory('/storage/emulated/0/Download');
      if (await downloads.exists()) {
        final dir = Directory(p.join(downloads.path, 'BusinessPro'));
        await dir.create(recursive: true);
        return dir;
      }
    } else {
      // Windows / macOS / Linux: the real Downloads folder.
      final downloads = await getDownloadsDirectory();
      if (downloads != null) {
        final dir = Directory(p.join(downloads.path, 'BusinessPro'));
        await dir.create(recursive: true);
        return dir;
      }
    }
    // Last resort: app documents (still works, just less visible).
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'BusinessPro', 'backups'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Snapshots the DB to a temp file and opens the system share sheet
  /// (WhatsApp / Email / Drive / Files …).
  Future<void> shareBackup(String businessName) async {
    final fileName = await createBackupFileName(businessName);
    final tmp = await getTemporaryDirectory();
    final file = await _snapshotTo(p.join(tmp.path, fileName));
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], text: 'BusinessPro Backup'),
    );
    await _markBackedUp();
  }

  // ── Cloud backup (delegated to the provider) ───────────────────────────────

  /// Snapshots the DB and uploads it via the configured provider.
  Future<void> backupToCloud(String businessName) async {
    final fileName = await createBackupFileName(businessName);
    final tmp = await getTemporaryDirectory();
    final file = await _snapshotTo(p.join(tmp.path, fileName));
    await provider.upload(file, fileName);
    await _markBackedUp();
  }

  Future<List<BackupRecord>> listCloudBackups() => provider.listBackups();

  Future<void> deleteCloudBackup(String backupId) =>
      provider.deleteBackup(backupId);

  /// Downloads [backupId] from the cloud over the live DB file, then re-opens.
  Future<void> restoreFromCloud(String backupId) async {
    final dbPath = await DatabaseHelper.databasePath();
    await DatabaseHelper.close();
    await _clearSidecars(dbPath);
    await provider.download(backupId, dbPath);
    await DatabaseHelper.reopen();
  }

  // ── Restore from a local .db file ──────────────────────────────────────────

  /// Replaces the live database with the file at [sourcePath], then re-opens
  /// the connection. The DB is closed and its WAL/SHM sidecars removed first so
  /// the swap is clean (critical on Windows, which locks the open file).
  ///
  /// Validates that [sourcePath] is a real SQLite file before clobbering data;
  /// throws [BackupException] if not.
  Future<void> restoreFromFile(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw const BackupException('Selected file no longer exists.');
    }
    if (!await _looksLikeSqlite(source)) {
      throw const BackupException(
          'That file is not a BusinessPro database backup.');
    }

    final dbPath = await DatabaseHelper.databasePath();
    await DatabaseHelper.close();
    await _clearSidecars(dbPath);
    await source.copy(dbPath);
    // Confirm the restored file opens; surfaces corruption before the user
    // navigates away thinking it worked.
    await DatabaseHelper.reopen();
  }

  /// Records "a backup just succeeded" so the backup-reminder notification can
  /// measure how long it's been. Called by the local / cloud / share paths.
  Future<void> _markBackedUp() => DatabaseHelper.setSetting(
      AppStrings.kLastBackupAt, DateTime.now().toIso8601String());

  // ── helpers ────────────────────────────────────────────────────────────────

  /// Removes the WAL / SHM sidecar files next to [dbPath] so a freshly copied
  /// main database isn't reinterpreted against a stale journal.
  Future<void> _clearSidecars(String dbPath) async {
    for (final suffix in const ['-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {
          // Best effort — a leftover sidecar is checkpointed away on reopen.
        }
      }
    }
  }

  /// Cheap sanity check: SQLite files start with the 16-byte magic header
  /// "SQLite format 3\0". Guards restore against arbitrary picked files.
  Future<bool> _looksLikeSqlite(File file) async {
    try {
      final raf = await file.open();
      try {
        final header = await raf.read(16);
        const magic = 'SQLite format 3\x00';
        if (header.length < 16) return false;
        for (var i = 0; i < 16; i++) {
          if (header[i] != magic.codeUnitAt(i)) return false;
        }
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }
}

/// A user-facing backup/restore failure (bad file, missing source, etc.).
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);
  @override
  String toString() => message;
}
