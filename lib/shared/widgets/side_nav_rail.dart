import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/providers/theme_provider.dart';

/// Persistent left navigation for the wide (desktop) layout. Replaces the
/// hamburger drawer + bottom nav bar when the window is wide. The four primary
/// destinations drive [selectedIndex] (they switch the shell's IndexedStack);
/// the secondary destinations push named routes exactly like the drawer does on
/// mobile, so nothing in the menu is lost.
class SideNavRail extends ConsumerWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  const SideNavRail({
    super.key,
    required this.selectedIndex,
    required this.onSelect,
  });

  static const double width = 240;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(themeProvider) == ThemeMode.dark;

    return SizedBox(
      width: width,
      child: Material(
        color: AppColors.surface(context),
        child: Column(
          children: [
            // The business name + Company Profile link now lives in the app bar
            // title (clickable), so the rail no longer repeats it as a header —
            // just a small top spacer below the app bar.
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  // Primary destinations — these switch the shell's IndexedStack.
                  _PrimaryItem(
                    icon: Icons.home_outlined,
                    activeIcon: Icons.home,
                    label: AppStrings.navDashboard,
                    selected: selectedIndex == 0,
                    onTap: () => onSelect(0),
                  ),
                  _PrimaryItem(
                    icon: Icons.receipt_long_outlined,
                    activeIcon: Icons.receipt_long,
                    label: AppStrings.navSale,
                    selected: selectedIndex == 1,
                    onTap: () => onSelect(1),
                  ),
                  _PrimaryItem(
                    icon: Icons.shopping_cart_outlined,
                    activeIcon: Icons.shopping_cart,
                    label: AppStrings.navPurchase,
                    selected: selectedIndex == 2,
                    onTap: () => onSelect(2),
                  ),
                  _PrimaryItem(
                    icon: Icons.people_outline,
                    activeIcon: Icons.people,
                    label: AppStrings.navParties,
                    selected: selectedIndex == 3,
                    onTap: () => onSelect(3),
                  ),
                  const Divider(height: 16),
                  // Secondary destinations — push named routes (as the drawer does).
                  _RouteItem(Icons.inventory_2_outlined, AppStrings.drawerItems,
                      '/items'),
                  _RouteItem(Icons.warehouse_outlined,
                      AppStrings.drawerInventory, '/inventory'),
                  _RouteItem(Icons.money_off_outlined, AppStrings.drawerExpense,
                      '/expense'),
                  _RouteItem(Icons.attach_money, AppStrings.drawerIncome,
                      '/income'),
                  _RouteItem(Icons.account_balance_wallet_outlined,
                      AppStrings.drawerCashBank, '/cash-bank'),
                  _RouteItem(Icons.groups_2_outlined,
                      AppStrings.drawerEmployees, '/employees'),
                  const Divider(height: 16),
                  _RouteItem(Icons.bar_chart, AppStrings.drawerReports,
                      '/reports'),
                  _RouteItem(Icons.backup_outlined, AppStrings.drawerBackup,
                      '/backup'),
                  _RouteItem(Icons.sync, AppStrings.drawerSync, '/sync'),
                  _RouteItem(Icons.settings_outlined, AppStrings.drawerSettings,
                      '/settings'),
                ],
              ),
            ),
            const Divider(height: 0),
            SwitchListTile(
              value: isDark,
              onChanged: (_) => ref.read(themeProvider.notifier).toggle(),
              title: const Text('Dark Mode', style: TextStyle(fontSize: 14)),
              secondary: Icon(isDark ? Icons.dark_mode : Icons.light_mode,
                  color: AppColors.primary),
              activeThumbColor: AppColors.primary,
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 10, top: 2),
              child: Text('v1.0.0',
                  style: TextStyle(color: AppColors.textHint, fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

}

/// A primary destination that switches the shell's selected screen. Highlighted
/// when active.
class _PrimaryItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _PrimaryItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? AppColors.primary.withValues(alpha: 0.10)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: ListTile(
          dense: true,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: Icon(selected ? activeIcon : icon, color: color, size: 22),
          title: Text(label,
              style: TextStyle(
                  fontSize: 14,
                  color: selected
                      ? AppColors.textPrimaryOf(context)
                      : AppColors.textSecondary,
                  fontWeight:
                      selected ? FontWeight.w700 : FontWeight.w500)),
          onTap: onTap,
        ),
      ),
    );
  }
}

/// A secondary destination that pushes a named route (same as the drawer).
class _RouteItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String route;

  const _RouteItem(this.icon, this.label, this.route);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: AppColors.primary, size: 22),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      onTap: () => Navigator.pushNamed(context, route),
    );
  }
}
