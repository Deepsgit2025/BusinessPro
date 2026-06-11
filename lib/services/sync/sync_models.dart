/// Data model for the Phase 5 Drive sync: the JSON envelope a device uploads
/// (a [ChangeSet] of [SyncRecord]s), the in-memory result of a merge
/// ([SyncResult]), and the value types backing the sync log + device registry.
///
/// A [ChangeSet] is serialised to `<deviceType>_changes.json` on Drive. The
/// other device downloads it and merges each [SyncRecord] by `uuid`, keeping the
/// latest `updatedAt` on conflict.
library;

/// One changed row, identified across devices by [uuid]. [data] is the full
/// column map exactly as stored locally (minus the local integer `id`, which is
/// meaningless on the other device). [updatedAt] drives latest-wins conflict
/// resolution.
class SyncRecord {
  final String uuid;
  final String operation; // 'upsert' | 'delete'
  final Map<String, dynamic> data;
  final DateTime updatedAt;
  final String? deviceId;

  const SyncRecord({
    required this.uuid,
    required this.data,
    required this.updatedAt,
    this.operation = 'upsert',
    this.deviceId,
  });

  Map<String, dynamic> toJson() => {
        'uuid': uuid,
        'operation': operation,
        'data': data,
        'updated_at': updatedAt.toIso8601String(),
        'device_id': deviceId,
      };

  factory SyncRecord.fromJson(Map<String, dynamic> json) => SyncRecord(
        uuid: json['uuid'] as String,
        operation: (json['operation'] as String?) ?? 'upsert',
        data: Map<String, dynamic>.from(json['data'] as Map),
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        deviceId: json['device_id'] as String?,
      );
}

/// The full set of one device's unsynced changes, grouped by table. Serialised
/// to a single JSON file on Drive. Field names mirror the table names so the
/// merge loop can iterate generically via [byTable].
class ChangeSet {
  final String deviceId;
  final String deviceType; // 'android' | 'windows'
  final int businessId;
  final DateTime exportedAt;
  final Map<String, List<SyncRecord>> byTable;

  /// The business profile (businesses row id=1) as exported by Android, the
  /// source of truth for it. Android always populates this; Windows always
  /// applies it verbatim (Android wins). Null when the exporter is Windows.
  final Map<String, dynamic>? businessProfile;

  const ChangeSet({
    required this.deviceId,
    required this.deviceType,
    required this.businessId,
    required this.exportedAt,
    required this.byTable,
    this.businessProfile,
  });

  /// True when at least one table carries a record.
  bool get hasRecords => byTable.values.any((l) => l.isNotEmpty);

