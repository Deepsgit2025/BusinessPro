import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show Database, ConflictAlgorithm;

import '../../core/database/database_helper.dart';
import 'sync_models.dart';

/// All database access for the sync engine: pulling local changes, finding /
/// inserting / updating rows by uuid during merge, and the sync log / device /
/// state bookkeeping.
///
/// Change detection is timestamp-based: a row is "unsynced" when its
/// `updated_at` is newer than `sync_state.last_upload_at` (the high-water mark
/// of the last successful upload). This needs no per-repository changes — every
/// existing insert/update already bumps `updated_at`, and the DB triggers stamp
/// `uuid`/`device_id`. transaction_items has no historical `updated_at`, so its
/// (v8-added) column is COALESCE'd to the parent transaction's timestamp.
class SyncRepository {
  static const _businessId = 1;

  /// Per-table SQL expression yielding the row's effective "updated at". Most
  /// tables have a real column; the master lists that don't fall back to a
  /// constant epoch so they upload once and then only on genuine edits (which we
  /// can't detect without a column — acceptable: these change rarely).
  // NOTE: each expression may only reference columns that actually exist on the
  // table (a missing column makes the whole export query fail to compile). Per
  // the schema in database_helper.dart:
  //   transactions/parties/items/accounts → created_at + updated_at
  //   item_categories/payments            → created_at only
  //   item_units/expense_categories       → NO timestamp columns
  static const _updatedAtExpr = <String, String>{
    'transactions': "COALESCE(t.updated_at, t.created_at, '1970-01-01')",
    'parties': "COALESCE(t.updated_at, t.created_at, '1970-01-01')",
    'items': "COALESCE(t.updated_at, t.created_at, '1970-01-01')",
    'accounts': "COALESCE(t.updated_at, t.created_at, '1970-01-01')",
    'item_categories': "COALESCE(t.created_at, '1970-01-01')",
    'payments': "COALESCE(t.created_at, '1970-01-01')",
    // No timestamp column at all — upload once, then only via a future edit we
    // can't timestamp (acceptable: these change rarely and are small).
    'item_units': "'1970-01-01'",
    'expense_categories': "'1970-01-01'",
    // Employee module (v14). employees has updated_at + created_at from v7; the
    // three child tables track by created_at but were given an updated_at in
    // v14 so an edited row carries a fresh latest-wins timestamp.
    'employees': "COALESCE(t.updated_at, t.created_at, '1970-01-01')",
    'attendance': "COALESCE(t.updated_at, t.created_at, '1970-01-01')",
    'salary_payments': "COALESCE(t.updated_at, t.created_at, '1970-01-01')",
    'employee_advances': "COALESCE(t.updated_at, t.created_at, '1970-01-01')",
  };

  /// Cross-table foreign keys that hold a *local integer id* and therefore mean
  /// nothing on the other device. For each, the export attaches a `_<col>_uuid`
  /// helper (the parent row's uuid) via a LEFT JOIN, and the merge resolves that
  /// uuid back to the local parent id. Self-references and the always-1
  /// business_id are intentionally excluded.
  ///   table → { localColumn: referencedTable }
  static const _foreignKeys = <String, Map<String, String>>{
    'items': {
      'category_id': 'item_categories',
    },
    'item_units': {
      'item_id': 'items',
    },
    'transactions': {
      'party_id': 'parties',
      'account_id': 'accounts',
      'category_id': 'expense_categories',
      // Self-reference: a sale links to the order/challan it converted from.
      // Must be remapped by uuid or it carries the source device's local id and
      // FK-fails (787). Nullable, so an unresolved link just drops to null.
      'linked_transaction_id': 'transactions',
    },
    'transaction_items': {
      'transaction_id': 'transactions',
      'item_id': 'items',
      'item_unit_id': 'item_units',
    },
    'payments': {
      'transaction_id': 'transactions',
      'account_id': 'accounts',
    },
    // Employee module (v14): each child holds the parent's local integer
    // employee_id, meaningless on the other device — remap via the parent's
    // uuid. business_id is always 1 (excluded, like everywhere else).
    'attendance': {
      'employee_id': 'employees',
    },
    'salary_payments': {
      'employee_id': 'employees',
    },
    'employee_advances': {
      'employee_id': 'employees',
    },
  };

