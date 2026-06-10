import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../services/backup/backup_manager.dart';
import '../../../services/backup/backup_provider.dart';

/// Lists backups stored on the cloud provider, each with Restore / Delete. Pull
/// to refresh. While the Drive provider is deferred its listing returns empty,
/// so this screen shows a "not configured" empty state rather than an error.
class CloudBackupsListScreen extends StatefulWidget {
  final BackupManager manager;
  const CloudBackupsListScreen({super.key, required this.manager});

  @override
  State<CloudBackupsListScreen> createState() => _CloudBackupsListScreenState();
}

class _CloudBackupsListScreenState extends State<CloudBackupsListScreen> {
  late Future<List<BackupRecord>> _future = _load();
  bool _busy = false;

  Future<List<BackupRecord>> _load() => widget.manager.listCloudBackups();

  void _refresh() => setState(() => _future = _load());

  Future<void> _restore(BackupRecord r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
          'This will replace ALL current data with the backup from '
          '${Formatters.dateShort(r.createdAt)}.\n\nThis cannot be undone. Continue?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.expense),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await widget.manager.restoreFromCloud(r.id);
      _snack('Restore complete.');
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(BackupRecord r) async {
    setState(() => _busy = true);
    try {
      await widget.manager.deleteCloudBackup(r.id);
      _refresh();
    } catch (e) {
      _snack('$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColors.expense : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud Backups')),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () async => _refresh(),
            child: FutureBuilder<List<BackupRecord>>(
              future: _future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = snap.data ?? const [];
                if (rows.isEmpty) {
                  return ListView(
                    children: const [
                      SizedBox(height: 120),
                      Icon(Icons.cloud_off_outlined,
                          size: 56, color: AppColors.textHint),
                      SizedBox(height: 12),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 32),
                        child: Text(
                          'No cloud backups.\nGoogle Drive backup isn\'t set up on this build yet.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.textSecondary),
                        ),
                      ),
                    ],
                  );
                }
                return ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _tile(rows[i]),
                );
              },
            ),
          ),
          if (_busy)
            Container(
              color: Colors.black26,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  Widget _tile(BackupRecord r) {
    return ListTile(
      leading: const Icon(Icons.backup_outlined, color: AppColors.primary),
      title: Text(r.fileName,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13)),
      subtitle: Text(
          '${Formatters.dateShort(r.createdAt)}  ·  ${r.sizeLabel}',
          style: const TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.restore, color: AppColors.primary),
            tooltip: 'Restore',
            onPressed: _busy ? null : () => _restore(r),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: AppColors.expense),
            tooltip: 'Delete',
            onPressed: _busy ? null : () => _delete(r),
          ),
        ],
      ),
    );
  }
}
