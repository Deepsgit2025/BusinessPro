import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/providers/business_provider.dart';
import '../../core/providers/theme_provider.dart';

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bizAsync = ref.watch(businessProvider);
    final themeMode = ref.watch(themeProvider);
    final isDark = themeMode == ThemeMode.dark;

    return Drawer(
      child: Column(
        children: [
          // Header — tappable, opens Company Profile
          InkWell(
            onTap: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/company-setup');
            },
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [AppColors.primaryDark, AppColors.primary],
                ),
              ),
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top + 16,
                bottom: 16,
                left: 16,
                right: 16,
              ),
              child: bizAsync.when(
                loading: () => const SizedBox(
                  height: 40,
                  child: Center(child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                ),
                error: (_, err) => const SizedBox.shrink(),
                data: (biz) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      biz?['name'] as String? ?? 'My Business',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      biz?['gstin'] as String? ?? 'Tap to set up profile',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Nav items
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _DrawerItem(Icons.inventory_2_outlined, AppStrings.drawerItems, () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/items');
                }),
                _DrawerItem(Icons.money_off_outlined, AppStrings.drawerExpense, () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/expense');
                }),
                _DrawerItem(Icons.attach_money, AppStrings.drawerIncome, () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/income');
                }),
                _DrawerItem(Icons.account_balance_wallet_outlined, AppStrings.drawerCashBank, () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/cash-bank');
                }),
                const Divider(),
                _DrawerItem(Icons.bar_chart, AppStrings.drawerReports, () => Navigator.pop(context)),
                _DrawerItem(Icons.backup_outlined, AppStrings.drawerBackup, () => Navigator.pop(context)),
                const Divider(),
                _DrawerItem(Icons.settings_outlined, AppStrings.drawerSettings, () {
                  Navigator.pop(context);
                  Navigator.pushNamed(context, '/settings');
                }),
              ],
            ),
          ),

          // Dark mode toggle + version
          const Divider(height: 0),
          SwitchListTile(
            value: isDark,
            onChanged: (_) => ref.read(themeProvider.notifier).toggle(),
            title: const Text('Dark Mode', style: TextStyle(fontSize: 14)),
            secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode, color: AppColors.primary),
            activeThumbColor: AppColors.primary,
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('v1.0.0', style: TextStyle(color: AppColors.textHint, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DrawerItem(this.icon, this.label, this.onTap);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: AppColors.primary, size: 22),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      onTap: onTap,
      dense: true,
    );
  }
}