  /// Foreign keys into NON-synced master tables (`units`, `tax_rates`,
  /// `payment_modes`) that are seeded identically on every device but whose
  /// integer ids may differ. These can't be remapped by uuid (the master rows
  /// have none). Instead the export attaches the parent's NATURAL KEY (e.g. a
  /// unit's short_name, a tax rate's rate) as `_<col>_nk`, and the merge resolves
  /// it to the LOCAL row with that key.
  ///   table → { localColumn: (refTable, naturalKeyColumn) }
  /// This is why a synced item previously vanished: its unit_id pointed at a
  /// row id that didn't match on the other device and the insert FK-failed.
  static const _naturalKeyFks = <String, Map<String, (String, String)>>{
    'items': {
      'unit_id': ('units', 'short_name'),
      'tax_rate_id': ('tax_rates', 'rate'),
    },
    'item_units': {
      'unit_id': ('units', 'short_name'),
    },
    'transaction_items': {
      'tax_rate_id': ('tax_rates', 'rate'),
    },
  };

  // ── LOCAL CHANGE EXTRACTION ────────────────────────────────────────────────

  /// Builds the [ChangeSet] — a COMPLETE snapshot of this device's synced rows.
  /// The changes file is idempotent (uuid-keyed, latest-wins on merge), so we
  /// always export everything rather than an incremental delta; this guarantees
  /// no row is ever dropped from the channel.
  Future<ChangeSet> getLocalChanges({
    required String deviceId,
    required String deviceType,
  }) async {
    final db = await DatabaseHelper.database;
    final byTable = <String, List<SyncRecord>>{};

    for (final table in DatabaseHelper.syncedTables) {
      byTable[table] = await _allRows(db, table);
    }

    // Business profile: Android is the source of truth, so only Android exports
    // it (always the full current row). Windows exports null so it never
    // clobbers Android.
    Map<String, dynamic>? profile;
    if (deviceType == 'android') {
      final biz = await DatabaseHelper.getBusiness();
      if (biz != null) {
        profile = Map<String, dynamic>.from(biz)..remove('id');
      }
    }

    return ChangeSet(
      businessProfile: profile,
      deviceId: deviceId,
      deviceType: deviceType,
      businessId: _businessId,
      exportedAt: DateTime.now(),
      byTable: byTable,
    );
  }

  Future<List<SyncRecord>> _allRows(Database db, String table) async {
    // transaction_items has no timestamp of its own — track its parent's so an
    // edited bill re-uploads its lines. Other tables use their own column.
    final isTxnItems = table == 'transaction_items';
    final expr = isTxnItems
        ? "COALESCE(parent.updated_at, parent.created_at, '1970-01-01')"
        : (_updatedAtExpr[table] ?? "'1970-01-01'");

    // Build `_<col>_uuid` helper selects + the JOINs that resolve them.
    final fks = _foreignKeys[table] ?? const {};
    final selects = <String>['t.*', '$expr AS _eff_updated'];
    final joins = <String>[];
    var i = 0;
    fks.forEach((col, refTable) {
      final alias = 'fk$i';
      selects.add('$alias.uuid AS _${col}_uuid');
      joins.add('LEFT JOIN $refTable $alias ON $alias.id = t.$col');
      i++;
    });

    // Natural-key helpers for FKs into seeded master tables (units/tax_rates).
    final nkFks = _naturalKeyFks[table] ?? const {};
    nkFks.forEach((col, ref) {
      final (refTable, nkCol) = ref;
      final alias = 'nk$i';
      selects.add('$alias.$nkCol AS _${col}_nk');
      joins.add('LEFT JOIN $refTable $alias ON $alias.id = t.$col');
      i++;
    });
    if (isTxnItems) {
      // Dedicated parent join for the timestamp (separate from the FK join so
      // the expression is stable even if transaction_id isn't in _foreignKeys).
      joins.add('LEFT JOIN transactions parent ON parent.id = t.transaction_id');
    }

    // The changes file is a COMPLETE, idempotent snapshot of this device's rows,
    // not an incremental delta. Earlier designs exported only is_synced=0 rows,
    // but the file is overwritten each upload — so a row uploaded once then
    // marked synced would disappear from the file before the other device read
    // it, silently dropping data. Exporting everything (uuid-keyed, latest-wins
    // on merge) makes re-seeing a row harmless and guarantees no delta is missed.
    final where = StringBuffer('t.uuid IS NOT NULL');
    final args = <Object?>[];

    final rows = await db.rawQuery(
      'SELECT ${selects.join(', ')} FROM $table t '
      '${joins.join(' ')} WHERE $where',
      args,
    );
    return rows.map((r) => _toRecord(r)).toList();
  }

