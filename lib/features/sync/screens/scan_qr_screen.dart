import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../../../services/sync/qr_link_service.dart';
import '../../../services/sync/sync_models.dart';
import '../../../services/sync/sync_providers.dart';

/// Windows-side device linking — code only (no camera/QR). The user reads the
/// 8-char code shown on the Android phone and types it here. On success it fetches
/// the Drive token from Firebase, stores it (plus the paired Android device id for
/// the token relay), registers the Android device, and runs the first sync.
class ScanQrScreen extends ConsumerStatefulWidget {
  const ScanQrScreen({super.key});

  @override
  ConsumerState<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends ConsumerState<ScanQrScreen> {
  final _qr = QrLinkService();
  final _codeController = TextEditingController();
  bool _processing = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _link() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() => _processing = true);
    try {
      final result = await _qr.fetchTokenFromCode(code);
      if (!mounted) return;

      if (!result.isSuccess) {
        setState(() => _processing = false);
        _toast(result.status == LinkStatus.expired
            ? 'That code has expired. Generate a new one on Android.'
            : 'Code not found. Check it and try again.');
        return;
      }

      // Persist the handed-off token + the paired Android device id (the relay
      // key, so Windows can auto-refresh the token later without re-linking).
      await DatabaseHelper.setSetting(
          AppStrings.kDriveAccessToken, result.accessToken!);
      await DatabaseHelper.setSetting(
        AppStrings.kDriveTokenExpiry,
        DateTime.now().add(const Duration(minutes: 55)).toIso8601String(),
      );
      await DatabaseHelper.setSetting(
          AppStrings.kPairedAndroidDeviceId, result.androidDeviceId ?? '');

      // Register the Android device locally so it appears in the device list.
      await ref.read(syncRepositoryProvider).upsertDevice(SyncDevice(
            deviceId: result.androidDeviceId!,
            deviceName: result.androidDeviceName ?? 'Android device',
            deviceType: 'android',
            linkedAt: DateTime.now(),
            lastSeen: DateTime.now(),
          ));
      refreshSyncStateW(ref);

      // First sync immediately (silent — errors won't surface here).
      final engine = ref.read(syncEngineProvider);
      if (engine != null) {
        await engine.sync();
        refreshSyncStateW(ref);
        invalidateAllSyncedDataW(ref);
      }

      if (!mounted) return;
      _toast('Linked to Android device successfully.');
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _processing = false);
      _toast('Could not link. Check your connection and try again.');
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enter Link Code')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'On your Android phone, open BusinessPro → Settings → Sync & '
              'Devices → Link New Windows Device. A code will appear — type it '
              'below to link this PC.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 28),
            TextField(
              controller: _codeController,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: 6,
              ),
              decoration: InputDecoration(
                hintText: 'A1B2C3D4',
                hintStyle: TextStyle(
                    color: AppColors.textHint, letterSpacing: 6, fontSize: 24),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(vertical: 18),
              ),
              onSubmitted: (_) => _link(),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                style:
                    FilledButton.styleFrom(backgroundColor: AppColors.primary),
                icon: _processing
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.link),
                label: Text(_processing ? 'Linking…' : 'Link Device'),
                onPressed: _processing ? null : _link,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'The code is single-use and expires in a minute. If it doesn’t '
              'work, generate a fresh one on Android.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textHint, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}
