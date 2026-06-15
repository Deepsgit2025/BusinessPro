import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/theme_provider.dart';
import '../../../screens/security/security_settings_screen.dart';
import '../../../services/security/app_lock_service.dart';
import '../../items/screens/tax_rates_screen.dart';
import '../../items/screens/units_screen.dart';
import 'bill_formats_screen.dart';
import 'notification_settings_screen.dart';
import 'prefix_settings_screen.dart';
import 'printer_settings_screen.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    final themeMode = ref.watch(themeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (settings) => ListView(
          children: [
            _SectionTile('Appearance'),
            SwitchListTile(
              value: themeMode == ThemeMode.dark,
              onChanged: (_) => ref.read(themeProvider.notifier).toggle(),
              title: const Text('Dark Mode'),
              secondary: const Icon(Icons.dark_mode_outlined, color: AppColors.primary),
              activeThumbColor: AppColors.primary,
            ),
            const Divider(height: 0),

            _SectionTile('Notifications'),
            ListTile(
              leading: const Icon(Icons.notifications_outlined,
                  color: AppColors.primary),
              title: const Text('Notifications'),
              subtitle: const Text('Choose which alerts you receive'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const NotificationSettingsScreen()),
              ),
            ),
            const Divider(height: 0),

            _SectionTile('Invoice & Transactions'),
            SwitchListTile(
              value: settings.taxEnabled,
              onChanged: (v) => ref.read(settingsProvider.notifier).set(AppStrings.kTaxEnabled, v ? '1' : '0'),
              title: const Text('Enable GST / Tax'),
              secondary: const Icon(Icons.percent, color: AppColors.primary),
              activeThumbColor: AppColors.primary,
            ),
            SwitchListTile(
              value: settings.showDiscount,
              onChanged: (v) => ref.read(settingsProvider.notifier).set(AppStrings.kShowDiscount, v ? '1' : '0'),
              title: const Text('Show Discount Field'),
              secondary: const Icon(Icons.discount_outlined, color: AppColors.primary),
              activeThumbColor: AppColors.primary,
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined,
                  color: AppColors.primary),
              title: const Text('Bill Formats'),
              subtitle:
                  const Text('Invoice & estimate print layouts, preview'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const BillFormatsScreen()),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.tag, color: AppColors.primary),
              title: const Text('Invoice Prefix'),
              subtitle:
                  const Text('Sale & purchase numbering — custom or monthly'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const PrefixSettingsScreen()),
              ),
            ),
            const Divider(height: 0),

            _SectionTile('Inventory'),
            SwitchListTile(
              value: settings.stockTracking,
              onChanged: (v) => ref.read(settingsProvider.notifier).set(AppStrings.kStockTracking, v ? '1' : '0'),
              title: const Text('Track Stock'),
              subtitle: const Text('Auto-update inventory on sale/purchase'),
              secondary: const Icon(Icons.inventory_outlined, color: AppColors.primary),
              activeThumbColor: AppColors.primary,
            ),
            SwitchListTile(
              value: settings.lowStockAlert,
              onChanged: (v) => ref.read(settingsProvider.notifier).set(AppStrings.kLowStockAlert, v ? '1' : '0'),
              title: const Text('Low Stock Alert'),
              secondary: const Icon(Icons.warning_amber_outlined, color: AppColors.primary),
              activeThumbColor: AppColors.primary,
            ),
            const Divider(height: 0),

            _SectionTile('Master Data'),
            ListTile(
              leading: const Icon(Icons.straighten, color: AppColors.primary),
              title: const Text('Units'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const UnitsScreen())),
            ),
            ListTile(
              leading: const Icon(Icons.percent, color: AppColors.primary),
              title: const Text('Tax Rates'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const TaxRatesScreen())),
            ),
            const Divider(height: 0),

            _SectionTile('Date & Currency'),
            ListTile(
              leading: const Icon(Icons.calendar_today_outlined, color: AppColors.primary),
              title: const Text('Date Format'),
              trailing: DropdownButton<String>(
                value: settings.dateFormat,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 'dd/MM/yyyy', child: Text('dd/MM/yyyy')),
                  DropdownMenuItem(value: 'MM/dd/yyyy', child: Text('MM/dd/yyyy')),
                  DropdownMenuItem(value: 'yyyy-MM-dd', child: Text('yyyy-MM-dd')),
                ],
                onChanged: (v) {
                  if (v != null) ref.read(settingsProvider.notifier).set(AppStrings.kDateFormat, v);
                },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.currency_rupee, color: AppColors.primary),
              title: const Text('Decimal Places'),
              trailing: DropdownButton<String>(
                value: settings.decimalPlaces.toString(),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: '0', child: Text('0')),
                  DropdownMenuItem(value: '2', child: Text('2')),
                  DropdownMenuItem(value: '3', child: Text('3')),
                ],
                onChanged: (v) {
                  if (v != null) ref.read(settingsProvider.notifier).set(AppStrings.kDecimalPlaces, v);
                },
              ),
            ),
            const Divider(height: 0),

            _SectionTile('Printing'),
            ListTile(
              leading: const Icon(Icons.print_outlined, color: AppColors.primary),
              title: const Text('Printer Settings'),
              subtitle: const Text('Thermal printer, paper size, default printer'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => const PrinterSettingsScreen()),
              ),
            ),
            const Divider(height: 0),

            _SectionTile('Sync'),
            ListTile(
              leading: const Icon(Icons.sync, color: AppColors.primary),
              title: const Text('Sync & Devices'),
              subtitle: const Text('Google Drive sync, linked devices'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pushNamed(context, '/sync'),
            ),
            const Divider(height: 0),

            _SectionTile('Security'),
            ListTile(
              leading: const Icon(Icons.security_outlined, color: AppColors.primary),
              title: const Text('Security'),
              subtitle: ListenableBuilder(
                listenable: AppLockService.instance,
                builder: (context, _) => Text(AppLockService.instance.pinEnabled
                    ? 'PIN lock is on'
                    : 'PIN lock is off'),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SecuritySettingsScreen(
                    onChanged: (enabled, hash) async {
                      await DatabaseHelper.setSetting(
                          'security_pin_enabled', enabled ? '1' : '0');
                      await DatabaseHelper.setSetting(
                          'security_pin_hash', hash ?? '');
                    },
                  ),
                ),
              ),
            ),
            const Divider(height: 0),

            _SectionTile('Backup'),
            ListTile(
              leading: const Icon(Icons.backup_outlined, color: AppColors.primary),
              title: const Text('Backup Reminder'),
              trailing: DropdownButton<String>(
                value: settings.backupReminderDays.toString(),
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: '1', child: Text('Daily')),
                  DropdownMenuItem(value: '7', child: Text('Weekly')),
                  DropdownMenuItem(value: '30', child: Text('Monthly')),
                  DropdownMenuItem(value: '0', child: Text('Off')),
                ],
                onChanged: (v) {
                  if (v != null) ref.read(settingsProvider.notifier).set(AppStrings.kBackupReminderDays, v);
                },
              ),
            ),
            const Divider(height: 0),

            _SectionTile('About'),
            ListTile(
              leading: const Icon(Icons.info_outline, color: AppColors.primary),
              title: const Text('Version'),
              trailing: const Text('1.0.0', style: TextStyle(color: AppColors.textSecondary)),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
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
      child: Text(title, style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: AppColors.primary,
        letterSpacing: 0.8,
      )),
    );
  }
}
