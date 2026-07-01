// First migration test — proves the harness can drive the REAL migration code
// against a controlled database and that a freshly built current-version DB
// reports the expected schema version.
//
// Invariant I1.1: a DB built at the current schema version via the real
// _onCreate path has PRAGMA user_version == DatabaseHelper.schemaVersion (16).

import 'package:business_pro/core/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

import 'migration_harness.dart';

void main() {
  setUpAll(initMigrationHarness);
  tearDown(disposeOpenedDatabases);

  test('I1.1 — fresh DB at current version reports matching user_version', () async {
    final db = await openAtVersion(currentSchemaVersion);
    addTearDown(db.close);

    final userVersion = await readUserVersion(db);

    expect(userVersion, currentSchemaVersion);
    expect(userVersion, DatabaseHelper.schemaVersion);
    expect(userVersion, 16); // pinned to the documented current version
  });
}
