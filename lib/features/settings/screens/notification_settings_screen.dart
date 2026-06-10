import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/providers/settings_provider.dart';

/// Settings → Notifications. A master switch plus per-type toggles controlling
/// which in-app notifications surface through the dashboard bell.
class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (s) {
          final notifier = ref.read(settingsProvider.notifier);
          void set(String key, bool v) => notifier.set(key, v ? '1' : '0');

          return ListView(
            children: [
              SwitchListTile(
                value: s.notifEnabled,
                onChanged: (v) => set(AppStrings.kNotifEnabled, v),
                title: const Text('Enable Notifications'),
                subtitle: const Text(
                    'Master switch for all in-app notifications'),
                secondary: const Icon(Icons.notifications_active_outlined,
                    color: AppColors.primary),
                activeThumbColor: AppColors.primary,
              ),
              const Divider(height: 0),
              _SectionTile('Reminders'),
              _NotifTile(
                enabled: s.notifEnabled,
                value: s.notifMonthEndExpense,
                onChanged: (v) => set(AppStrings.kNotifMonthEndExpense, v),
                icon: Icons.event_note_outlined,
                title: 'Month-end Expense Reminder',
                subtitle:
                    "Nudge to log expenses when a month is wrapping up",
              ),
              _NotifTile(
                enabled: s.notifEnabled,
                value: s.notifBackupReminder,
                onChanged: (v) => set(AppStrings.kNotifBackupReminder, v),
                icon: Icons.backup_outlined,
                title: 'Backup Reminder',
                subtitle: "Remind me to back up based on the backup interval",
              ),
              _NotifTile(
                enabled: s.notifEnabled,
                value: s.notifLowStock,
                onChanged: (v) => set(AppStrings.kNotifLowStock, v),
                icon: Icons.warning_amber_outlined,
                title: 'Low Stock Alerts',
                subtitle: "Warn when items reach their reorder level",
              ),
              const SizedBox(height: 24),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'Notifications appear in the bell on the Dashboard.',
                  style: TextStyle(
                      color: AppColors.textHint, fontSize: 12.5),
                ),
              ),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }
}

class _NotifTile extends StatelessWidget {
  final bool enabled;
  final bool value;
  final ValueChanged<bool> onChanged;
  final IconData icon;
  final String title;
  final String subtitle;

  const _NotifTile({
    required this.enabled,
    required this.value,
    required this.onChanged,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      value: enabled && value,
      onChanged: enabled ? onChanged : null,
      title: Text(title),
      subtitle: Text(subtitle),
      secondary: Icon(icon,
          color: enabled ? AppColors.primary : AppColors.textHint),
      activeThumbColor: AppColors.primary,
    );
  }
}

class _SectionTile extends StatelessWidget {
  final String title;
  const _SectionTile(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppColors.primary,
            letterSpacing: 0.8,
          )),
    );
  }
}
