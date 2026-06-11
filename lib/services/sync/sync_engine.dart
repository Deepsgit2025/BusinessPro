// The engine's constructor maps public named params to private fields by
// design (it's the public construction API), which trips prefer_initializing_formals.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart' show MissingPluginException;

import '../../core/constants/app_strings.dart';
import '../../core/database/database_helper.dart';
import 'auth_service.dart';
import 'drive_service.dart';
import 'sync_models.dart';
import 'sync_repository.dart';

/// The semi-smart, row-level merge engine.
///
/// One [sync] run: confirm internet + a valid Drive token, upload this device's
/// unsynced changes to `<deviceType>_changes.json`, download the *other*
/// device's file, and merge it row-by-row keyed on `uuid` with latest-`updatedAt`
/// wins. No data is ever deleted by a conflict — the losing side simply keeps its
/// newer copy, which it re-uploads next run.
///
/// Every public path is wrapped so a sync failure can never crash the app: the
/// scheduler calls [sync] inside its own try/catch too, and [sync] returns a
/// status rather than throwing for the expected "offline / not linked" cases.
class SyncEngine {
  final DriveService _drive;
  final SyncRepository _repo;
  final AuthService _auth;
  final String _deviceId;
  final String _deviceType; // 'android' | 'windows'

  SyncEngine({
    required DriveService drive,
    required SyncRepository repo,
    required AuthService auth,
    required String deviceId,
    required String deviceType,
  })  : _drive = drive,
        _repo = repo,
        _auth = auth,
        _deviceId = deviceId,
        _deviceType = deviceType;

  static const _androidFile = 'android_changes.json';
  static const _windowsFile = 'windows_changes.json';

  String get _myFile => _deviceType == 'android' ? _androidFile : _windowsFile;
  String get _theirFile =>
      _deviceType == 'android' ? _windowsFile : _androidFile;

  // ── MAIN ENTRY ───────────────────────────────────────────────────────────

  /// Runs a full two-way sync. Never throws — returns a [SyncResult] whose
  /// [SyncResult.status] reflects offline / not-linked / failed states.
  Future<SyncResult> sync() async {
    try {
      if (!await _hasInternet()) return SyncResult.noInternet();

      // Obtain a fresh token. On Android this refreshes silently; on Windows it
      // returns the handed-off token (or null once it expires → re-link needed).
      final token = await _auth.getAccessToken();
      if (token == null || token.isEmpty) return SyncResult.notLinked();
      _drive.setToken(token);

      final state = await _repo.getSyncState();
      var since = DateTime.tryParse(
          (state['last_upload_at'] as String?) ?? '');

      // Self-heal: if we think we've already uploaded (since != null) but our
      // changes file isn't actually on Drive, a prior "upload" didn't persist.
      // Reset the high-water mark so every row re-exports this run.
      if (since != null && !await _drive.fileExists(_myFile)) {
        since = null;
        await _repo.updateLastUploadTime(DateTime.fromMillisecondsSinceEpoch(0));
      }

      // 1 + 2. Gather and upload local changes.
      final local = await _repo.getLocalChanges(
        deviceId: _deviceId,
        deviceType: _deviceType,
        since: since,
      );
      final uploadStartedAt = DateTime.now();
      if (local.hasRecords) {
        await _uploadChanges(local);
      }

      // 3. Download the other device's changes.
      final remote = await _downloadRemoteChanges();

      // 4. Merge.
      var result = await _mergeChanges(remote);

      // 5. Mark local rows synced + advance the upload high-water mark. We use
      // the pre-upload timestamp so any write that landed *during* the upload is
      // picked up next run rather than skipped.
      if (local.hasRecords) {
        await _markAllSynced(local);
        await _repo.updateLastUploadTime(uploadStartedAt);
      }
      if (remote != null) {
        await _repo.updateLastDownloadTime(DateTime.now());
      }
      await _repo.updateLastSyncTime(DateTime.now());
      if (remote != null) await _repo.touchDevice(remote.deviceId);

      // 6. Log + attach the upload count for the settings line.
      result = SyncResult(
        inserted: result.inserted,
        updated: result.updated,
        conflicts: result.conflicts,
        uploaded: local.recordCount,
        deviceSource: result.deviceSource,
        status: SyncStatus.ok,
      );
      await _logSync(result);

      return result;
    } on DriveException catch (e) {
      // Token rejected → surface as not-linked so the UI prompts a re-link.
      if (e.isAuthError) return SyncResult.notLinked();
      await _logFailure(e.toString());
      return SyncResult.failed(e.toString());
    } catch (e) {
      await _logFailure(e.toString());
      return SyncResult.failed(e.toString());
    }
  }

  // ── UPLOAD ─────────────────────────────────────────────────────────────────

  Future<void> _uploadChanges(ChangeSet changes) async {
    await _drive.uploadFile(_myFile, jsonEncode(changes.toJson()));
  }

  // ── DOWNLOAD ─────────────────────────────────────────────────────────────

  Future<ChangeSet?> _downloadRemoteChanges() async {
    final content = await _drive.downloadFile(_theirFile);
    if (content == null || content.trim().isEmpty) return null;
    try {
      return ChangeSet.fromJson(
          jsonDecode(content) as Map<String, dynamic>);
    } catch (_) {
      // A malformed/partial file shouldn't abort the whole sync.
      return null;
    }
  }

