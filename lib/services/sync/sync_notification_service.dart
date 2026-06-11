import 'sync_models.dart';
import 'sync_repository.dart';

/// Read-side facade over the `sync_log` table for the dashboard bell and the
/// sync activity panel. All it does is wrap [SyncRepository] in intent-revealing
/// methods the UI providers call.
class SyncNotificationService {
  final SyncRepository _repo;
  SyncNotificationService(this._repo);

  /// Unread sync-log entries — feeds the bell badge count.
  Future<int> getUnreadCount() => _repo.countUnreadLogs();

  /// Recent sync activity, newest first.
  Future<List<SyncLog>> getLogs({int limit = 20}) =>
      _repo.getSyncLogs(limit: limit);

  /// Clears the unread badge.
  Future<void> markAllRead() => _repo.markAllLogsRead();
}
