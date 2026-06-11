import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_colors.dart';
import '../../../services/sync/sync_models.dart';
import '../../../services/sync/sync_providers.dart';

/// Sync-activity panel: the history of merges/conflicts from `sync_log`. Opened
/// from the dashboard bell's "Sync Activity" entry. Marks everything read on
/// open so the badge clears.
class SyncNotificationsScreen extends ConsumerStatefulWidget {
  const SyncNotificationsScreen({super.key});

  @override
  ConsumerState<SyncNotificationsScreen> createState() =>
      _SyncNotificationsScreenState();
}

class _SyncNotificationsScreenState
    extends ConsumerState<SyncNotificationsScreen> {
  @override
  void initState() {
    super.initState();
    // Clear the unread badge once the user is looking at the list.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(syncNotificationServiceProvider).markAllRead();
      if (mounted) refreshSyncStateW(ref);
    });
  }

  @override
  Widget build(BuildContext context) {
    final logs = ref.watch(syncLogsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Activity'),
        actions: [
          TextButton(
            onPressed: () async {
              await ref.read(syncNotificationServiceProvider).markAllRead();
              refreshSyncStateW(ref);
            },
            child: const Text('Mark all read',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: logs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (items) {
          if (items.isEmpty) return const _EmptyActivity();
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) => _LogCard(items[i]),
          );
        },
      ),
    );
  }
}

class _LogCard extends StatelessWidget {
  final SyncLog log;
  const _LogCard(this.log);

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (log.syncType) {
      'conflict' => (Icons.merge_type, AppColors.pending),
      'upload' => (Icons.cloud_upload_outlined, AppColors.partial),
      'download' => (Icons.cloud_download_outlined, AppColors.partial),
      _ => (Icons.sync, AppColors.primary),
    };
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log.description ?? 'Synced',
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 14, height: 1.3),
                ),
                const SizedBox(height: 4),
                Text(
                  _formatTime(log.syncedAt),
                  style: const TextStyle(
                      color: AppColors.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime when) {
    final now = DateTime.now();
    final diff = now.difference(when);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    final isToday = now.year == when.year &&
        now.month == when.month &&
        now.day == when.day;
    if (isToday) return 'Today ${DateFormat('h:mm a').format(when)}';
    return DateFormat('d MMM, h:mm a').format(when);
  }
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.cloud_sync_outlined,
                size: 40, color: AppColors.primary),
          ),
          const SizedBox(height: 14),
          const Text('No sync activity yet',
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          const Text('Synced changes will show up here',
              style: TextStyle(color: AppColors.textHint, fontSize: 12.5)),
        ],
      ),
    );
  }
}