  // ── MERGE ────────────────────────────────────────────────────────────────

  /// Merges in dependency order so a parent (transaction) is inserted before its
  /// children (transaction_items). Within a table, latest-wins per record.
  Future<SyncResult> _mergeChanges(ChangeSet? remote) async {
    if (remote == null) return SyncResult.nothingToMerge();

    var inserted = 0, updated = 0, conflicts = 0;

    // Parents first, then children, then everything else.
    const order = [
      'expense_categories',
      'item_categories',
      'accounts',
      'parties',
      'items',
      'item_units',
      'transactions',
      'transaction_items',
      'payments',
    ];

    for (final table in order) {
      final records = remote.byTable[table];
      if (records == null || records.isEmpty) continue;
      for (final record in records) {
        final action = await _mergeRecord(table, record);
        switch (action) {
          case MergeAction.inserted:
            inserted++;
          case MergeAction.updated:
            updated++;
          case MergeAction.conflict:
            conflicts++;
          case MergeAction.skipped:
            break;
        }
      }
    }

    return SyncResult(
      inserted: inserted,
      updated: updated,
      conflicts: conflicts,
      deviceSource: remote.deviceType,
    );
  }

  /// Merges one remote record into [table]: insert if new, overwrite if the
  /// remote copy is strictly newer, otherwise keep local (a conflict the local
  /// side wins). Child rows whose parent hasn't been inserted yet are skipped.
  Future<MergeAction> _mergeRecord(String table, SyncRecord remote) async {
    if (!await _repo.canResolveParents(table, remote.data)) {
      return MergeAction.skipped;
    }

    final local = await _repo.findByUuid(table, remote.uuid);

    if (local == null) {
      await _repo.insertFromSync(table, remote.data);
      return MergeAction.inserted;
    }

    final localUpdatedAt = _localUpdatedAt(local);
    if (remote.updatedAt.isAfter(localUpdatedAt)) {
      await _repo.updateFromSync(table, remote.uuid, remote.data);
      return MergeAction.updated;
    }

    // Local copy is newer or equal → keep it (it re-uploads next run).
    return MergeAction.conflict;
  }

  /// The local row's effective updated-at for conflict comparison, mirroring the
  /// expressions [SyncRepository] uses when exporting.
  DateTime _localUpdatedAt(Map<String, dynamic> row) {
    final raw = (row['updated_at'] as String?) ??
        (row['created_at'] as String?) ??
        '1970-01-01';
    return DateTime.tryParse(raw) ?? DateTime.fromMillisecondsSinceEpoch(0);
  }

  // ── MARK SYNCED ────────────────────────────────────────────────────────────

  Future<void> _markAllSynced(ChangeSet changes) async {
    for (final entry in changes.byTable.entries) {
      final uuids = entry.value.map((r) => r.uuid).toList();
      await _repo.markSynced(entry.key, uuids);
    }
  }

  // ── LOGGING ──────────────────────────────────────────────────────────────

  Future<void> _logSync(SyncResult result) async {
    if (result.hasChanges) {
      await _repo.insertSyncLog(SyncLog(
        syncType: result.conflicts > 0 ? 'conflict' : 'merge',
        recordsCount: result.inserted + result.updated,
        deviceSource: result.deviceSource,
        description: _describe(result),
        syncedAt: DateTime.now(),
      ));
    }
    await DatabaseHelper.setSetting(
        AppStrings.kLastBackupAt, DateTime.now().toIso8601String());
  }

  Future<void> _logFailure(String message) async {
    try {
      await _repo.insertSyncLog(SyncLog(
        syncType: 'merge',
        description: 'Sync could not complete. Will retry automatically.',
        syncedAt: DateTime.now(),
        // Failures are not surfaced as unread badges (they're transient); mark
        // read so the bell doesn't nag about a blip that the next run fixes.
        isRead: true,
      ));
    } catch (_) {/* never let logging crash a failed sync */}
  }

  String _describe(SyncResult r) {
    final src = r.deviceSource.isEmpty ? 'other device' : r.deviceSource;
    final parts = <String>[];
    if (r.inserted > 0) {
      parts.add('${r.inserted} new record${r.inserted == 1 ? '' : 's'} from $src');
    }
    if (r.updated > 0) {
      parts.add('${r.updated} record${r.updated == 1 ? '' : 's'} updated from $src');
    }
    if (r.conflicts > 0) {
      parts.add(
          '${r.conflicts} conflict${r.conflicts == 1 ? '' : 's'} resolved (latest edit kept)');
    }
    return parts.join(', ');
  }

  // ── HELPERS ──────────────────────────────────────────────────────────────

  Future<bool> _hasInternet() async {
    try {
      final results = await Connectivity().checkConnectivity();
      // connectivity_plus 6.x returns a list; "none" only when the list is just
      // [none]. A reported interface doesn't guarantee reachability, but it's a
      // cheap pre-filter — the actual Drive call surfaces a real outage.
      return !results.every((r) => r == ConnectivityResult.none);
    } on MissingPluginException {
      // Plugin not available on this platform build → assume online and let the
      // network call decide.
      return true;
    } catch (_) {
      return true;
    }
  }
}
