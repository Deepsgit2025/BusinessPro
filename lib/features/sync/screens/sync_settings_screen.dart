import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_colors.dart';
import '../../../services/sync/auth_service.dart';
import '../../../services/sync/drive_service.dart';
import '../../../services/sync/sync_feedback.dart';
import '../../../services/sync/sync_models.dart';
import '../../../services/sync/sync_providers.dart';
import 'scan_qr_screen.dart';
import 'show_qr_screen.dart';

/// Settings → Sync & Devices. Hub for connecting Google Drive, linking the
/// paired device via QR, running a manual sync, and reviewing sync status.
class SyncSettingsScreen extends ConsumerWidget {
  const SyncSettingsScreen({super.key});

  bool get _isAndroid => Platform.isAndroid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final linked = ref.watch(isLinkedProvider);
    final email = ref.watch(syncAccountEmailProvider);
    final lastSync = ref.watch(lastSyncAtProvider);
    final unsynced = ref.watch(unsyncedCountProvider);
    final devices = ref.watch(linkedDevicesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sync & Devices')),
      body: RefreshIndicator(
        onRefresh: () async => refreshSyncStateW(ref),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _section('Google Drive'),
            linked.when(
              loading: () => const ListTile(
                  leading: CircularProgressIndicator(strokeWidth: 2),
                  title: Text('Checking…')),
              error: (e, _) => ListTile(title: Text('Error: $e')),
              data: (isLinked) => isLinked
                  ? _ConnectedTile(
                      email: email.valueOrNull ?? '',
                      lastSync: lastSync.valueOrNull,
                    )
                  : _NotConnectedTile(isAndroid: _isAndroid),
            ),
            if (linked.valueOrNull == true) ...[
              _SyncActionsRow(),
            ],
            const Divider(height: 24),

            _section('Linked Devices'),
            devices.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => ListTile(title: Text('Error: $e')),
              data: (list) => Column(
                children: [
                  for (final d in list) _DeviceTile(device: d, ref: ref),
                  if (list.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Text(
                        'No devices linked yet.',
                        style: TextStyle(color: AppColors.textSecondary),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: Icon(_isAndroid ? Icons.qr_code_2 : Icons.qr_code_scanner),
                  label: Text(_isAndroid
                      ? 'Link New Windows Device'
                      : 'Link to Android Device'),
                  onPressed: () => _openLinkFlow(context, ref),
                ),
              ),
            ),
            const Divider(height: 24),

            _section('Sync Status'),
            unsynced.when(
              loading: () => const ListTile(title: Text('Unsynced records: …')),
              error: (_, _) => const SizedBox.shrink(),
              data: (count) => ListTile(
                leading: const Icon(Icons.sync_problem_outlined,
                    color: AppColors.primary),
                title: const Text('Unsynced records'),
                trailing: Text('$count',
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            if (linked.valueOrNull == true)
              _StorageTile(),

            if (linked.valueOrNull == true) ...[
              const Divider(height: 24),
              _section('Troubleshooting'),
              _ResetTile(),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openLinkFlow(BuildContext context, WidgetRef ref) async {
    if (_isAndroid) {
      // Android needs to be signed in first to have a token to hand off.
      final auth = ref.read(authServiceProvider);
      if (!await auth.isSignedIn()) {
        try {
          final account = await auth.signIn();
          if (account == null) {
            if (context.mounted) {
              _toast(context, 'Sign in with Google to link a device.');
            }
            return;
          }
        } on SignInException catch (e) {
          if (context.mounted) _toast(context, e.message);
          return;
        }
        refreshSyncStateW(ref);
      }
      if (context.mounted) {
        await Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ShowQrScreen()));
      }
    } else {
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => const ScanQrScreen()));
    }
    refreshSyncStateW(ref);
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
        child: Text(title,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.primary,
              letterSpacing: 0.8,
            )),
      );
}

void _toast(BuildContext context, String msg) {
  // Errors can be long (a Drive REST body); give them time + room to be read.
  final isLong = msg.length > 60;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    duration: isLong ? const Duration(seconds: 8) : const Duration(seconds: 4),
  ));
}

String _relative(DateTime? when) {
  if (when == null) return 'never';
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} hr ago';
  return DateFormat('d MMM, h:mm a').format(when);
}

class _ConnectedTile extends ConsumerWidget {
  final String email;
  final DateTime? lastSync;
  const _ConnectedTile({required this.email, required this.lastSync});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.cloud_done, color: AppColors.primary),
          title: Text(email.isEmpty ? 'Connected' : email),
          subtitle: Text('Last sync: ${_relative(lastSync)}'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.logout, size: 18),
              style: TextButton.styleFrom(foregroundColor: AppColors.expense),
              label: const Text('Disconnect'),
              onPressed: () async {
                final ok = await _confirmDisconnect(context);
                if (ok != true) return;
                await disconnectSync(ref);
                if (context.mounted) _toast(context, 'Disconnected.');
              },
            ),
          ),
        ),
      ],
    );
  }

  Future<bool?> _confirmDisconnect(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Disconnect Google Drive?'),
        content: const Text(
            'Syncing will stop on this device. Your local data stays intact.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.expense),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Disconnect')),
        ],
      ),
    );
  }
}