  /// Total record count across all tables.
  int get recordCount =>
      byTable.values.fold(0, (sum, list) => sum + list.length);

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'device_type': deviceType,
        'business_id': businessId,
        'exported_at': exportedAt.toIso8601String(),
        'business_profile': businessProfile,
        'tables': {
          for (final entry in byTable.entries)
            entry.key: entry.value.map((r) => r.toJson()).toList(),
        },
      };

  factory ChangeSet.fromJson(Map<String, dynamic> json) {
    final tables = (json['tables'] as Map?) ?? const {};
    return ChangeSet(
      deviceId: (json['device_id'] as String?) ?? '',
      deviceType: (json['device_type'] as String?) ?? 'unknown',
      businessId: (json['business_id'] as int?) ?? 1,
      exportedAt: DateTime.tryParse(json['exported_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      businessProfile: (json['business_profile'] as Map?) == null
          ? null
          : Map<String, dynamic>.from(json['business_profile'] as Map),
      byTable: {
        for (final entry in tables.entries)
          entry.key as String: ((entry.value as List?) ?? const [])
              .map((e) => SyncRecord.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList(),
      },
    );
  }
}

/// What happened when a remote [ChangeSet] was merged locally.
class SyncResult {
  final int inserted;
  final int updated;
  final int conflicts; // local kept (remote was older)
  final int uploaded; // local records pushed this run
  final String deviceSource; // who the merged changes came from
  final SyncStatus status;

  /// Raw failure detail when [status] == failed — surfaced in the manual-sync
  /// toast so a misconfiguration (Drive 403, etc.) is visible rather than a
  /// generic "Sync failed".
  final String? errorMessage;

  const SyncResult({
    this.inserted = 0,
    this.updated = 0,
    this.conflicts = 0,
    this.uploaded = 0,
    this.deviceSource = '',
    this.status = SyncStatus.ok,
    this.errorMessage,
  });

  factory SyncResult.noInternet() =>
      const SyncResult(status: SyncStatus.noInternet);
  factory SyncResult.notLinked() =>
      const SyncResult(status: SyncStatus.notLinked);
  factory SyncResult.nothingToMerge({int uploaded = 0}) =>
      SyncResult(uploaded: uploaded, status: SyncStatus.ok);
  factory SyncResult.failed([String? errorMessage]) =>
      SyncResult(status: SyncStatus.failed, errorMessage: errorMessage);

  /// Whether the merge changed any local data (drives whether we log + badge).
  bool get hasChanges => inserted > 0 || updated > 0;

  /// Whether the run did anything at all worth noting.
  bool get didSomething => hasChanges || uploaded > 0;
}

enum SyncStatus { ok, noInternet, notLinked, failed }

/// What [SyncEngine._mergeRecord] decided for a single row.
enum MergeAction { inserted, updated, conflict, skipped }

/// One row of the sync activity log, surfaced through the dashboard bell.
class SyncLog {
  final int? id;
  final String syncType; // 'upload' | 'download' | 'merge' | 'conflict'
  final String? tableName;
  final int recordsCount;
  final String? deviceSource; // 'android' | 'windows'
  final String? description;
  final DateTime syncedAt;
  final bool isRead;

  const SyncLog({
    this.id,
    required this.syncType,
    this.tableName,
    this.recordsCount = 0,
    this.deviceSource,
    this.description,
    required this.syncedAt,
    this.isRead = false,
  });

  Map<String, dynamic> toMap() => {
        'sync_type': syncType,
        'table_name': tableName,
        'records_count': recordsCount,
        'device_source': deviceSource,
        'description': description,
        'synced_at': syncedAt.toIso8601String(),
        'is_read': isRead ? 1 : 0,
      };

  factory SyncLog.fromMap(Map<String, dynamic> m) => SyncLog(
        id: m['id'] as int?,
        syncType: (m['sync_type'] as String?) ?? 'merge',
        tableName: m['table_name'] as String?,
        recordsCount: (m['records_count'] as int?) ?? 0,
        deviceSource: m['device_source'] as String?,
        description: m['description'] as String?,
        syncedAt: DateTime.tryParse(m['synced_at'] as String? ?? '') ??
            DateTime.now(),
        isRead: ((m['is_read'] as int?) ?? 0) == 1,
      );
}

/// A device linked to this account (this one or the paired one).
class SyncDevice {
  final int? id;
  final String deviceId;
  final String? deviceName;
  final String deviceType; // 'android' | 'windows'
  final DateTime? linkedAt;
  final DateTime? lastSeen;

  const SyncDevice({
    this.id,
    required this.deviceId,
    this.deviceName,
    required this.deviceType,
    this.linkedAt,
    this.lastSeen,
  });

  factory SyncDevice.fromMap(Map<String, dynamic> m) => SyncDevice(
        id: m['id'] as int?,
        deviceId: (m['device_id'] as String?) ?? '',
        deviceName: m['device_name'] as String?,
        deviceType: (m['device_type'] as String?) ?? 'android',
        linkedAt: DateTime.tryParse(m['linked_at'] as String? ?? ''),
        lastSeen: DateTime.tryParse(m['last_seen'] as String? ?? ''),
      );
}
