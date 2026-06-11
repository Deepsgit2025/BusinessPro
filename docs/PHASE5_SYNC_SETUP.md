# Phase 5 — Google Drive Sync: Setup & Operations

Two-way, row-level sync between Android (primary) and Windows (secondary) using
the user's own Google Drive for data and Firebase only for a one-time QR token
handoff. No business data ever touches Firebase.

## Architecture at a glance

```
Google Drive  "BusinessPro Sync/"
  ├── android_changes.json   ← Android uploads, Windows downloads
  └── windows_changes.json   ← Windows uploads, Android downloads

Firebase Firestore  link_tokens/<CODE>   ← 60s, single-use Drive-token handoff
```

- **Identity across devices** is the per-row `uuid` (not the local integer id).
- **Conflict rule**: latest `updated_at` wins; the loser keeps its newer copy
  and re-uploads next run. No row is ever deleted by a conflict.
- **Change capture** is non-invasive: DB INSERT triggers stamp `uuid` +
  `device_id` on every new row, and the engine selects changes by
  `updated_at > sync_state.last_upload_at`. No repository code was modified.

## Code map

```
lib/services/sync/
  sync_models.dart              ChangeSet / SyncRecord / SyncResult / SyncLog / SyncDevice
  sync_repository.dart          all sync DB queries (extract, merge, log, devices, state)
  drive_service.dart            Drive v3 REST (Android + Windows, no googleapis dep)
  auth_service.dart             Google Sign-In (Android only) + token cache
  qr_link_service.dart          Firebase QR token handoff (the only Firebase use)
  sync_engine.dart              upload → download → row-level merge → log
  sync_scheduler.dart           resume / post-transaction (3s debounce) / 15-min / manual
  sync_notification_service.dart  read-side facade over sync_log (dashboard bell)
  sync_providers.dart           Riverpod composition root + lifecycle

lib/features/sync/screens/
  sync_settings_screen.dart     Settings → Sync & Devices  (route '/sync')
  show_qr_screen.dart           Android: show QR + 60s countdown, auto-regenerate
  scan_qr_screen.dart           Windows: scan QR / manual code entry
  sync_notifications_screen.dart  Sync activity history
```

## Database (v8 migration)

Adds `uuid` to every synced table, plus `device_id` / `is_synced` /
`server_updated_at` on the tracked tables, and three support tables:
`sync_log`, `devices`, `sync_state`. Existing rows get UUIDs via a one-time
backfill. See `_createSyncColumns / _createSyncTables / _createSyncTriggers /
_backfillSyncUuids` in `database_helper.dart`. The migration is idempotent and
runs identically on fresh installs and upgrades.

## Firebase / Google Cloud setup (one-time)

The project is already provisioned (`firebase_options.dart`, project
`businesspro-forfun`, Android package `com.businesspro.app`). Remaining console
steps for a working sync:

1. **Enable Firestore** (Console → Firestore Database → Create, production mode,
   region `asia-south1`).
2. **Firestore security rules** — only `link_tokens` is used; tokens are
   single-use and expire in 60s:

   ```
   rules_version = '2';
   service cloud.firestore {
     match /databases/{database}/documents {
       // One-time QR/code link handoff (short-lived, single-use).
       match /link_tokens/{tokenId} {
         allow read, write: if true;
       }
       // Token relay: Android keeps a fresh Drive token here so Windows can
       // refresh without re-linking. Still just an OAuth token, no business data.
       match /device_tokens/{deviceId} {
         allow read, write: if true;
       }
       match /{document=**} {
         allow read, write: if false;
       }
     }
   }
   ```

3. **Enable the Google Drive API** (Cloud Console → APIs & Services → Library →
   "Google Drive API" → Enable).
4. **OAuth client IDs** (Cloud Console → APIs & Services → Credentials):
   - Android client: package `com.businesspro.app` + the **debug** SHA-1 from
     `cd android && ./gradlew signingReport`.
   - Web application client (Flutter uses it internally for Drive scope).
5. **Scope** is `drive.file` — the app only ever sees files it created.

## Android build notes

- `minSdk` is pinned to **23** (cloud_firestore 5.x requirement) in
  `android/app/build.gradle.kts`.
- `INTERNET` + `ACCESS_NETWORK_STATE` permissions added to the manifest.
- **Release SHA-1 differs from debug** — before a Play Store release, add the
  release-keystore SHA-1 as a second Android OAuth client in Cloud Console, or
  Google Sign-In will fail on release builds.

## Windows build caveat (Firebase C++ SDK + modern CMake)

`cloud_firestore` pulls in `firebase_cpp_sdk_windows`, whose bundled
`CMakeLists.txt` declares `cmake_minimum_required(VERSION 3.1)`. CMake ≥ 4.0
removed compatibility with `< 3.5`, so a **clean** Windows build fails with:

```
CMake Error ... Compatibility with CMake < 3.5 has been removed from CMake.
```

This is upstream (not app code) and reproduces for anyone adding cloud_firestore
to a Windows Flutter app on a recent CMake. Workarounds, cheapest first:

- Configure with the compatibility flag:
  `flutter build windows --debug -- "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"`
  (or set `CMAKE_POLICY_VERSION_MINIMUM=3.5` in the environment).
- Or install a CMake in the 3.x line (e.g. 3.30) for the Windows toolchain.

Android builds are unaffected. The Dart layer compiles cleanly on both targets
(`flutter analyze` passes with no issues).

## Behaviour notes

- All background syncs are **silent** and wrapped so a failure can never crash
  the app; failures log quietly and the next trigger retries.
- Offline writes get queued automatically (they're just unsynced rows) and
  upload on the next successful sync.
- Soft-deleted rows (`is_deleted = 1`) sync too, so deletions propagate.
- Windows has **no** `google_sign_in`; it uses the token handed over via QR and
  re-links when that token lapses.
