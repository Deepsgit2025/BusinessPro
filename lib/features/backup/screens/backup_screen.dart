import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/formatters.dart';
import '../../../services/backup/backup_manager.dart';
import '../../../services/backup/google_drive_backup.dart';
import 'cloud_backups_list_screen.dart';

/// Backup & Restore home (drawer → Backup). Three sections:
///  • Google Drive — scaffolded; actions are disabled until OAuth is wired up.
///  • Local backup — Save to Device / Share Backup (both work offline now).
///  • Restore — from Drive (deferred) or from a picked .db file (works now).
///
/// The Drive provider is the single injection point: swapping
/// `GoogleDriveBackup()` for `AwsS3Backup()` here is the only change needed to
/// move clouds.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key});

  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  final _provider = GoogleDriveBackup();
  late final BackupManager _manager = BackupManager(_provider);

  bool _busy = false;
  String _businessName = 'My Business';
  String? _lastLocalPath;

  @override
  void initState() {
    super.initState();
    _loadBusiness();
  }

  Future<void> _loadBusiness() async {
    final biz = await DatabaseHelper.getBusiness();
    if (mounted) {
      setState(() =>
          _businessName = (biz?['name'] as String?)?.trim().isNotEmpty == true
              ? biz!['name'] as String
              : 'My Business');
    }
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToDevice() => _run(() async {
        final path = await _manager.backupToLocal(_businessName);
        if (!mounted) return;
        setState(() => _lastLocalPath = path);
        // Tell the user where to look — the file is browsable in Downloads on
        // Android (and the OS Downloads folder on desktop).
        final inDownloads = path.contains('Download');
        _snack(inDownloads
            ? 'Backup saved to Downloads/BusinessPro.'
            : 'Backup saved.');
      });

  Future<void> _shareBackup() => _run(() async {
        await _manager.shareBackup(_businessName);
      });

  Future<void> _restoreFromFile() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Select a BusinessPro backup (.db)',
      type: FileType.any,
    );
    final path = picked?.path;
    if (path == null) return;

    if (!mounted) return;
    final ok = await _confirmRestore('the selected file');
    if (ok != true) return;

    await _run(() async {
      try {
        await _manager.restoreFromFile(path);
        if (!mounted) return;
        _snack('Restore complete. Data reloaded.');
      } on BackupException catch (e) {
        _snack(e.message, error: true);
      }
    });
  }

  Future<bool?> _confirmRestore(String source) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore backup?'),
        content: Text(
          'This will replace ALL current data with $source.\n\n'
          'This cannot be undone. Continue?',
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
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? AppColors.expense : null,
    ));
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Backup & Restore')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _cloudSection(),
              const SizedBox(height: 16),
              _localSection(),
              const SizedBox(height: 16),
              _restoreSection(),
            ],
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

  Widget _section({required String title, required List<Widget> children}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _cloudSection() {
    return _section(
      title: 'Google Drive Backup',
      children: [
        Row(
          children: [
            const Icon(Icons.cloud_off_outlined,
                size: 18, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Not connected',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Cloud backup isn\'t configured on this build yet. '
          '${GoogleDriveBackup.planDescription} '
          'For now, use Local backup or Share below.',
          style: const TextStyle(fontSize: 12, color: AppColors.textHint),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: null, // enabled once Drive is wired up
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('Backup Now'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CloudBackupsListScreen(manager: _manager),
                  ),
                ),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('View Backups'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _localSection() {
    return _section(
      title: 'Local Backup',
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style:
                    FilledButton.styleFrom(backgroundColor: AppColors.primary),
                onPressed: _busy ? null : _saveToDevice,
                icon: const Icon(Icons.save_alt),
                label: const Text('Save to Device'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busy ? null : _shareBackup,
                icon: const Icon(Icons.share_outlined),
                label: const Text('Share Backup'),
              ),
            ),
          ],
        ),
        if (_lastLocalPath != null) ...[
          const SizedBox(height: 10),
          Text('Saved: $_lastLocalPath',
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ],
        const SizedBox(height: 6),
        const Text('Share sends the database file to WhatsApp, Email, Drive, etc.',
            style: TextStyle(fontSize: 12, color: AppColors.textHint)),
      ],
    );
  }

  Widget _restoreSection() {
    return _section(
      title: 'Restore',
      children: [
        OutlinedButton.icon(
          onPressed: null, // enabled once Drive is wired up
          icon: const Icon(Icons.cloud_download_outlined),
          label: const Text('Restore from Drive'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy ? null : _restoreFromFile,
          icon: const Icon(Icons.upload_file_outlined),
          label: const Text('Restore from File'),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.expense.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 18, color: AppColors.expense),
              SizedBox(width: 8),
              Expanded(
                child: Text('Restoring will replace all current data.',
                    style: TextStyle(fontSize: 12, color: AppColors.expense)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text('Last loaded ${Formatters.dateShort(DateTime.now())}',
            style: const TextStyle(fontSize: 11, color: AppColors.textHint)),
      ],
    );
  }
}
