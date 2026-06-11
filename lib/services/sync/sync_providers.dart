import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_strings.dart';
import '../../core/database/database_helper.dart';
import 'auth_service.dart';
import 'drive_service.dart';
import 'sync_engine.dart';
import 'sync_models.dart';
import 'sync_notification_service.dart';
import 'sync_repository.dart';
import 'sync_scheduler.dart';

/// Composition root for Phase 5 sync — wires the services together and exposes
/// the state the UI watches (link status, last-sync time, unsynced count, and
/// the sync-activity badge).

// ── Singleton services ───────────────────────────────────────────────────────

final syncRepositoryProvider = Provider((_) => SyncRepository());
final driveServiceProvider = Provider((_) => DriveService());
final authServiceProvider = Provider((_) => AuthService());

final syncNotificationServiceProvider = Provider(
  (ref) => SyncNotificationService(ref.read(syncRepositoryProvider)),
);

/// This device's type, derived from the platform. Android is the primary
/// (Google login) device; everything else is treated as the Windows secondary.
final deviceTypeProvider = Provider<String>((_) {
  return Platform.isAndroid ? 'android' : 'windows';
});

/// This device's stable sync id (persisted; also read by the DB insert
/// triggers). Resolved once at startup via [ensureDeviceRegistered].
final deviceIdProvider = StateProvider<String>((_) => '');

/// The live [SyncEngine], rebuilt if its inputs change. Returns null until the
/// device id is known (set during startup).
final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final deviceId = ref.watch(deviceIdProvider);
  if (deviceId.isEmpty) return null;
  return SyncEngine(
    drive: ref.read(driveServiceProvider),
    repo: ref.read(syncRepositoryProvider),
    auth: ref.read(authServiceProvider),
    deviceId: deviceId,
    deviceType: ref.read(deviceTypeProvider),
  );
});

// ── Link / connection status ─────────────────────────────────────────────────

/// Whether this device can sync: Android needs a signed-in Google account;
/// Windows needs a non-expired handed-off token.
final isLinkedProvider = FutureProvider<bool>((ref) async {
  ref.watch(syncStateRefreshProvider);
  return ref.read(authServiceProvider).isSignedIn();
});

/// The connected Google account email (Android), or empty.
final syncAccountEmailProvider = FutureProvider<String>((ref) async {
  ref.watch(syncStateRefreshProvider);
  return ref.read(authServiceProvider).accountEmail();
});

/// A bumpable token: increment to force the status providers above (and the
/// settings screen) to re-read after a sign-in / link / sync.
final syncStateRefreshProvider = StateProvider<int>((_) => 0);

/// Last successful sync time, or null if never.
final lastSyncAtProvider = FutureProvider<DateTime?>((ref) async {
  ref.watch(syncStateRefreshProvider);
  final state = await DatabaseHelper.syncState();
  return DateTime.tryParse((state['last_sync_at'] as String?) ?? '');
});

/// Count of local rows not yet uploaded.
final unsyncedCountProvider = FutureProvider<int>((ref) async {
  ref.watch(syncStateRefreshProvider);
  final state = await DatabaseHelper.syncState();
  final since = DateTime.tryParse((state['last_upload_at'] as String?) ?? '');
  return ref.read(syncRepositoryProvider).unsyncedCount(since);
});

/// Devices linked to this account (for the settings list).
final linkedDevicesProvider = FutureProvider<List<SyncDevice>>((ref) async {
  ref.watch(syncStateRefreshProvider);
  return ref.read(syncRepositoryProvider).getDevices();
});

// ── Sync-activity (bell) ─────────────────────────────────────────────────────

/// Unread sync-log entries → drives the dashboard bell badge for sync activity.
final syncUnreadCountProvider = FutureProvider<int>((ref) async {
  ref.watch(syncStateRefreshProvider);
  return ref.read(syncNotificationServiceProvider).getUnreadCount();
});

/// Recent sync-activity log entries for the activity panel.
final syncLogsProvider = FutureProvider<List<SyncLog>>((ref) async {
  ref.watch(syncStateRefreshProvider);
  return ref.read(syncNotificationServiceProvider).getLogs();
});

// ── Scheduler ────────────────────────────────────────────────────────────────

/// The app-lifetime [SyncScheduler]. It calls the live engine (a no-op result
/// while the device id isn't resolved yet) and bumps the refresh token whenever
/// a background sync changed something, so the UI updates silently.
final syncSchedulerProvider = Provider<SyncScheduler>((ref) {
  final scheduler = SyncScheduler(
    runSync: () async {
      final engine = ref.read(syncEngineProvider);
      if (engine == null) return SyncResult.notLinked();
      return engine.sync();
    },
    onChanged: (_) => refreshSyncState(ref),
  );
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

// ── Startup + actions ────────────────────────────────────────────────────────

/// Resolves and registers this device's id at app start. Also registers a
/// `devices` row for *this* device so it shows in the settings list. Idempotent.
/// Called from [MainShell] with a [WidgetRef].
Future<String> ensureDeviceRegistered(WidgetRef ref) async {
  final id = await DatabaseHelper.getOrCreateDeviceId();
  ref.read(deviceIdProvider.notifier).state = id;

  final type = ref.read(deviceTypeProvider);
  await ref.read(syncRepositoryProvider).upsertDevice(SyncDevice(
        deviceId: id,
        deviceName: _localDeviceName(type),
        deviceType: type,
        lastSeen: DateTime.now(),
      ));
  return id;
}

String _localDeviceName(String type) =>
    type == 'android' ? 'This Android device' : 'This Windows PC';

/// Bumps the refresh token so all status providers re-read.
void refreshSyncState(Ref ref) {
  ref.read(syncStateRefreshProvider.notifier).state++;
}

/// Convenience for `WidgetRef` callers (screens).
void refreshSyncStateW(WidgetRef ref) {
  ref.read(syncStateRefreshProvider.notifier).state++;
}

/// Forgets the connected account / token. On Android this signs out of Google;
/// on Windows it just clears the cached token. Local data is untouched. Takes a
/// [WidgetRef] since it's invoked from screens.
Future<void> disconnectSync(WidgetRef ref) async {
  await ref.read(authServiceProvider).signOut();
  ref.read(driveServiceProvider).clear();
  await DatabaseHelper.setSetting(AppStrings.kDriveAccessToken, '');
  refreshSyncStateW(ref);
}
