import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_colors.dart';
import '../../core/constants/app_strings.dart';
import '../../core/utils/responsive.dart';
import '../../core/providers/business_provider.dart';
import '../../core/providers/notification_provider.dart';
import '../../features/dashboard/screens/dashboard_screen.dart';
import '../../features/dashboard/widgets/notifications_sheet.dart';
import '../../features/transactions/providers/transaction_providers.dart';
import '../../features/transactions/screens/sale_list_screen.dart';
import '../../features/transactions/screens/purchase_list_screen.dart';
import '../../features/parties/screens/parties_screen.dart';
import '../../features/sync/screens/sync_notifications_screen.dart';
import '../../services/sync/sync_providers.dart';
import 'app_drawer.dart';
import 'side_nav_rail.dart';

class MainShell extends ConsumerStatefulWidget {
  const MainShell({super.key});

  @override
  ConsumerState<MainShell> createState() => _MainShellState();
}

class _MainShellState extends ConsumerState<MainShell>
    with WidgetsBindingObserver {
  int _selectedIndex = 0;
  bool _searching = false;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Resolve this device's sync id, register it, then start the background
    // sync scheduler. All best-effort — a failure here must not block the UI.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ensureDeviceRegistered(ref);
        ref.read(syncSchedulerProvider).startPeriodicSync();
        // An opportunistic sync on launch (silent).
        ref.read(syncSchedulerProvider).onAppResume();
      } catch (_) {/* sync stays idle until next trigger */}
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(syncSchedulerProvider).onAppResume();
    }
  }

  static const _screens = <Widget>[
    DashboardScreen(),
    SaleListScreen(),
    PurchaseListScreen(),
    PartiesScreen(),
  ];

  static const _titles = <String>[
    AppStrings.navSale,
    AppStrings.navPurchase,
    AppStrings.navParties,
  ];

  // Dashboard (0) has no FAB; Parties (3) provides its own FAB + search.
  // Sale (1) and Purchase (2) each show a + FAB to create a new bill/invoice.
  // Search is Sale-only — Purchase (2) is an action-grid landing page.
  bool get _showFab => _selectedIndex == 1 || _selectedIndex == 2;
  bool get _showSearch => _selectedIndex == 1;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  String _titleFor(int index) {
    if (index == 0) {
      final name = ref.watch(businessProvider).valueOrNull?['name'] as String?;
      return (name != null && name.trim().isNotEmpty) ? name : AppStrings.appName;
    }
    return _titles[index - 1];
  }

  void _applySearch(String value) {
    if (_selectedIndex == 1) {
      final f = ref.read(saleFilterProvider);
      ref.read(saleFilterProvider.notifier).state = f.copyWith(search: value);
    } else if (_selectedIndex == 2) {
      final f = ref.read(purchaseFilterProvider);
      ref.read(purchaseFilterProvider.notifier).state =
          f.copyWith(search: value);
    }
  }

  void _stopSearching() {
    _searchController.clear();
    _applySearch('');
    setState(() => _searching = false);
  }

  void _onTabChange(int i) {
    if (_searching) _stopSearching();
    setState(() => _selectedIndex = i);
  }

  Future<void> _onFab() async {
    if (_selectedIndex == 1) {
      await SaleListScreen.openCreateSheet(context, ref);
    } else if (_selectedIndex == 2) {
      await PurchaseListScreen.openCreate(context, ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = Responsive.isWide(context);

    final body = IndexedStack(index: _selectedIndex, children: _screens);

    return Scaffold(
      // Wide layout uses a persistent rail, so no hamburger drawer there.
      drawer: wide ? null : const AppDrawer(),
      appBar: AppBar(
        // The rail provides navigation on wide windows; suppress the auto
        // hamburger so no empty leading button shows.
        automaticallyImplyLeading: !wide,
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                  hintText: 'Search…',
                  hintStyle: TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                ),
                onChanged: _applySearch,
              )
            : _selectedIndex == 0
                ? InkWell(
                    onTap: () =>
                        Navigator.pushNamed(context, '/company-setup'),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(_titleFor(0),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 4),
                        const Icon(Icons.chevron_right, size: 20),
                      ],
                    ),
                  )
                : Text(_titleFor(_selectedIndex)),
        actions: [
          if (_selectedIndex == 0) const _SyncBell(),
          if (_selectedIndex == 0) const _NotificationBell(),
          if (_showSearch)
            IconButton(
              icon: Icon(_searching ? Icons.close : Icons.search),
              onPressed: () {
                if (_searching) {
                  _stopSearching();
                } else {
                  setState(() => _searching = true);
                }
              },
            ),
        ],
      ),
      body: wide
          ? Row(
              children: [
                SideNavRail(
                  selectedIndex: _selectedIndex,
                  onSelect: _onTabChange,
                ),
                VerticalDivider(
                    width: 1, thickness: 1, color: AppColors.dividerOf(context)),
                Expanded(child: body),
              ],
            )
          : body,
      floatingActionButton: _showFab
          ? FloatingActionButton(
              backgroundColor: AppColors.primary,
              onPressed: _onFab,
              child: const Icon(Icons.add, color: Colors.white),
            )
          : null,
      // Bottom nav only on narrow windows; the rail replaces it when wide.
      bottomNavigationBar: wide
          ? null
          : BottomNavigationBar(
              currentIndex: _selectedIndex,
              onTap: _onTabChange,
              items: const [
                BottomNavigationBarItem(
                  icon: Icon(Icons.home_outlined),
                  activeIcon: Icon(Icons.home),
                  label: AppStrings.navDashboard,
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.receipt_long_outlined),
                  activeIcon: Icon(Icons.receipt_long),
                  label: AppStrings.navSale,
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.shopping_cart_outlined),
                  activeIcon: Icon(Icons.shopping_cart),
                  label: AppStrings.navPurchase,
                ),
                BottomNavigationBarItem(
                  icon: Icon(Icons.people_outline),
                  activeIcon: Icon(Icons.people),
                  label: AppStrings.navParties,
                ),
              ],
            ),
    );
  }
}

/// Sync-activity icon in the dashboard app bar. Badge shows unread sync-log
/// entries; tapping opens the sync activity screen.
class _SyncBell extends ConsumerWidget {
  const _SyncBell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(syncUnreadCountProvider).valueOrNull ?? 0;
    return IconButton(
      tooltip: 'Sync activity',
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SyncNotificationsScreen()),
      ),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.sync),
          if (count > 0)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                decoration: BoxDecoration(
                  color: AppColors.partial,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.primary, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  count > 9 ? '9+' : '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bell icon in the dashboard app bar with a live count badge. Opens the
/// notifications bottom sheet.
class _NotificationBell extends ConsumerWidget {
  const _NotificationBell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(notificationCountProvider);
    return IconButton(
      tooltip: 'Notifications',
      onPressed: () => showNotificationsSheet(context),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications_outlined),
          if (count > 0)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                decoration: BoxDecoration(
                  color: AppColors.expense,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.primary, width: 1.5),
                ),
                alignment: Alignment.center,
                child: Text(
                  count > 9 ? '9+' : '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