class _NotConnectedTile extends ConsumerWidget {
  final bool isAndroid;
  const _NotConnectedTile({required this.isAndroid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.cloud_off_outlined,
              color: AppColors.textSecondary),
          title: const Text('Not connected'),
          subtitle: Text(isAndroid
              ? 'Sign in with Google to enable sync.'
              : 'Scan the QR code from your Android phone to link.'),
        ),
        if (isAndroid)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style:
                    FilledButton.styleFrom(backgroundColor: AppColors.primary),
                icon: const Icon(Icons.login),
                label: const Text('Connect Google Drive'),
                onPressed: () async {
                  try {
                    final account =
                        await ref.read(authServiceProvider).signIn();
                    if (account != null) {
                      refreshSyncStateW(ref);
                      if (context.mounted) {
                        _toast(context, 'Connected as ${account.email}.');
                      }
                    }
                  } on SignInException catch (e) {
                    if (context.mounted) _toast(context, e.message);
                  }
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _SyncActionsRow extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SyncActionsRow> createState() => _SyncActionsRowState();
}

class _SyncActionsRowState extends ConsumerState<_SyncActionsRow> {
  bool _syncing = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          icon: _syncing
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.sync),
          label: Text(_syncing ? 'Syncing…' : 'Sync Now'),
          onPressed: _syncing ? null : _syncNow,
        ),
      ),
    );
  }

  Future<void> _syncNow() async {
    final engine = ref.read(syncEngineProvider);
    if (engine == null) return;
    setState(() => _syncing = true);
    final result = await engine.sync();
    // Confirm via the app-level messenger so the result shows even if the user
    // navigated away from this screen while the sync was running.
    showSyncSnack(result);
    if (!mounted) return;
    setState(() => _syncing = false);
    refreshSyncStateW(ref);
    invalidateAllSyncedDataW(ref);
  }

}

/// Destructive "fresh start" for this device: wipes local synced data and
/// re-pulls the paired device's snapshot. For recovering a device whose numbers
/// drifted (e.g. pre-fix double-counted stock).
class _ResetTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ResetTile> createState() => _ResetTileState();
}

class _ResetTileState extends ConsumerState<_ResetTile> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: _busy
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.restart_alt, color: AppColors.expense),
      title: const Text('Reset & re-sync this device'),
      subtitle: const Text(
          'Erase this device’s data and re-download from the linked device'),
      onTap: _busy ? null : _confirmAndReset,
    );
  }

  Future<void> _confirmAndReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reset & re-sync this device?'),
        content: const Text(
            'This erases all bills, items, parties and balances stored on THIS '
            'device, then re-downloads everything from the linked device.\n\n'
            'Use this if this device’s numbers look wrong. The other device is '
            'not affected.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.expense),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reset & re-sync')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    final result = await resetAndResync(ref);
    if (!mounted) return;
    setState(() => _busy = false);
    final msg = switch (result.status) {
      SyncStatus.ok => 'Reset complete — re-synced from the linked device.',
      SyncStatus.noInternet => 'Data cleared, but no internet to re-sync yet.',
      SyncStatus.notLinked => 'Data cleared, but the device isn’t linked.',
      SyncStatus.failed =>
        'Data cleared, but re-sync failed: ${result.errorMessage ?? 'unknown'}',
    };
    _toast(context, msg);
  }
}

class _DeviceTile extends StatelessWidget {
  final SyncDevice device;
  final WidgetRef ref;
  const _DeviceTile({required this.device, required this.ref});

  /// A device that synced within this window is treated as currently linked &
  /// active. Each successful sync round-trips through Drive and updates last_seen,
  /// so recent activity ≈ "online".
  static const _onlineWindow = Duration(minutes: 3);

  @override
  Widget build(BuildContext context) {
    final isThis = device.deviceId == ref.read(deviceIdProvider);
    final icon = device.deviceType == 'android'
        ? Icons.smartphone
        : Icons.laptop_windows;

    final online = device.lastSeen != null &&
        DateTime.now().difference(device.lastSeen!) <= _onlineWindow;

    final Widget subtitle;
    if (isThis) {
      subtitle = const Text('This device');
    } else if (online) {
      subtitle = Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
                color: AppColors.income, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          const Text('Online · active now',
              style: TextStyle(color: AppColors.income, fontWeight: FontWeight.w600)),
        ],
      );
    } else {
      subtitle = Text('Last active: ${_relative(device.lastSeen)}');
    }

    return ListTile(
      leading: Icon(icon, color: AppColors.primary),
      title: Text(device.deviceName ??
          (device.deviceType == 'android' ? 'Android device' : 'Windows PC')),
      subtitle: subtitle,
      trailing: isThis
          ? null
          : IconButton(
              icon: const Icon(Icons.link_off, color: AppColors.expense),
              tooltip: 'Unlink',
              onPressed: () async {
                await ref
                    .read(syncRepositoryProvider)
                    .removeDevice(device.deviceId);
                refreshSyncStateW(ref);
              },
            ),
    );
  }
}

class _StorageTile extends ConsumerStatefulWidget {
  @override
  ConsumerState<_StorageTile> createState() => _StorageTileState();
}

class _StorageTileState extends ConsumerState<_StorageTile> {
  int? _bytes;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.storage_outlined, color: AppColors.primary),
      title: const Text('Drive storage used'),
      trailing: _loading
          ? const SizedBox(
              height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : Text(_bytes == null ? 'Tap to check' : _fmt(_bytes!)),
      onTap: _loading ? null : _check,
    );
  }

  Future<void> _check() async {
    final auth = ref.read(authServiceProvider);
    final token = await auth.getAccessToken();
    if (token == null) return;
    setState(() => _loading = true);
    final drive = ref.read(driveServiceProvider)..setToken(token);
    int bytes = 0;
    try {
      bytes = await drive.folderStorageBytes();
    } on DriveException {
      bytes = 0;
    }
    if (!mounted) return;
    setState(() {
      _bytes = bytes;
      _loading = false;
    });
  }

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)} KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}