  /// Converts a DB row into a [SyncRecord]. Strips the local-only `id` and the
  /// query-only `_eff_updated` helper; keeps `_txn_uuid` (transaction_items use
  /// it to re-link to the parent on the other device).
  SyncRecord _toRecord(Map<String, dynamic> row) {
    final updatedRaw = row['_eff_updated'] as String?;
    final updatedAt =
        DateTime.tryParse(updatedRaw ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0);
    final data = Map<String, dynamic>.from(row)
      ..remove('id')
      ..remove('_eff_updated')
      ..remove('is_synced')
      ..remove('server_updated_at');
    final isDeleted = (row['is_deleted'] as int?) == 1;
    return SyncRecord(
      uuid: row['uuid'] as String,
      data: data,
      updatedAt: updatedAt,
      operation: isDeleted ? 'delete' : 'upsert',
      deviceId: row['device_id'] as String?,
    );
  }

  // ── MERGE: FIND / INSERT / UPDATE BY UUID ──────────────────────────────────

  /// Overwrites the local business profile (businesses row id=1) with [profile]
  /// from Android (Android takes precedence). Returns true only if something
  /// actually changed — the caller uses this so an unchanged profile doesn't get
  /// reported as "1 updated" on every sync.
  Future<bool> applyBusinessProfile(Map<String, dynamic> profile) async {
    final db = await DatabaseHelper.database;

    // Never copy these: id is fixed; the *_counter columns are per-device
    // numbering state (copying them would corrupt Windows' own invoice/receipt
    // sequence); created_at/updated_at are local bookkeeping.
    const skip = {
      'id',
      'invoice_counter',
      'purchase_counter',
      'receipt_counter',
      'created_at',
      'updated_at',
    };

    // Only write columns that actually exist on this device's businesses table,
    // so a schema drift between devices can't make the whole update throw.
    final cols = await db.rawQuery('PRAGMA table_info(businesses)');
    final existing = cols.map((c) => c['name'] as String).toSet();

    final incoming = <String, dynamic>{};
    profile.forEach((k, v) {
      if (!skip.contains(k) && existing.contains(k)) incoming[k] = v;
    });
    if (incoming.isEmpty) return false;

    // Change detection: compare against the current row; only write the columns
    // that differ. No diff ⇒ nothing to do (and not counted as an update).
    final current = await DatabaseHelper.getBusiness() ?? const {};
    final changed = <String, dynamic>{};
    incoming.forEach((k, v) {
      if (current[k] != v) changed[k] = v;
    });
    if (changed.isEmpty) return false;

    await db.update('businesses', changed, where: 'id = 1');
    return true;
  }

  /// The local row for [uuid] in [table], or null if absent.
  Future<Map<String, dynamic>?> findByUuid(String table, String uuid) async {
    final db = await DatabaseHelper.database;
    final rows =
        await db.query(table, where: 'uuid = ?', whereArgs: [uuid], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Tables with a cross-device NATURAL identity — a uniqueness constraint that
  /// two devices can independently satisfy, producing two rows with the SAME
  /// logical key but DIFFERENT uuids. Without special handling the merge's
  /// uuid-only match would see the remote row as new and hit the local UNIQUE
  /// constraint (ConflictAlgorithm.replace would then delete the local row,
  /// losing its uuid and bouncing duplicates forever). Listing the natural-key
  /// columns lets the merge fall back to matching by them.
  ///
  /// `attendance` is UNIQUE(employee_id, date). employee_id is a FK remapped to
  /// the LOCAL id before this lookup, so we match on the local id + date.
  static const _naturalIdentity = <String, List<String>>{
    'attendance': ['employee_id', 'date'],
  };

  bool hasNaturalIdentity(String table) =>
      _naturalIdentity.containsKey(table);

  /// Finds the local row in [table] matching the natural-key columns carried by
  /// [localRow] (whose FK columns must already be remapped to local ids). Used
  /// when a uuid lookup misses but a same-key row may already exist from the
  /// other device. Returns null if the table has no natural identity or no row
  /// matches.
  Future<Map<String, dynamic>?> findByNaturalKey(
      String table, Map<String, dynamic> localRow) async {
    final keys = _naturalIdentity[table];
    if (keys == null) return null;
    // If any key column is unresolved (e.g. employee_id didn't remap), we can't
    // match — let the caller treat it as a fresh row.
    if (keys.any((k) => localRow[k] == null)) return null;
    final db = await DatabaseHelper.database;
    final where = keys.map((k) => '$k = ?').join(' AND ');
    final args = keys.map((k) => localRow[k]).toList();
    final rows =
        await db.query(table, where: where, whereArgs: args, limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// Remaps the FK columns of [data] to local ids without writing anything —
  /// used so the merge can compute a natural-key lookup (which needs the local
  /// employee_id) before deciding insert vs. update.
  Future<Map<String, dynamic>> remapForeignKeysForLookup(
          String table, Map<String, dynamic> data) =>
      _remapForeignKeys(table, Map<String, dynamic>.from(data));

  /// Inserts a remote row that doesn't exist locally. Foreign keys that
  /// reference other tables by integer id are remapped from the accompanying
  /// uuid where one is provided (see [_remapForeignKeys]); rows whose parents
  /// haven't arrived yet are skipped by the caller via [canResolveParents].
  ///
  /// [effectiveUpdatedAt] is the record's authoritative change time from the
  /// changeset. We stamp it onto the local row's `updated_at` (when that column
  /// exists) so the next merge's timestamp comparison matches and the row isn't
  /// re-"updated" on every sync. This is essential for child rows like
  /// transaction_items whose own `updated_at` is null in the payload.
  Future<void> insertFromSync(
      String table, Map<String, dynamic> data, DateTime effectiveUpdatedAt) async {
    final row = await _remapForeignKeys(table, Map<String, dynamic>.from(data));
    row.remove('id');
    row['is_synced'] = 1;
    _stampUpdatedAt(table, row, effectiveUpdatedAt);
    final db = await DatabaseHelper.database;
    await db.insert(table, row,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Overwrites the local row identified by [uuid] with newer remote data.
  Future<void> updateFromSync(String table, String uuid,
      Map<String, dynamic> data, DateTime effectiveUpdatedAt) async {
    final row = await _remapForeignKeys(table, Map<String, dynamic>.from(data));
    row..remove('id')..remove('uuid');
    row['is_synced'] = 1;
    _stampUpdatedAt(table, row, effectiveUpdatedAt);
    final db = await DatabaseHelper.database;
    await db.update(table, row, where: 'uuid = ?', whereArgs: [uuid]);
  }

  /// Overwrites the local row at [localId] with remote data AND adopts the
  /// remote [uuid]. Used for a natural-key collision (two devices independently
  /// created the same logical row with different uuids): the loser's row is
  /// rewritten to the winner's uuid + data so both devices converge on one
  /// identity instead of bouncing two rows that violate the UNIQUE constraint.
  Future<void> updateFromSyncByLocalId(String table, int localId, String uuid,
      Map<String, dynamic> data, DateTime effectiveUpdatedAt) async {
    final row = await _remapForeignKeys(table, Map<String, dynamic>.from(data));
    row.remove('id');
    row['uuid'] = uuid; // adopt the winning uuid so identities converge
    row['is_synced'] = 1;
    _stampUpdatedAt(table, row, effectiveUpdatedAt);
    final db = await DatabaseHelper.database;
    await db.update(table, row, where: 'id = ?', whereArgs: [localId]);
  }

  /// Tables that carry an `updated_at` column the merge compares against. We
  /// overwrite it with the changeset's authoritative time (stored canonically as
  /// ISO-8601) so subsequent comparisons are stable and format-independent.
  static const _hasUpdatedAt = {
    'transactions',
    'parties',
    'items',
    'accounts',
    'transaction_items',
    // Employee module (v14): all four carry updated_at (employees from v7, the
    // three children from the v14 ALTER) so the merge stamps the authoritative
    // time and the row isn't re-"updated" on every subsequent sync.
    'employees',
    'attendance',
    'salary_payments',
    'employee_advances',
  };

  void _stampUpdatedAt(
      String table, Map<String, dynamic> row, DateTime when) {
    if (_hasUpdatedAt.contains(table)) {
      row['updated_at'] = when.toIso8601String();
    }
  }

  /// True when the *structural* parent referenced by [data] already exists
  /// locally. Only the owning relationship blocks insertion (a line needs its
  /// transaction; a unit needs its item); soft references (party, account,
  /// category, item) may resolve to null without breaking the row, so they don't
  /// gate. This lets the merge defer children until their owner has been merged.
  Future<bool> canResolveParents(String table, Map<String, dynamic> data) async {
    final owner = _owningFk[table];
    if (owner == null) return true;
    final uuid = data['_${owner.$1}_uuid'] as String?;
    if (uuid == null) return true; // legacy row with no uuid pointer
    return (await findByUuid(owner.$2, uuid)) != null;
  }

  /// The owning (cascade) parent per child table: (localColumn, referencedTable).
  /// A child without its owner present must wait.
  static const _owningFk = <String, (String, String)>{
    'transaction_items': ('transaction_id', 'transactions'),
    'item_units': ('item_id', 'items'),
    // payments.transaction_id is NOT NULL → a payment must wait for its parent
    // transaction to merge first, else it fails the NOT NULL constraint (1299).
    'payments': ('transaction_id', 'transactions'),
    // Employee children: employee_id is NOT NULL + cascades off employees, so
    // each must wait for its parent employee to merge first.
    'attendance': ('employee_id', 'employees'),
    'salary_payments': ('employee_id', 'employees'),
    'employee_advances': ('employee_id', 'employees'),
  };

  /// Rewrites every uuid-carried foreign key in [data] back into the local
  /// integer id for this device, then strips the `_<col>_uuid` helpers so they
  /// aren't written as columns. A uuid that doesn't resolve locally is left as
  /// null (the reference is simply unknown here yet).
  Future<Map<String, dynamic>> _remapForeignKeys(
      String table, Map<String, dynamic> data) async {
    final fks = _foreignKeys[table] ?? const {};
    for (final entry in fks.entries) {
      final col = entry.key;
      final refTable = entry.value;
      final helper = '_${col}_uuid';
      if (!data.containsKey(helper)) continue;
      final uuid = data.remove(helper) as String?;
      if (uuid == null) {
        data[col] = null;
      } else {
        final parent = await findByUuid(refTable, uuid);
        data[col] = parent?['id'];
      }
    }

    // Resolve natural-key FKs (units / tax_rates) to LOCAL ids by matching the
    // seeded master row with the same short_name / rate.
    final nkFks = _naturalKeyFks[table] ?? const {};
    for (final entry in nkFks.entries) {
      final col = entry.key;
      final (refTable, nkCol) = entry.value;
      final helper = '_${col}_nk';
      if (!data.containsKey(helper)) continue;
      final nkValue = data.remove(helper);
      data[col] = nkValue == null
          ? null
          : await _localIdByNaturalKey(refTable, nkCol, nkValue);
    }

    // Last-resort fallback for the one hard NOT NULL master FK: item_units.unit_id
    // must reference a real unit or the insert fails. If unresolved, use the
    // parent item's base unit, else the first local unit.
    if (table == 'item_units' && data['unit_id'] == null) {
      data['unit_id'] = await _fallbackUnitId();
    }

    // Drop any stray helper fields so they can't leak into the column list.
    data.removeWhere((k, _) =>
        k.startsWith('_') && (k.endsWith('_uuid') || k.endsWith('_nk')));
    return data;
  }

  /// The local id of the master row in [refTable] whose [nkCol] equals [value],
  /// or null if none matches.
  Future<int?> _localIdByNaturalKey(
      String refTable, String nkCol, Object value) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(refTable,
        columns: ['id'], where: '$nkCol = ?', whereArgs: [value], limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  /// A safe unit id when an item_unit's unit can't be resolved (the row must
  /// have a non-null unit_id). Prefers any active unit, else any unit.
  Future<int?> _fallbackUnitId() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('units',
        columns: ['id'], orderBy: 'id', limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as int?;
  }

  // ── MARK SYNCED ────────────────────────────────────────────────────────────

  /// Flags the given uuids in [table] as synced. This is now load-bearing:
  /// change detection filters on `is_synced = 0`, so a row only leaves the
  /// upload set once this runs after a successful upload.
  Future<void> markSynced(String table, List<String> uuids) async {
    if (uuids.isEmpty) return;
    final db = await DatabaseHelper.database;
    const chunk = 400;
    for (var i = 0; i < uuids.length; i += chunk) {
      final slice = uuids.sublist(i, (i + chunk).clamp(0, uuids.length));
      final placeholders = List.filled(slice.length, '?').join(',');
      await db.rawUpdate(
        'UPDATE $table SET is_synced = 1 WHERE uuid IN ($placeholders)',
        slice,
      );
    }
  }

  /// Count of locally-unsynced rows across all tracked tables (for the settings
  /// "Unsynced records" line). Counts rows changed since the last upload.
  /// Count of locally-changed rows not yet confirmed uploaded (is_synced = 0).
  /// Drives the "Unsynced records" line; the export sends everything regardless.
  Future<int> unsyncedCount() async {
    final db = await DatabaseHelper.database;
    var total = 0;
    for (final table in DatabaseHelper.syncedTables) {
      if (table == 'transaction_items') continue;
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM $table t '
        "WHERE t.uuid IS NOT NULL AND COALESCE(t.is_synced, 0) = 0");
      total += (rows.first['c'] as int?) ?? 0;
    }
    return total;
  }

  // ── SYNC LOG ───────────────────────────────────────────────────────────────

  Future<void> insertSyncLog(SyncLog log) async {
    final db = await DatabaseHelper.database;
    await db.insert('sync_log', log.toMap());
  }

  Future<List<SyncLog>> getSyncLogs({int limit = 20}) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('sync_log',
        orderBy: 'synced_at DESC, id DESC', limit: limit);
    return rows.map(SyncLog.fromMap).toList();
  }

  Future<int> countUnreadLogs() async {
    final db = await DatabaseHelper.database;
    final rows = await db
        .rawQuery('SELECT COUNT(*) AS c FROM sync_log WHERE is_read = 0');
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> markAllLogsRead() async {
    final db = await DatabaseHelper.database;
    await db.update('sync_log', {'is_read': 1}, where: 'is_read = 0');
  }

  // ── DEVICES ──────────────────────────────────────────────────────────────

  Future<List<SyncDevice>> getDevices() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('devices', orderBy: 'linked_at ASC');
    return rows.map(SyncDevice.fromMap).toList();
  }

  /// Inserts or refreshes a device row (keyed by device_id).
  Future<void> upsertDevice(SyncDevice device) async {
    final db = await DatabaseHelper.database;
    final existing = await db.query('devices',
        where: 'device_id = ?', whereArgs: [device.deviceId], limit: 1);
    final data = {
      'device_id': device.deviceId,
      'device_name': device.deviceName,
      'device_type': device.deviceType,
      'last_seen': (device.lastSeen ?? DateTime.now()).toIso8601String(),
    };
    if (existing.isEmpty) {
      await db.insert('devices', {
        ...data,
        'linked_at': (device.linkedAt ?? DateTime.now()).toIso8601String(),
      });
    } else {
      await db.update('devices', data,
          where: 'device_id = ?', whereArgs: [device.deviceId]);
    }
  }

  Future<void> touchDevice(String deviceId) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'devices',
      {'last_seen': DateTime.now().toIso8601String()},
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
  }

  Future<void> removeDevice(String deviceId) async {
    final db = await DatabaseHelper.database;
    await db.delete('devices', where: 'device_id = ?', whereArgs: [deviceId]);
  }

  // ── SYNC STATE ─────────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> getSyncState() => DatabaseHelper.syncState();

  Future<void> updateLastUploadTime(DateTime when) =>
      DatabaseHelper.updateSyncState({'last_upload_at': when.toIso8601String()});

  Future<void> updateLastDownloadTime(DateTime when) => DatabaseHelper
      .updateSyncState({'last_download_at': when.toIso8601String()});

  Future<void> updateLastSyncTime(DateTime when) =>
      DatabaseHelper.updateSyncState({'last_sync_at': when.toIso8601String()});

  // ── RESET (fresh start on this device) ─────────────────────────────────────

  /// Wipes all synced business data on THIS device so a subsequent sync re-pulls
  /// the paired device's complete snapshot. Used to recover a device whose
  /// numbers drifted (e.g. pre-fix double-counted stock). The `businesses` row is
  /// kept (it's overwritten by the Android profile on the next sync) and the
  /// devices/sync_state link is preserved so the device stays paired.
  ///
  /// Deletes children before parents to respect foreign keys, and clears the
  /// sync-state high-water marks + activity log.
  Future<void> resetLocalData() async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      // Order matters: children/dependents first.
      const deleteOrder = [
        'payments',
        'transaction_items',
        'transactions',
        'item_units',
        'items',
        'parties',
        'expense_categories',
        'item_categories',
        'accounts',
      ];
      for (final table in deleteOrder) {
        await txn.delete(table);
      }
      await txn.delete('sync_log');
      await txn.update('sync_state', {
        'last_sync_at': null,
        'last_upload_at': null,
        'last_download_at': null,
      });
    });
  }
}
